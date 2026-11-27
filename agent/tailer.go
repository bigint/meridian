package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	maxTailed     = 20          // containers followed at once
	maxBacklog    = 1000        // lines one tail may ask for
	sweepInterval = time.Second // how often lapsed leases are noticed
	// A follow stream Docker closed while the container still runs (the socket
	// proxy cuts streams idle for 10 minutes) is reopened after this pause.
	reopenInterval = time.Second
	// The reader may run this many lines ahead of the batcher, which is as
	// far as one slow WebSocket write can back Docker's stream up.
	linesAhead     = 64
	backlogTimeout = 15 * time.Second // the one-shot fetch of history
	// Followers send at most maxTailed batches per batchEvery, 80 a second,
	// of the 100 log frames a second Meridian accepts from an agent. History
	// fetched beside a follow has its own batcher, so the fetches share this
	// many a second between them, which keeps the total under the cap.
	historyBatchesPerSecond = 10
)

// Why a tail is refused. Meridian shows these.
const (
	refusedNotFound = "container not found"
	refusedNotKamal = "not a Kamal container"
	refusedSelf     = "the agent's own container"
	refusedCap      = "too many containers are being tailed"
	refusedDocker   = "cannot read the container's logs"
)

// tailRequest is a {"type":"tail"} message the line has parsed.
type tailRequest struct {
	container string // a full container id
	seconds   int
	backlog   int // 0 to maxBacklog
}

// tailer follows containers' logs while somebody reads them. It owns the
// followers: one per container, each with its own lease and context, kept in
// a map only run touches. A tail message starts a follower or extends its
// lease; run's ticker cancels the ones whose lease has lapsed, and with them
// their Docker streams. Everything slow (the inspect, the stream) happens in
// the follower's goroutines, so run never waits on Docker.
type tailer struct {
	docker  *dockerClient
	send    func(frame []byte) bool
	log     *slog.Logger
	now     func() time.Time // leases, and where history ends and live lines begin
	enabled bool             // MERIDIAN_LOGS
	self    string           // the agent's own container id, or its first 12 digits; never tailed

	sweepEvery  time.Duration
	batchEvery  time.Duration
	reopenAfter time.Duration

	followers map[string]*follower // by full container id; owned by run
	wg        sync.WaitGroup       // every follower and fetch goroutine
	history   pacer                // spaces the batches of history fetches
}

func newTailer(docker *dockerClient, send func([]byte) bool, log *slog.Logger, now func() time.Time, enabled bool, self string) *tailer {
	return &tailer{
		docker:      docker,
		send:        send,
		log:         log,
		now:         now,
		enabled:     enabled,
		self:        self,
		sweepEvery:  sweepInterval,
		batchEvery:  batchEvery,
		reopenAfter: reopenInterval,
		followers:   map[string]*follower{},
		history:     pacer{gap: time.Second / historyBatchesPerSecond},
	}
}

// run handles tail messages and expires leases until ctx ends, then waits for
// every stream it started to close.
func (t *tailer) run(ctx context.Context, tails <-chan tailRequest) {
	defer recoverPanic(t.log, "tailer")
	defer t.wg.Wait()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	ticker := time.NewTicker(t.sweepEvery)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case req := <-tails:
			guard(t.log, "tail", func() { t.handle(ctx, req) })
		case <-ticker.C:
			guard(t.log, "sweep", t.sweep)
		}
	}
}

// handle is the lease rule per container, as the sampler has it for a whole
// host: a follower's lease is max(until, now + min(seconds, 120 s)).
func (t *tailer) handle(ctx context.Context, req tailRequest) {
	if !t.enabled {
		t.reply(logReply{Container: req.container, Off: true})
		return
	}
	if req.seconds <= 0 {
		return
	}
	for id, f := range t.followers {
		if f.done.Load() { // ended on its own; a new tail starts it afresh
			delete(t.followers, id)
		}
	}

	if f, ok := t.followers[req.container]; ok {
		f.lease.watch(req.seconds)
		// Already following: the history is a separate, one-shot request. At
		// most one runs per container; the follow itself is never touched.
		if req.backlog > 0 && f.fetching.CompareAndSwap(false, true) {
			t.wg.Go(func() { f.fetchBacklog(req.backlog) })
		}
		return
	}
	if len(t.followers) >= maxTailed {
		t.reply(logReply{Container: req.container, Refused: refusedCap})
		return
	}
	fctx, cancel := context.WithCancel(ctx)
	f := &follower{t: t, id: req.container, backlog: req.backlog, ctx: fctx, cancel: cancel, ready: make(chan struct{}), lease: lease{now: t.now}}
	f.lease.watch(req.seconds)
	t.followers[req.container] = f
	t.wg.Go(f.run)
}

// sweep cancels followers whose lease has lapsed or that have ended.
func (t *tailer) sweep() {
	for id, f := range t.followers {
		if f.done.Load() || !f.lease.live() {
			f.cancel()
			delete(t.followers, id)
		}
	}
}

