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
	// The reader may run this many lines ahead of the batcher, which is as
	// far as one slow WebSocket write can back Docker's stream up.
	linesAhead     = 64
	backlogTimeout = 15 * time.Second // the one-shot fetch of history
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

	sweepEvery time.Duration
	batchEvery time.Duration

	followers map[string]*follower // by full container id; owned by run
	wg        sync.WaitGroup       // every follower and fetch goroutine
}

func newTailer(docker *dockerClient, send func([]byte) bool, log *slog.Logger, now func() time.Time, enabled bool, self string) *tailer {
	return &tailer{
		docker:     docker,
		send:       send,
		log:        log,
		now:        now,
		enabled:    enabled,
		self:       self,
		sweepEvery: sweepInterval,
		batchEvery: batchEvery,
		followers:  map[string]*follower{},
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
			t.guard("tail", func() { t.handle(ctx, req) })
		case <-ticker.C:
			t.guard("sweep", t.sweep)
		}
	}
}

func (t *tailer) guard(what string, fn func()) {
	defer recoverPanic(t.log, what)
	fn()
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

func (t *tailer) newBatcher(id string) *batcher {
	b := newBatcher(id, time.Now, t.sendBatch)
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
// why it refused a container, and reports ended when Docker closes the stream.
// A follower that was cancelled says nothing.
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
	body, err := t.docker.logs(f.ctx, f.id, true, f.backlog)
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
	defer body.Close()
	t.log.Debug("following container logs", "container", short(f.id), "backlog", f.backlog)
	f.pump(body, since)
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
// stream waits with it.
func (f *follower) pump(body io.Reader, since time.Time) {
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

	b := f.t.newBatcher(f.id)
	ticker := time.NewTicker(max(f.t.batchEvery/5, time.Millisecond))
	defer ticker.Stop()
	for {
		select {
		case <-f.ctx.Done():
			return
		case l, ok := <-lines:
			if !ok { // Docker closed the stream
				if f.ctx.Err() == nil {
					if readErr != nil {
						f.t.log.Warn("container logs: the stream broke", "container", short(f.id), "error", readErr)
					}
					b.finish()
				}
				return
			}
			b.add(l, f.backlog > 0 && !l.at.IsZero() && !l.at.After(since))
		case <-ticker.C:
			b.flushDue()
		}
	}
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
	body, err := f.t.docker.logs(ctx, f.id, false, n)
	if err != nil {
		if ctx.Err() == nil {
			f.t.log.Warn("container logs: cannot fetch the backlog", "container", short(f.id), "error", err)
		}
		return
	}
	defer body.Close()
	b := f.t.newBatcher(f.id)
	readLogs(body, f.tty, func(l logLine) bool {
		b.add(l, true)
		return ctx.Err() == nil
	})
	if ctx.Err() == nil {
		b.flush(false)
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
