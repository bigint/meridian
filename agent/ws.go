package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"sync/atomic"
	"time"
)

// A small RFC 6455 client. The upgrade goes through net/http, so TLS,
// proxies and the dial timeouts come from the caller's http.Client, and a 101
// response hands back the raw connection as the response Body.

const (
	wsGUID            = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	maxInboundMessage = 1 << 20
	maxControlPayload = 125
	wsWriteTimeout    = 5 * time.Second
)

const (
	opContinuation = 0x0
	opText         = 0x1
	opBinary       = 0x2
	opClose        = 0x8
	opPing         = 0x9
	opPong         = 0xA
)

const (
	closeNormal   = 1000
	closeProtocol = 1002
	closeTooBig   = 1009
)

var (
	errReadTimeout = errors.New("no frame from the server before the read timeout")
	errWSClosed    = errors.New("websocket closed")
)

// handshakeError is a response to the upgrade request that is not a 101.
type handshakeError struct{ status int }

func (e *handshakeError) Error() string {
	return fmt.Sprintf("websocket upgrade refused: HTTP %d", e.status)
}

// closeError is a close frame received from the server.
type closeError struct {
	code   int
	reason string
}

func (e *closeError) Error() string {
	return fmt.Sprintf("server closed the websocket: %d %s", e.code, e.reason)
}

// wsConn is the client end of an upgraded connection. readMessage belongs to
// one goroutine. The write methods are safe from any goroutine: wmu is the
// single write lock.
type wsConn struct {
	rwc io.ReadWriteCloser
	br  *bufio.Reader

	readTimeout time.Duration
	readDog     *watchdog

	wmu       sync.Mutex // serialises every write
	sentClose bool       // guarded by wmu
}

// dialWS upgrades to a WebSocket at endpoint (an http or https URL). client
// must have no overall Timeout, which would also kill the stream; bound the
// dial, TLS handshake and response headers on its Transport instead.
// readTimeout is how long the server may stay silent before the connection
// is closed.
func dialWS(ctx context.Context, client *http.Client, endpoint string, header http.Header, subprotocol string, readTimeout time.Duration) (*wsConn, error) {
	var nonce [16]byte
	rand.Read(nonce[:])
	key := base64.StdEncoding.EncodeToString(nonce[:])

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	for k, v := range header {
		req.Header[k] = v
	}
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Upgrade", "websocket")
	req.Header.Set("Sec-WebSocket-Version", "13")
	req.Header.Set("Sec-WebSocket-Key", key)
	req.Header.Set("Sec-WebSocket-Protocol", subprotocol)

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("dial: %w", err)
	}
	if resp.StatusCode != http.StatusSwitchingProtocols {
		io.Copy(io.Discard, io.LimitReader(resp.Body, 4<<10))
		resp.Body.Close()
		return nil, &handshakeError{status: resp.StatusCode}
	}
	rwc, ok := resp.Body.(io.ReadWriteCloser)
	if !ok {
		resp.Body.Close()
		return nil, errors.New("dial: upgrade response body is not writable")
	}
	sum := sha1.Sum([]byte(key + wsGUID))
	if resp.Header.Get("Sec-WebSocket-Accept") != base64.StdEncoding.EncodeToString(sum[:]) {
		rwc.Close()
		return nil, errors.New("dial: bad Sec-WebSocket-Accept")
	}
	if got := resp.Header.Get("Sec-WebSocket-Protocol"); got != subprotocol {
		rwc.Close()
		return nil, fmt.Errorf("dial: server chose subprotocol %q, want %q", got, subprotocol)
	}
	return newWSConn(rwc, readTimeout), nil
}

func newWSConn(rwc io.ReadWriteCloser, readTimeout time.Duration) *wsConn {
	return &wsConn{
		rwc:         rwc,
		br:          bufio.NewReader(rwc),
		readTimeout: readTimeout,
		readDog:     newWatchdog(readTimeout, func() { rwc.Close() }),
	}
}

// readMessage returns the next complete text or binary message, answering
// pings and following fragmentation on the way. Every frame, control frames
// included, counts as the server being alive.
func (c *wsConn) readMessage() ([]byte, error) {
	msg, err := c.readMessageFrames()
	if err != nil && c.readDog.didFire() {
		return nil, errReadTimeout
	}
	return msg, err
}

