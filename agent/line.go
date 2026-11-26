package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"
)

const (
	cablePath     = "/cable"
	cableProtocol = "actioncable-v1-json"
	cableChannel  = "AgentChannel"
)

var (
	// errRefused means the server does not want this agent: a revoked token,
	// or a disconnect that says not to reconnect. The line backs off long.
	errRefused        = errors.New("refused by Meridian")
	errRejected       = errors.New("subscription rejected")
	errConfirmTimeout = errors.New("subscription was not confirmed in time")
)

type lineTimings struct {
	readTimeout    time.Duration // silence from the server that means a dead line
	confirmTimeout time.Duration // open, but never confirmed
	backoffBase    time.Duration // first retry delay, doubled per failure
	backoffMax     time.Duration
	refusedBackoff time.Duration // after errRefused
}

// ActionCable pings every 3s, so 10s of silence means the line is dead.
var defaultLineTimings = lineTimings{
	readTimeout:    10 * time.Second,
	confirmTimeout: 15 * time.Second,
	backoffBase:    5 * time.Second,
	backoffMax:     time.Minute,
	refusedBackoff: maxBackoff,
}

// line is the agent's one outbound WebSocket into Meridian's ActionCable.
// run owns the session lifecycle, send puts a frame on the wire while the
// line is subscribed, and the leases the server sends arrive on watches
// (stats) and tails (container logs).
type line struct {
	endpoint   string
	origin     string
	token      string
	identifier string // the channel identifier; byte-identical in every command
	subscribe  []byte
	client     *http.Client
	log        *slog.Logger
	rand       func() float64
	timings    lineTimings
	wait       func(ctx context.Context, d time.Duration) error // between sessions; tests replace it
	watches    chan int                                         // seconds from watch messages
	tails      chan tailRequest                                 // tail messages

	mu sync.Mutex
	ws *wsConn // set only while subscribed: frames may be sent
}

func newLine(cfg config, log *slog.Logger, rnd func() float64) (*line, error) {
	u, err := url.Parse(cfg.url)
	if err != nil || u.Host == "" {
		return nil, fmt.Errorf("cannot derive the websocket address from %q", cfg.url)
	}
	identifier, err := json.Marshal(struct {
		Channel   string `json:"channel"`
		MachineID string `json:"machine_id"`
	}{cableChannel, cfg.machineID})
	if err != nil {
		return nil, err
	}
	subscribe, err := json.Marshal(cableCommand{Command: "subscribe", Identifier: string(identifier)})
	if err != nil {
		return nil, err
	}
	return &line{
		endpoint:   cfg.url + cablePath,
		origin:     u.Scheme + "://" + u.Host,
		token:      cfg.token,
		identifier: string(identifier),
		subscribe:  subscribe,
		client:     newLineClient(),
		log:        log,
		rand:       rnd,
		timings:    defaultLineTimings,
		wait:       sleepCtx,
		watches:    make(chan int, 8),
		tails:      make(chan tailRequest, 32),
	}, nil
}