func (t *tailer) reply(r logReply) {
	r.Action = "logs"
	t.sendJSON(r)
}

func (t *tailer) sendBatch(b logBatch) { t.sendJSON(b) }

// sendJSON hands a message to the line, which drops it unless it is subscribed.
func (t *tailer) sendJSON(v any) {
	body, err := json.Marshal(v)
	if err != nil {
		t.log.Error("container logs: cannot encode message", "error", err)
		return
	}
	t.send(body)
}

// newBatcher batches on the wall clock, not t.now: batches pace what goes
// on the wire, while t.now only measures leases and tests move it by hand.
func (t *tailer) newBatcher(id string, emit func(logBatch)) *batcher {
	b := newBatcher(id, time.Now, emit)
	b.every = t.batchEvery
	return b
}

// follower follows one container's logs from the first tail until its lease
// lapses, Docker closes the stream, or the container is refused.
type follower struct {
	t       *tailer
	id      string
	backlog int // history lines the first tail asked for
	ctx     context.Context
	cancel  context.CancelFunc
	lease   lease // owned by the tailer's run

	done     atomic.Bool   // run has returned
	fetching atomic.Bool   // a history fetch is in flight
	ready    chan struct{} // closed once the container is accepted; tty is valid then
	tty      bool
}

// run checks the container, then follows it until it ends. It tells Meridian
// why it refused a container, and reports ended once Docker closes the stream
// and the container is no longer running. A stream closed under a running
// container is reopened from the last line it carried. A follower that was
// cancelled says nothing.
func (f *follower) run() {
	t := f.t
	defer f.cancel() // wakes a history fetch still waiting for ready
	defer f.done.Store(true)
	defer recoverPanic(t.log, "log follower")

	in, refusal := f.admit()
	if f.ctx.Err() != nil {
		return
	}
	if refusal != "" {
		t.reply(logReply{Container: f.id, Refused: refusal})
		return
	}
	f.tty = in.Config.Tty
	close(f.ready)
	if in.State.Status != "running" && f.backlog == 0 {
		// Nothing to replay and nothing new to come: it already reported ended.
		// A later tail follows it once it runs again.
		return
	}

	// History is everything logged up to now; the clock Docker stamps lines
	// with is this host's.
	since := t.now()
	body, err := t.docker.logs(f.ctx, f.id, true, f.backlog, time.Time{})
	if err != nil {
		if f.ctx.Err() == nil {
			refusal := refusedDocker
			if errors.Is(err, errNotFound) { // removed since the inspect
				refusal = refusedNotFound
			} else {
				t.log.Warn("container logs: cannot open the stream", "container", short(f.id), "error", err)
			}
			t.reply(logReply{Container: f.id, Refused: refusal})
		}
		return
	}
	t.log.Debug("following container logs", "container", short(f.id), "backlog", f.backlog)
	b := t.newBatcher(f.id, t.sendBatch)
	from := since
	for {
		last := f.pump(body, since, b)
		body.Close()
		if f.ctx.Err() != nil {
			return
		}
		if last.After(from) {
			from = last
		}
		if !f.stillRunning() {
			b.finish()
			return
		}
		select { // a pause, so a stream that keeps closing cannot spin
		case <-f.ctx.Done():
			return
		case <-time.After(t.reopenAfter):
		}
		// Docker's since includes lines stamped exactly then: skip the last one.
		if body, err = t.docker.logs(f.ctx, f.id, true, 0, from.Add(time.Nanosecond)); err != nil {
			if f.ctx.Err() == nil {
				t.log.Warn("container logs: cannot reopen the stream", "container", short(f.id), "error", err)
				b.finish()
			}
			return
		}
	}
}

// stillRunning asks Docker again whether the container runs, after its
// follow stream closed.
func (f *follower) stillRunning() bool {
	ctx, cancel := context.WithTimeout(f.ctx, dockerTimeout)
	defer cancel()
	in, err := f.t.docker.inspectContainer(ctx, f.id)
	return err == nil && in.ID == f.id && in.State.Status == "running"
}

// admit is the check Meridian's say-so never replaces: the container exists
// and is Kamal's, and is not the agent itself. It returns what to refuse with.
func (f *follower) admit() (inspectedContainer, string) {
	t := f.t
	if t.self != "" && strings.HasPrefix(f.id, t.self) {
		return inspectedContainer{}, refusedSelf
	}
	ctx, cancel := context.WithTimeout(f.ctx, dockerTimeout)
	defer cancel()
	in, err := t.docker.inspectContainer(ctx, f.id)
	switch {
	case errors.Is(err, errNotFound):
		return in, refusedNotFound
	case err != nil:
		if f.ctx.Err() == nil {
			t.log.Warn("container logs: cannot inspect the container", "container", short(f.id), "error", err)
		}
		return in, refusedDocker
	case in.ID != f.id: // an id that is really a name or a prefix
		return in, refusedNotFound
	}
	if _, ok := classify(strings.TrimPrefix(in.Name, "/"), in.Config.Labels); !ok {
		return in, refusedNotKamal
	}
	return in, ""
}

