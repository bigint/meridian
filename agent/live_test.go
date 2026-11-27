package main

import (
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func discardLog() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func newFakeClock() *fakeClock {
	return &fakeClock{now: time.Date(2026, 11, 25, 10, 0, 0, 0, time.UTC)}
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

// ---- the server's side of RFC 6455, as much as the tests need ----

// frameHeader encodes a server frame header (unmasked) for a payload of n bytes.
func frameHeader(op byte, fin bool, n int) []byte {
	b0 := op
	if fin {
		b0 |= 0x80
	}
	switch {
	case n < 126:
		return []byte{b0, byte(n)}
	case n <= 0xffff:
		return []byte{b0, 126, byte(n >> 8), byte(n)}
	default:
		return binary.BigEndian.AppendUint64([]byte{b0, 127}, uint64(n))
	}
}

func serverFrame(op byte, fin bool, payload []byte) []byte {
	return append(frameHeader(op, fin, len(payload)), payload...)
}

// clientFrame is a frame as the server decoded it.
type clientFrame struct {
	op      byte
	fin     bool
	masked  bool
	payload []byte
}

func readClientFrame(r io.Reader) (clientFrame, error) {
	var h [2]byte
	if _, err := io.ReadFull(r, h[:]); err != nil {
		return clientFrame{}, err
	}
	f := clientFrame{fin: h[0]&0x80 != 0, op: h[0] & 0x0f, masked: h[1]&0x80 != 0}
	n := uint64(h[1] & 0x7f)
	switch n {
	case 126:
		var b [2]byte
		if _, err := io.ReadFull(r, b[:]); err != nil {
			return f, err
		}
		n = uint64(binary.BigEndian.Uint16(b[:]))
	case 127:
		var b [8]byte
		if _, err := io.ReadFull(r, b[:]); err != nil {
			return f, err
		}
		n = binary.BigEndian.Uint64(b[:])
	}
	var mask [4]byte
	if f.masked {
		if _, err := io.ReadFull(r, mask[:]); err != nil {
			return f, err
		}
	}
	f.payload = make([]byte, n)
	if _, err := io.ReadFull(r, f.payload); err != nil {
		return f, err
	}
	if f.masked {
		for i := range f.payload {
			f.payload[i] ^= mask[i%4]
		}
	}
	return f, nil
}

func collectClientFrames(r io.Reader) <-chan clientFrame {
	out := make(chan clientFrame, 256)
	go func() {
		defer close(out)
		for {
			f, err := readClientFrame(r)
			if err != nil {
				return
			}
			out <- f
		}
	}()
	return out
}

func recvFrame(t *testing.T, in <-chan clientFrame) clientFrame {
	t.Helper()
	select {
	case f, ok := <-in:
		if !ok {
			t.Fatal("connection closed while waiting for a client frame")
		}
		return f
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for a client frame")
	}
	return clientFrame{}
}

func pipeWS(t *testing.T, readTimeout time.Duration) (*wsConn, net.Conn) {
	t.Helper()
	server, client := net.Pipe()
	c := newWSConn(client, readTimeout)
	t.Cleanup(func() { c.close(); server.Close() })
	return c, server
}

func TestWSReadsMessagesOfEveryLengthClass(t *testing.T) {
	for _, n := range []int{0, 5, 125, 126, 300, 65535, 65536, 70000, maxInboundMessage} {
		c, server := pipeWS(t, time.Minute)
		payload := bytes.Repeat([]byte("ab"), n/2+1)[:n]
		go server.Write(serverFrame(opText, true, payload))
		got, err := c.readMessage()
		if err != nil || !bytes.Equal(got, payload) {
			t.Fatalf("%d-byte message: err=%v, got %d bytes", n, err, len(got))
		}
	}
}

func TestWSReassemblesFragmentsAndAnswersPingsInBetween(t *testing.T) {
	c, server := pipeWS(t, time.Minute)
	sent := collectClientFrames(server)
	go func() {
		server.Write(serverFrame(opText, false, []byte("hel")))
		server.Write(serverFrame(opPing, true, []byte("are you there")))
		server.Write(serverFrame(opContinuation, false, []byte("lo ")))
		server.Write(serverFrame(opContinuation, true, []byte("world")))
	}()
	got, err := c.readMessage()
	if err != nil || string(got) != "hello world" {
		t.Fatalf("got %q, %v", got, err)
	}
	pong := recvFrame(t, sent)
	if pong.op != opPong || string(pong.payload) != "are you there" || !pong.masked {
		t.Fatalf("pong = %+v, want a masked pong echoing the ping payload", pong)
	}
}

func TestWSRefusesMessagesOverOneMiB(t *testing.T) {
	// The announced length alone is enough: nothing is read or allocated.
	for _, tc := range []struct {
		name  string
		frame []byte
	}{
		{"one frame", frameHeader(opText, true, maxInboundMessage+1)},
		{"fragments adding up", append(serverFrame(opText, false, make([]byte, maxInboundMessage)), frameHeader(opContinuation, true, 1)...)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, server := pipeWS(t, time.Minute)
			sent := collectClientFrames(server)
			go server.Write(tc.frame)
			if _, err := c.readMessage(); err == nil {
				t.Fatal("want an error")
			}
			closeFrame := recvFrame(t, sent)
			if closeFrame.op != opClose || binary.BigEndian.Uint16(closeFrame.payload) != closeTooBig {
				t.Fatalf("client sent %+v, want a close frame with code 1009", closeFrame)
			}
		})
	}
}

func TestWSRejectsMaskedServerFrames(t *testing.T) {
	c, server := pipeWS(t, time.Minute)
	sent := collectClientFrames(server)
	go server.Write([]byte{0x81, 0x81, 1, 2, 3, 4, 'x' ^ 1})
	if _, err := c.readMessage(); err == nil {
		t.Fatal("want a protocol error")
	}
	if f := recvFrame(t, sent); f.op != opClose || binary.BigEndian.Uint16(f.payload) != closeProtocol {
		t.Fatalf("client sent %+v, want a close frame with code 1002", f)
	}
}

func TestWSCloseFrameIsEchoedAndReported(t *testing.T) {
	c, server := pipeWS(t, time.Minute)
	sent := collectClientFrames(server)
	go server.Write(serverFrame(opClose, true, append([]byte{0x03, 0xe9}, "going away"...)))
	_, err := c.readMessage()
	var ce *closeError
	if !errors.As(err, &ce) || ce.code != 1001 || ce.reason != "going away" {
		t.Fatalf("err = %v, want close 1001 going away", err)
	}
	if f := recvFrame(t, sent); f.op != opClose {
		t.Fatalf("client sent %+v, want the close echoed", f)
	}
}

func TestWSWritesAreMaskedAndNeverInterleave(t *testing.T) {
	c, server := pipeWS(t, time.Minute)
	sent := collectClientFrames(server)
	want := map[string]bool{}
	var wg sync.WaitGroup
	for i := range 40 {
		size := 3000
		if i%5 == 0 {
			size = 70000 // 64-bit length
		}
		msg := fmt.Sprintf("message-%02d-", i) + strings.Repeat("y", size)
		want[msg] = true
		wg.Go(func() {
			if err := c.writeText([]byte(msg)); err != nil {
				t.Errorf("write %d: %v", i, err)
			}
		})
	}
	wg.Wait()
	for range 40 {
		f := recvFrame(t, sent)
		if f.op != opText || !f.fin || !f.masked || !want[string(f.payload)] {
			t.Fatalf("garbled frame: op=%d fin=%v masked=%v len=%d", f.op, f.fin, f.masked, len(f.payload))
		}
		delete(want, string(f.payload))
	}
	if len(want) != 0 {
		t.Fatalf("%d messages never arrived", len(want))
	}
}

func TestWSSilentServerTimesOutButPingsKeepItAlive(t *testing.T) {
	t.Run("silence", func(t *testing.T) {
		c, _ := pipeWS(t, 100*time.Millisecond)
		start := time.Now()
		_, err := c.readMessage()
		if !errors.Is(err, errReadTimeout) || time.Since(start) < 90*time.Millisecond {
			t.Fatalf("err = %v after %s, want a read timeout after ~100ms", err, time.Since(start))
		}
	})
	t.Run("pings", func(t *testing.T) {
		c, server := pipeWS(t, 150*time.Millisecond)
		collectClientFrames(server) // pongs
		go func() {
			for range 10 { // 400ms in all: well past the timeout
				server.Write(serverFrame(opPing, true, nil))
				time.Sleep(40 * time.Millisecond)
			}
			server.Write(serverFrame(opText, true, []byte("finally")))
		}()
		got, err := c.readMessage()
		if err != nil || string(got) != "finally" {
			t.Fatalf("got %q, %v; pings should have kept the connection alive", got, err)
		}
	})
}

// ---- a fake ActionCable server ----

type cableServer struct {
	t      *testing.T
	srv    *httptest.Server
	conns  chan *srvConn
	status atomic.Int32 // non-zero: answer the upgrade with this HTTP status

	mu  sync.Mutex
	all []*srvConn
}

func newCableServer(t *testing.T) *cableServer {
	cs := &cableServer{t: t, conns: make(chan *srvConn, 32)}
	cs.srv = httptest.NewServer(http.HandlerFunc(cs.serve))
	t.Cleanup(func() {
		cs.mu.Lock()
		for _, c := range cs.all {
			c.close()
		}
		cs.mu.Unlock()
		cs.srv.Close()
	})
	return cs
}

func (cs *cableServer) serve(w http.ResponseWriter, r *http.Request) {
	if st := int(cs.status.Load()); st != 0 {
		http.Error(w, "refused", st)
		return
	}
	if r.URL.Path != "/cable" {
		http.NotFound(w, r)
		return
	}
	sum := sha1.Sum([]byte(r.Header.Get("Sec-WebSocket-Key") + wsGUID))
	conn, brw, err := http.NewResponseController(w).Hijack()
	if err != nil {
		return
	}
	fmt.Fprintf(brw, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"+
		"Sec-WebSocket-Accept: %s\r\nSec-WebSocket-Protocol: %s\r\n\r\n",
		base64.StdEncoding.EncodeToString(sum[:]), cableProtocol)
	brw.Flush()

	c := &srvConn{conn: conn, header: r.Header.Clone(), path: r.URL.Path, in: make(chan clientFrame, 256), done: make(chan struct{})}
	go func() {
		defer close(c.in)
		for {
			f, err := readClientFrame(brw.Reader)
			if err != nil {
				return
			}
			if !f.masked {
				cs.t.Errorf("client sent an unmasked frame")
			}
			c.in <- f
		}
	}()
	cs.mu.Lock()
	cs.all = append(cs.all, c)
	cs.mu.Unlock()
	cs.conns <- c
	<-c.done
	conn.Close()
}

// accept waits for the agent to connect.
func (cs *cableServer) accept(t *testing.T) *srvConn {
	t.Helper()
	select {
	case c := <-cs.conns:
		return c
	case <-time.After(5 * time.Second):
		t.Fatal("the agent never connected")
	}
	return nil
}

func (cs *cableServer) noConnectionWithin(t *testing.T, d time.Duration) {
	t.Helper()
	select {
	case <-cs.conns:
		t.Fatal("the agent connected again; the line should have stayed up")
	case <-time.After(d):
	}
}

type srvConn struct {
	conn   net.Conn
	header http.Header
	path   string
	in     chan clientFrame // closed once the client's end is gone
	wmu    sync.Mutex
	done   chan struct{}
	once   sync.Once
}

func (c *srvConn) close() { c.once.Do(func() { close(c.done) }) }

func (c *srvConn) send(op byte, payload []byte) {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	c.conn.Write(serverFrame(op, true, payload))
}

func (c *srvConn) sendJSON(s string) { c.send(opText, []byte(s)) }

// recvText returns the next text message the agent sent.
func (c *srvConn) recvText(t *testing.T) string {
	t.Helper()
	for {
		if f := recvFrame(t, c.in); f.op == opText {
			return string(f.payload)
		}
	}
}

// waitHungUp waits for the agent to drop the connection and returns the
// frames it sent on the way out.
func (c *srvConn) waitHungUp(t *testing.T) []clientFrame {
	t.Helper()
	var frames []clientFrame
	timeout := time.After(5 * time.Second)
	for {
		select {
		case f, ok := <-c.in:
			if !ok {
				return frames
			}
			frames = append(frames, f)
		case <-timeout:
			t.Fatal("the agent never hung up")
		}
	}
}

const testIdentifier = `{"channel":"AgentChannel","machine_id":"0123456789abcdef"}`

func jsonString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

// welcome plays the first step of a good start and returns the agent's
// subscribe command.
func (c *srvConn) welcome(t *testing.T) string {
	t.Helper()
	c.sendJSON(`{"type":"welcome"}`)
	return c.recvText(t)
}

func (c *srvConn) confirm() {
	c.sendJSON(`{"identifier":` + jsonString(testIdentifier) + `,"type":"confirm_subscription"}`)
}

func (c *srvConn) watch(seconds int) {
	c.sendJSON(fmt.Sprintf(`{"identifier":%s,"message":{"type":"watch","seconds":%d}}`, jsonString(testIdentifier), seconds))
}

// waitLog records the delays the line asked to sleep, and does not sleep.
type waitLog struct {
	mu sync.Mutex
	ds []time.Duration
}

func (w *waitLog) wait(ctx context.Context, d time.Duration) error {
	w.mu.Lock()
	w.ds = append(w.ds, d)
	w.mu.Unlock()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(2 * time.Millisecond):
		return nil
	}
}