// newLineClient has no overall Timeout, which would cut the stream off.
// Redirects are not followed: the Origin and token belong to one host.
func newLineClient() *http.Client {
	return &http.Client{
		Transport: &http.Transport{
			Proxy:                 http.ProxyFromEnvironment,
			DialContext:           (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
			TLSHandshakeTimeout:   10 * time.Second,
			ResponseHeaderTimeout: 10 * time.Second,
			DisableKeepAlives:     true,
		},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

// cableCommand is what the agent sends.
type cableCommand struct {
	Command    string `json:"command"`
	Identifier string `json:"identifier"`
	Data       string `json:"data,omitempty"`
}

// cableMessage is what the server sends: a typed control message (welcome,
// ping, confirm_subscription, ...) or, with no type, a channel message.
type cableMessage struct {
	Type       string          `json:"type"`
	Identifier string          `json:"identifier"`
	Reason     string          `json:"reason"`
	Reconnect  *bool           `json:"reconnect"`
	Message    json.RawMessage `json:"message"`
}

// run connects, serves one session at a time and backs off between them,
// until ctx ends.
func (l *line) run(ctx context.Context) {
	defer recoverPanic(l.log, "line")
	failures := 0
	for ctx.Err() == nil {
		confirmed, err := l.session(ctx)
		if ctx.Err() != nil {
			return
		}
		var delay time.Duration
		if errors.Is(err, errRefused) {
			failures = 0
			delay = jittered(l.timings.refusedBackoff, l.rand())
			l.log.Error("meridian refused the live line; is the agent token valid?", "error", err, "retry_in", delay.Round(time.Second).String())
		} else {
			if confirmed { // a clean session resets the backoff
				failures = 0
			}
			failures++
			delay = retryDelay(l.timings.backoffBase, l.timings.backoffMax, failures, l.rand())
			l.log.Warn("live line down", "error", err, "retry_in", delay.Round(time.Millisecond).String())
		}
		if l.wait(ctx, delay) != nil {
			return
		}
	}
}

// session is one pass through dialing, subscribing and live. It returns why
// the session ended, and whether it got as far as a confirmed subscription.
func (l *line) session(ctx context.Context) (confirmed bool, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("recovered from panic: %v", r)
		}
	}()

	header := http.Header{}
	header.Set("Authorization", "Bearer "+l.token)
	header.Set("Origin", l.origin)
	header.Set("User-Agent", "meridian-agent/"+version)
	ws, err := dialWS(ctx, l.client, l.endpoint, header, cableProtocol, l.timings.readTimeout)
	if err != nil {
		var he *handshakeError
		if errors.As(err, &he) && (he.status == http.StatusUnauthorized || he.status == http.StatusForbidden) {
			err = fmt.Errorf("%w: %w", errRefused, err)
		}
		return false, err
	}

	stopCtxWatch := context.AfterFunc(ctx, ws.shutdown)
	confirmDog := newWatchdog(l.timings.confirmTimeout, ws.close)
	defer func() {
		stopCtxWatch()
		confirmDog.stop()
		l.setLive(nil)
		ws.shutdown()
	}()

	for {
		raw, err := ws.readMessage()
		if err != nil {
			if confirmDog.didFire() {
				err = errConfirmTimeout
			}
			return confirmed, err
		}
		var m cableMessage
		if json.Unmarshal(raw, &m) != nil {
			continue
		}
		switch m.Type {
		case "welcome":
			if err := ws.writeText(l.subscribe); err != nil {
				return confirmed, err
			}
		case "confirm_subscription":
			if m.Identifier == l.identifier && !confirmed {
				confirmed = true
				confirmDog.stop()
				l.setLive(ws)
				l.log.Info("live line subscribed")
			}
		case "reject_subscription":
			return confirmed, errRejected
		case "disconnect":
			if m.Reason == "unauthorized" || (m.Reconnect != nil && !*m.Reconnect) {
				return confirmed, fmt.Errorf("%w: disconnected with reason %q", errRefused, m.Reason)
			}
			return confirmed, fmt.Errorf("server disconnected us: reason %q", m.Reason)
		case "":
			l.deliver(m)
		}
		// Pings and unknown types need nothing: any frame already showed the
		// server is alive.
	}
}

// deliver hands a {"type":"watch","seconds":n} message to the sampler and a
// {"type":"tail","container":id,"seconds":n,"backlog":n} message to the
// tailer. Neither waits: when its owner is busy the message is dropped, and
// the next renewal does the job. Everything else on the channel is ignored,
// for forward compatibility.
func (l *line) deliver(m cableMessage) {
	var msg struct {
		Type      string `json:"type"`
		Seconds   int    `json:"seconds"`
		Container string `json:"container"`
		Backlog   int    `json:"backlog"`
	}
	if m.Identifier != l.identifier || json.Unmarshal(m.Message, &msg) != nil {
		return
	}
	switch msg.Type {
	case "watch":
		select {
		case l.watches <- msg.Seconds:
		default:
			l.log.Debug("watch dropped: the sampler is busy")
		}
	case "tail":
		if !validContainerID(msg.Container) {
			return
		}
		req := tailRequest{container: msg.Container, seconds: msg.Seconds, backlog: min(max(msg.Backlog, 0), maxBacklog)}
		select {
		case l.tails <- req:
		default:
			l.log.Debug("tail dropped: the tailer is busy")
		}
	}
}

// send puts one frame (the JSON for the command's data field) on the
// wire. Frames are never queued: unless the line is subscribed right now,
// the frame is dropped and send reports false.
func (l *line) send(frame []byte) bool {
	l.mu.Lock()
	ws := l.ws
	l.mu.Unlock()
	if ws == nil {
		return false
	}
	cmd, err := json.Marshal(cableCommand{Command: "message", Identifier: l.identifier, Data: string(frame)})
	if err != nil {
		return false
	}
	return ws.writeText(cmd) == nil
}

func (l *line) setLive(ws *wsConn) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.ws = ws
}

// retryDelay is base doubled per failure past the first, capped at ceiling,
// then jittered by ±20%.
func retryDelay(base, ceiling time.Duration, failures int, r float64) time.Duration {
	d := base
	for i := 1; i < failures && d < ceiling; i++ {
		d *= 2
	}
	return jittered(min(d, ceiling), r)
}

// jittered scales d by a factor in [0.8, 1.2) from r in [0, 1).
func jittered(d time.Duration, r float64) time.Duration {
	return time.Duration(float64(d) * (0.8 + 0.4*r))
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}