func (c *wsConn) readMessageFrames() ([]byte, error) {
	var msg []byte
	fragmented := false
	for {
		fin, op, n, err := c.readHeader()
		if err != nil {
			return nil, err
		}
		switch op {
		case opPing, opPong, opClose:
			if !fin || n > maxControlPayload {
				return nil, c.fail(closeProtocol, "bad control frame")
			}
			payload, err := c.readPayload(n)
			if err != nil {
				return nil, err
			}
			c.readDog.reset(c.readTimeout)
			switch op {
			case opPing:
				if err := c.writeFrame(opPong, payload); err != nil {
					return nil, err
				}
			case opClose:
				ce := &closeError{code: closeNormal}
				if len(payload) >= 2 {
					ce.code, ce.reason = int(binary.BigEndian.Uint16(payload)), string(payload[2:])
				}
				c.writeFrame(opClose, payload) // echo, best effort
				return nil, ce
			}
		case opText, opBinary, opContinuation:
			if (op == opContinuation) != fragmented {
				return nil, c.fail(closeProtocol, "unexpected frame in fragmented message")
			}
			if n > uint64(maxInboundMessage-len(msg)) {
				return nil, c.fail(closeTooBig, "message too big")
			}
			payload, err := c.readPayload(n)
			if err != nil {
				return nil, err
			}
			c.readDog.reset(c.readTimeout)
			msg = append(msg, payload...)
			if fragmented = !fin; !fragmented {
				return msg, nil
			}
		default:
			return nil, c.fail(closeProtocol, "unknown opcode")
		}
	}
}

func (c *wsConn) readHeader() (fin bool, op byte, n uint64, err error) {
	var h [2]byte
	if _, err = io.ReadFull(c.br, h[:]); err != nil {
		return
	}
	fin, op = h[0]&0x80 != 0, h[0]&0x0f
	if h[0]&0x70 != 0 { // no extension was negotiated
		return false, 0, 0, c.fail(closeProtocol, "reserved bits set")
	}
	if h[1]&0x80 != 0 { // servers never mask
		return false, 0, 0, c.fail(closeProtocol, "masked server frame")
	}
	switch n = uint64(h[1] & 0x7f); n {
	case 126:
		var b [2]byte
		if _, err = io.ReadFull(c.br, b[:]); err == nil {
			n = uint64(binary.BigEndian.Uint16(b[:]))
		}
	case 127:
		var b [8]byte
		if _, err = io.ReadFull(c.br, b[:]); err == nil {
			n = binary.BigEndian.Uint64(b[:])
		}
	}
	return
}

func (c *wsConn) readPayload(n uint64) ([]byte, error) {
	buf := make([]byte, n) // n is already within maxInboundMessage or maxControlPayload
	_, err := io.ReadFull(c.br, buf)
	return buf, err
}

// fail sends a close frame with code and returns an error describing why.
func (c *wsConn) fail(code int, why string) error {
	c.writeClose(code, why)
	return fmt.Errorf("websocket protocol error: %s", why)
}

func (c *wsConn) writeText(p []byte) error { return c.writeFrame(opText, p) }

func (c *wsConn) writeClose(code int, reason string) error {
	return c.writeFrame(opClose, append(binary.BigEndian.AppendUint16(nil, uint16(code)), reason...))
}

// writeFrame sends one masked, unfragmented frame. A write that cannot
// finish within wsWriteTimeout closes the connection.
func (c *wsConn) writeFrame(op byte, payload []byte) error {
	var mask [4]byte
	rand.Read(mask[:])

	buf := make([]byte, 0, 14+len(payload))
	buf = append(buf, 0x80|op)
	switch n := len(payload); {
	case n < 126:
		buf = append(buf, 0x80|byte(n))
	case n <= 0xffff:
		buf = append(buf, 0x80|126)
		buf = binary.BigEndian.AppendUint16(buf, uint16(n))
	default:
		buf = append(buf, 0x80|127)
		buf = binary.BigEndian.AppendUint64(buf, uint64(n))
	}
	buf = append(buf, mask[:]...)
	for i, b := range payload {
		buf = append(buf, b^mask[i%4])
	}

	c.wmu.Lock()
	defer c.wmu.Unlock()
	if c.sentClose {
		return errWSClosed
	}
	c.sentClose = op == opClose
	dog := newWatchdog(wsWriteTimeout, func() { c.rwc.Close() })
	defer dog.stop()
	_, err := c.rwc.Write(buf)
	return err
}

// shutdown says goodbye and closes the connection. Safe to call twice.
func (c *wsConn) shutdown() {
	c.writeClose(closeNormal, "")
	c.close()
}

func (c *wsConn) close() {
	c.readDog.stop()
	c.rwc.Close()
}

// watchdog runs onFire once if it is not reset or stopped within d. A
// ReadWriteCloser has no deadlines, so closing the connection is how a stuck
// read or write is cut short.
type watchdog struct {
	timer *time.Timer
	fired atomic.Bool
}

func newWatchdog(d time.Duration, onFire func()) *watchdog {
	w := &watchdog{}
	w.timer = time.AfterFunc(d, func() {
		w.fired.Store(true)
		onFire()
	})
	return w
}

func (w *watchdog) reset(d time.Duration) { w.timer.Reset(d) }
func (w *watchdog) stop()                 { w.timer.Stop() }
func (w *watchdog) didFire() bool         { return w.fired.Load() }