func (w *waitLog) all() []time.Duration {
	w.mu.Lock()
	defer w.mu.Unlock()
	return slices.Clone(w.ds)
}

func (w *waitLog) await(t *testing.T, n int) []time.Duration {
	t.Helper()
	waitFor(t, fmt.Sprintf("%d backoff waits", n), func() bool { return len(w.all()) >= n })
	return w.all()[:n]
}

// startLine runs a line against url with no jitter (r = 0.5) and the backoff
// sleeps recorded in the returned log.
func startLine(t *testing.T, url string, tweak func(*line)) (*line, *waitLog) {
	t.Helper()
	l := newLine(config{url: url, token: "tok", machineID: "0123456789abcdef"}, discardLog(), func() float64 { return 0.5 })
	waits := &waitLog{}
	l.wait = waits.wait
	if tweak != nil {
		tweak(l)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { l.run(ctx); close(done) }()
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("line.run did not return after cancel")
		}
	})
	return l, waits
}

func TestLineHandshakeAndSubscribe(t *testing.T) {
	cs := newCableServer(t)
	l, _ := startLine(t, cs.srv.URL, nil)
	c := cs.accept(t)

	for k, want := range map[string]string{
		"Authorization":          "Bearer tok",
		"Origin":                 cs.srv.URL,
		"Sec-WebSocket-Protocol": "actioncable-v1-json",
		"User-Agent":             "meridian-agent/" + version,
		"Upgrade":                "websocket",
		"Sec-WebSocket-Version":  "13",
	} {
		if got := c.header.Get(k); got != want {
			t.Errorf("%s = %q, want %q", k, got, want)
		}
	}
	if c.path != "/cable" {
		t.Errorf("path = %q, want /cable", c.path)
	}

	// Subscribing waits for the server's welcome.
	if l.send([]byte(`{"early":1}`)) {
		t.Fatal("a frame was sent before the line was subscribed")
	}
	subscribe := c.welcome(t)
	if want := `{"command":"subscribe","identifier":` + jsonString(testIdentifier) + `}`; subscribe != want {
		t.Fatalf("subscribe = %s\nwant      %s", subscribe, want)
	}

	// Until the subscription is confirmed, frames are dropped, not queued.
	if l.send([]byte(`{"early":2}`)) {
		t.Fatal("a frame was sent before the subscription was confirmed")
	}
	c.confirm()
	frame := `{"action":"stats","containers":[]}`
	waitFor(t, "the line to go live", func() bool { return l.send([]byte(frame)) })

	var msg cableCommand
	if err := json.Unmarshal([]byte(c.recvText(t)), &msg); err != nil {
		t.Fatal(err)
	}
	if msg.Command != "message" || msg.Identifier != testIdentifier || msg.Data != frame {
		t.Fatalf("message = %+v, want command message, the same identifier, data %s", msg, frame)
	}
}

