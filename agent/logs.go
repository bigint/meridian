package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	maxLineBytes = 8192 // bytes of m kept, before the ellipsis
	// A raw line is "<timestamp> <message>\n". Keeping one byte more than a
	// full message plus the longest timestamp is enough to know the message is
	// too long, so a line without a newline can never grow the buffer past this.
	maxTimestamp = 40
	maxRawLine   = maxTimestamp + 1 + maxLineBytes + 1
	readChunk    = 32 << 10

	streamOut = "out"
	streamErr = "err"
)

var errBadFrame = errors.New("not a Docker log stream: bad frame header")

// logLine is one line of the wire format's "lines" array.
type logLine struct {
	T string `json:"t"` // Docker's RFC3339Nano timestamp, as sent
	S string `json:"s"` // streamOut or streamErr
	M string `json:"m"` // the message: valid UTF-8, at most maxLineBytes plus an ellipsis

	at time.Time // t parsed; zero when the line had no timestamp
}

// logBatch is the data of one logs message to Meridian.
type logBatch struct {
	Action    string    `json:"action"`
	Container string    `json:"container"`
	Backlog   bool      `json:"backlog"`
	Lines     []logLine `json:"lines"`
	Dropped   int       `json:"dropped"`
	Ended     bool      `json:"ended"`
}

// logReply is the agent's answer to a tail it will not serve.
type logReply struct {
	Action    string `json:"action"`
	Container string `json:"container"`
	Off       bool   `json:"off,omitempty"`
	Refused   string `json:"refused,omitempty"`
}

// logs opens GET /containers/{id}/logs for the lines the wire format
// carries: both streams, with timestamps, the last tail lines (or, with a
// non-zero since, every line stamped since then) and, with follow, every new
// one until ctx ends or Docker closes the stream. The caller closes the body.
func (c *dockerClient) logs(ctx context.Context, id string, follow bool, tail int, since time.Time) (io.ReadCloser, error) {
	followFlag := 0
	if follow {
		followFlag = 1
	}
	lines := strconv.Itoa(tail)
	if !since.IsZero() {
		lines = fmt.Sprintf("all&since=%d.%09d", since.Unix(), since.Nanosecond())
	}
	path := fmt.Sprintf("/containers/%s/logs?follow=%d&stdout=1&stderr=1&timestamps=1&tail=%s", url.PathEscape(id), followFlag, lines)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.base+path, nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.stream.Do(req)
	if err != nil {
		return nil, fmt.Errorf("GET %s: %w", path, err)
	}
	switch {
	case resp.StatusCode == http.StatusNotFound:
		resp.Body.Close()
		return nil, fmt.Errorf("GET %s: %w", path, errNotFound)
	case resp.StatusCode != http.StatusOK:
		resp.Body.Close()
		return nil, fmt.Errorf("GET %s: unexpected status %s", path, resp.Status)
	}
	return resp.Body, nil
}

// readLogs turns a Docker log stream into lines, calling emit for each until
// the stream ends or emit reports false. Without a TTY the stream is
// multiplexed: 8-byte frame headers (byte 0 the stream, 1 stdout and 2
// stderr, bytes 4-7 the big-endian payload length), and a line may span
// frames while the other stream's lines come in between, so each stream keeps
// its own partial line. With a TTY the stream is raw and all of it is stdout.
// A stream that ends cleanly returns nil; a partial last line is emitted
// either way.
func readLogs(r io.Reader, tty bool, emit func(logLine) bool) error {
	var out, errs lineSplitter
	out.stream, errs.stream = streamOut, streamErr
	finish := func(err error) error {
		if out.flush(emit) {
			errs.flush(emit)
		}
		return err
	}

	buf := make([]byte, readChunk)
	if tty { // whole chunks straight from the stream: no frames to parse
		for {
			n, err := r.Read(buf)
			if !out.write(buf[:n], emit) {
				return nil
			}
			if err != nil {
				return finish(cleanEOF(err))
			}
		}
	}

	br := bufio.NewReaderSize(r, readChunk)
	var header [8]byte
	for {
		if _, err := io.ReadFull(br, header[:]); err != nil {
			return finish(cleanEOF(err))
		}
		if header[1]|header[2]|header[3] != 0 || header[0] > 2 {
			return finish(errBadFrame)
		}
		sp := &out
		if header[0] == 2 {
			sp = &errs
		}
		for left := int64(binary.BigEndian.Uint32(header[4:])); left > 0; {
			n, err := br.Read(buf[:min(left, int64(len(buf)))])
			left -= int64(n)
			if !sp.write(buf[:n], emit) {
				return nil
			}
			if err != nil {
				if err == io.EOF { // the frame promised more
					err = io.ErrUnexpectedEOF
				}
				return finish(err)
			}
		}
	}
}

// cleanEOF is nil for the end of a stream and err for anything else,
// including a stream cut off in the middle of a header.
func cleanEOF(err error) error {
	if err == io.EOF {
		return nil
	}
	return err
}

// lineSplitter assembles one stream's lines from chunks that cut them anywhere.
type lineSplitter struct {
	stream string
	buf    []byte // the partial line, at most maxRawLine bytes
}

// write adds p and emits every line it completes. It reports false once emit does.
func (s *lineSplitter) write(p []byte, emit func(logLine) bool) bool {
	for len(p) > 0 {
		i := bytes.IndexByte(p, '\n')
		chunk := p
		if i >= 0 {
			chunk = p[:i]
		}
		s.buf = append(s.buf, chunk[:min(len(chunk), maxRawLine-len(s.buf))]...)
		if i < 0 {
			return true
		}
		if !s.flush(emit) {
			return false
		}
		p = p[i+1:]
	}
	return true
}

// flush emits the partial line, if there is one.
func (s *lineSplitter) flush(emit func(logLine) bool) bool {
	raw := s.buf
	s.buf = s.buf[:0]
	if len(raw) == 0 {
		return true
	}
	return emit(parseLine(raw, s.stream))
}

// parseLine splits Docker's timestamp off a raw line and cleans the message.
// A line that does not start with a timestamp keeps all of itself as the
// message and has an empty t.
func parseLine(raw []byte, stream string) logLine {
	l := logLine{S: stream}
	if i := bytes.IndexByte(raw, ' '); i > 0 && i <= maxTimestamp {
		if at, err := time.Parse(time.RFC3339Nano, string(raw[:i])); err == nil {
			l.T, l.at, raw = string(raw[:i]), at, raw[i+1:]
		}
	}
	l.M = cleanMessage(raw)
	return l
}

// cleanMessage makes a message fit the wire format: no trailing \r, every
// invalid UTF-8 byte replaced with U+FFFD, and at most maxLineBytes bytes
// (cut between runes) followed by an ellipsis.
func cleanMessage(raw []byte) string {
	s := string(bytes.TrimSuffix(raw, []byte("\r")))
	if !utf8.ValidString(s) {
		var b strings.Builder
		for i := 0; i < len(s); {
			r, size := utf8.DecodeRuneInString(s[i:])
			if r == utf8.RuneError && size == 1 {
				b.WriteRune(utf8.RuneError)
			} else {
				b.WriteString(s[i : i+size])
			}
			i += size
		}
		s = b.String()
	}
	if len(s) > maxLineBytes {
		cut := maxLineBytes
		for !utf8.RuneStart(s[cut]) {
			cut--
		}
		s = s[:cut] + "…"
	}
	return s
}

// validContainerID is a full container id: 64 lowercase hex digits.
func validContainerID(id string) bool { return len(id) == 64 && isHex(id) }

func isHex(s string) bool {
	for i := range len(s) {
		if c := s[i]; (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}