// pump reads the stream in one goroutine and batches it in this one, so a
// slow write to Meridian never stops the batch timer. The channel between
// them is small: when it is full the reader waits, and Docker's side of the
// stream waits with it. Live lines beyond one full batch per batchEvery are
// dropped and counted, never waited for, so the reader keeps up with Docker.
// It returns when ctx ends or Docker closes the stream, with the latest stamp
// it read; what is left in b is the caller's.
func (f *follower) pump(body io.Reader, since time.Time, b *batcher) (last time.Time) {
	lines := make(chan logLine, linesAhead)
	var readErr error
	go func() {
		defer close(lines)
		defer recoverPanic(f.t.log, "log reader")
		readErr = readLogs(body, f.tty, func(l logLine) bool {
			select {
			case lines <- l:
				return true
			case <-f.ctx.Done():
				return false
			}
		})
	}()

	ticker := time.NewTicker(max(f.t.batchEvery/5, time.Millisecond))
	defer ticker.Stop()
	for {
		select {
		case <-f.ctx.Done():
			return last
		case l, ok := <-lines:
			if !ok { // Docker closed the stream
				if f.ctx.Err() == nil && readErr != nil {
					f.t.log.Warn("container logs: the stream broke", "container", short(f.id), "error", readErr)
				}
				return last
			}
			if l.at.After(last) {
				last = l.at
			}
			history := f.backlog > 0 && !l.at.IsZero() && !l.at.After(since)
			if b.held() {
				// The batch is full and the last went out under batchEvery
				// ago. A live line is dropped and counted: waiting for it
				// would leave the reader further behind Docker every second
				// the container logs this fast. The backlog is bounded, so
				// it waits its turn instead.
				if !history {
					b.skip()
					continue
				}
				if !f.waitTurn(b) {
					return last
				}
			}
			b.add(l, history)
		case <-ticker.C:
			b.flushDue()
		}
	}
}

// waitTurn waits until the held batch b may go out, then sends it. It
// returns false if ctx ended first.
func (f *follower) waitTurn(b *batcher) bool {
	for b.held() {
		select {
		case <-f.ctx.Done():
			return false
		case <-time.After(b.wait()):
		}
	}
	b.flushDue()
	return true
}

// fetchBacklog sends the last n lines of an already followed container as
// backlog batches, from a separate non-following request.
func (f *follower) fetchBacklog(n int) {
	defer f.fetching.Store(false)
	defer recoverPanic(f.t.log, "log backlog")
	select {
	case <-f.ready:
	case <-f.ctx.Done():
		return
	}
	ctx, cancel := context.WithTimeout(f.ctx, backlogTimeout)
	defer cancel()
	body, err := f.t.docker.logs(ctx, f.id, false, n, time.Time{})
	if err != nil {
		if ctx.Err() == nil {
			f.t.log.Warn("container logs: cannot fetch the backlog", "container", short(f.id), "error", err)
		}
		return
	}
	defer body.Close()
	b := f.t.newBatcher(f.id, func(lb logBatch) {
		if f.t.history.wait(ctx) {
			f.t.sendBatch(lb)
		}
	})
	readLogs(body, f.tty, func(l logLine) bool {
		for b.held() {
			select {
			case <-ctx.Done():
				return false
			case <-time.After(b.wait()):
			}
		}
		b.add(l, true)
		return ctx.Err() == nil
	})
	if ctx.Err() == nil {
		b.flush(false)
	}
}

// pacer spaces calls to wait at least gap apart, across goroutines.
type pacer struct {
	gap time.Duration

	mu   sync.Mutex
	next time.Time // the earliest the next turn may start
}

// wait blocks until this caller's turn, and reports false if ctx ended first.
func (p *pacer) wait(ctx context.Context) bool {
	p.mu.Lock()
	at := time.Now()
	if p.next.After(at) {
		at = p.next
	}
	p.next = at.Add(p.gap)
	p.mu.Unlock()

	timer := time.NewTimer(time.Until(at))
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

// short is a container id as the docker CLI shows it, for log lines.
func short(id string) string { return id[:min(len(id), 12)] }

// ownMountRE finds the container's own id in /proc/self/mountinfo: Docker
// bind-mounts hostname, hosts and resolv.conf from /var/lib/docker/containers/<id>/.
var ownMountRE = regexp.MustCompile(`/containers/([0-9a-f]{64})/(?:hostname|hosts|resolv\.conf) /etc/`)

// ownContainerID is the id of the container the agent runs in: the full id
// when the mounts show it, else the first 12 digits when the hostname is
// Docker's default (the short id). It is "" when neither says.
func ownContainerID(readFile func(string) ([]byte, error), hostname func() (string, error)) string {
	if b, err := readFile("/proc/self/mountinfo"); err == nil {
		if m := ownMountRE.FindSubmatch(b); m != nil {
			return string(m[1])
		}
	}
	if h, err := hostname(); err == nil && len(h) == 12 && isHex(h) {
		return h
	}
	return ""
}