func TestLineDeliversWatchLeasesAndIgnoresTheRest(t *testing.T) {
	cs := newCableServer(t)
	l, _ := startLine(t, cs.srv.URL, nil)
	c := cs.accept(t)
	c.welcome(t)
	c.confirm()

	c.sendJSON(`{"type":"ping","message":1764068400}`)
	c.sendJSON(`{"type":"something_new"}`)
	c.sendJSON(`{"identifier":"{\"channel\":\"OtherChannel\"}","message":{"type":"watch","seconds":99}}`)
	c.sendJSON(`{"identifier":` + jsonString(testIdentifier) + `,"message":{"type":"something_new","seconds":98}}`)
	c.sendJSON(`not json at all`)
	c.watch(30)

	select {
	case seconds := <-l.watches:
		if seconds != 30 {
			t.Fatalf("first watch = %d seconds; only the watch for this channel should arrive", seconds)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no watch delivered")
	}
}

func TestLineReconnectsWithBackoff(t *testing.T) {
	cs := newCableServer(t)
	_, waits := startLine(t, cs.srv.URL, nil)

	cs.accept(t).close() // 1: dropped before saying anything

	c := cs.accept(t) // 2: subscription rejected
	c.welcome(t)
	c.sendJSON(`{"identifier":` + jsonString(testIdentifier) + `,"type":"reject_subscription"}`)
	if frames := c.waitHungUp(t); len(frames) == 0 || frames[len(frames)-1].op != opClose {
		t.Fatalf("the agent should close politely after a rejection, sent %+v", frames)
	}

	c = cs.accept(t) // 3: a clean session that then drops
	c.welcome(t)
	c.confirm()
	c.sendJSON(`{"type":"ping","message":1}`)
	c.close()

	c = cs.accept(t) // 4: rejected again
	c.welcome(t)
	c.sendJSON(`{"identifier":` + jsonString(testIdentifier) + `,"type":"reject_subscription"}`)

	// 5s doubling, +-20% jitter (none here); a confirmed session resets it.
	got := waits.await(t, 4)
	want := []time.Duration{5 * time.Second, 10 * time.Second, 5 * time.Second, 10 * time.Second}
	if !slices.Equal(got, want) {
		t.Fatalf("backoff waits = %v, want %v", got, want)
	}
}

func TestLineBacksOffFiveMinutesWhenRefused(t *testing.T) {
	cases := []struct {
		name   string
		status int // answer the upgrade with this HTTP status
		script func(c *srvConn)
	}{
		{"disconnect unauthorized", 0, func(c *srvConn) {
			c.sendJSON(`{"type":"welcome"}`)
			c.sendJSON(`{"type":"disconnect","reason":"unauthorized","reconnect":false}`)
		}},
		{"HTTP 401 on the upgrade", 401, nil},
		{"HTTP 403 on the upgrade", 403, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cs := newCableServer(t)
			cs.status.Store(int32(tc.status))
			_, waits := startLine(t, cs.srv.URL, nil)
			if tc.script != nil {
				tc.script(cs.accept(t))
			}
			if got := waits.await(t, 1)[0]; got != 5*time.Minute {
				t.Fatalf("waited %s, want 5m", got)
			}
		})
	}

	t.Run("a restarting server is not a refusal", func(t *testing.T) {
		cs := newCableServer(t)
		_, waits := startLine(t, cs.srv.URL, nil)
		c := cs.accept(t)
		c.sendJSON(`{"type":"disconnect","reason":"server_restart","reconnect":true}`)
		if got := waits.await(t, 1)[0]; got != 5*time.Second {
			t.Fatalf("waited %s, want the normal 5s", got)
		}
	})
	t.Run("another failure does not shorten it", func(t *testing.T) {
		cs := newCableServer(t)
		cs.status.Store(500)
		_, waits := startLine(t, cs.srv.URL, nil)
		got := waits.await(t, 3)
		if !slices.Equal(got, []time.Duration{5 * time.Second, 10 * time.Second, 20 * time.Second}) {
			t.Fatalf("waits after HTTP 500 = %v, want 5s, 10s, 20s", got)
		}
	})
}

func TestLineDetectsASilentServer(t *testing.T) {
	cs := newCableServer(t)
	_, waits := startLine(t, cs.srv.URL, func(l *line) { l.readTimeout = 300 * time.Millisecond })

	c := cs.accept(t)
	c.welcome(t)
	c.confirm() // then nothing: no ActionCable ping ever follows

	c.waitHungUp(t)
	waits.await(t, 1)
	cs.accept(t) // and it comes back
}

func TestLineStaysUpWhileThePingsKeepComing(t *testing.T) {
	cs := newCableServer(t)
	l, waits := startLine(t, cs.srv.URL, func(l *line) { l.readTimeout = 300 * time.Millisecond })

	c := cs.accept(t)
	c.welcome(t)
	c.confirm()
	for range 20 { // a full second: more than three read timeouts
		c.sendJSON(`{"type":"ping","message":1}`)
		time.Sleep(50 * time.Millisecond)
	}
	cs.noConnectionWithin(t, 10*time.Millisecond)
	if len(waits.all()) != 0 {
		t.Fatalf("the line went down: waits %v", waits.all())
	}
	waitFor(t, "a live line", func() bool { return l.send([]byte(`{}`)) })
}

func TestLineGivesUpOnASubscriptionThatIsNeverConfirmed(t *testing.T) {
	cs := newCableServer(t)
	_, waits := startLine(t, cs.srv.URL, func(l *line) { l.confirmTimeout = 200 * time.Millisecond })

	c := cs.accept(t)
	c.welcome(t)
	for range 8 { // the server stays chatty, so the read timeout never fires
		c.sendJSON(`{"type":"ping","message":1}`)
		time.Sleep(50 * time.Millisecond)
	}
	waits.await(t, 1)
	cs.accept(t)
}

func TestLineClosesCleanlyOnShutdown(t *testing.T) {
	cs := newCableServer(t)
	l := newLine(config{url: cs.srv.URL, token: "tok", machineID: "0123456789abcdef"}, discardLog(), func() float64 { return 0.5 })
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { l.run(ctx); close(done) }()

	c := cs.accept(t)
	c.welcome(t)
	c.confirm()
	waitFor(t, "a live line", func() bool { return l.send([]byte(`{}`)) })

	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("run did not return after cancel")
	}
	frames := c.waitHungUp(t)
	if len(frames) < 2 || frames[len(frames)-1].op != opClose {
		t.Fatalf("frames on the way out = %+v, want the connection ended with a close frame", frames)
	}
	if l.send([]byte(`{}`)) {
		t.Fatal("a frame was sent after shutdown")
	}
}

func TestRetryDelay(t *testing.T) {
	for _, tc := range []struct {
		failures int
		r        float64
		want     time.Duration
	}{
		{1, 0.5, 5 * time.Second},
		{2, 0.5, 10 * time.Second},
		{3, 0.5, 20 * time.Second},
		{4, 0.5, 40 * time.Second},
		{5, 0.5, 60 * time.Second},
		{50, 0.5, 60 * time.Second},
		{1, 0, 4 * time.Second},            // -20%
		{3, 0, 16 * time.Second},           // -20%
		{1, 0.75, 5500 * time.Millisecond}, // +10%
		{5, 0, 48 * time.Second},           // the cap is applied before the jitter
	} {
		got := retryDelay(tc.failures, tc.r)
		if diff := got - tc.want; diff < -2*time.Microsecond || diff > 2*time.Microsecond {
			t.Errorf("retryDelay(failures=%d, r=%v) = %s, want %s", tc.failures, tc.r, got, tc.want)
		}
	}
}
