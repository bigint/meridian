package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	frameInterval     = time.Second
	reconcileInterval = 5 * time.Second
	maxLiveContainers = 500
	// A stream that has not produced a sample for this long is not reported
	// until it recovers, so a stalled container never shows frozen numbers.
	staleAfter = 5 * time.Second
)

// liveFrame is the data of one stats message.
type liveFrame struct {
	Action     string           `json:"action"`
	Host       *hostFrame       `json:"host,omitempty"`
	Containers []containerFrame `json:"containers"`
}

// sampler streams stats while somebody is watching. Each lease that turns the
// sampler live opens a liveWindow: one stats stream per running Kamal
// container, reconciled every few seconds. Once a second a frame goes to
// send. When the lease lapses the window is cancelled and every stream with it.
type sampler struct {
	docker *dockerClient
	host   *hostMetrics
	send   func(frame []byte) bool
	log    *slog.Logger
	now    func() time.Time

	frameEvery     time.Duration
	reconcileEvery time.Duration

	lease lease       // owned by run
	win   *liveWindow // owned by run; nil while nobody watches
}

func newSampler(docker *dockerClient, host *hostMetrics, send func([]byte) bool, log *slog.Logger, now func() time.Time) *sampler {
	return &sampler{
		docker:         docker,
		host:           host,
		send:           send,
		log:            log,
		now:            now,
		frameEvery:     frameInterval,
		reconcileEvery: reconcileInterval,
		lease:          lease{now: now},
	}
}

// liveWindow is the streams of one live period. The reconcile goroutine
// writes streams and the frame loop reads them, both under mu.
type liveWindow struct {
	ctx     context.Context
	cancel  context.CancelFunc
	mu      sync.Mutex
	streams map[string]*stream // by full container id
}

// run is the live loop. It owns the lease: watch seconds arrive on watches,
// and the frame ticker notices when the lease has lapsed.
func (s *sampler) run(ctx context.Context, watches <-chan int) {
	defer recoverPanic(s.log, "sampler")
	ticker := time.NewTicker(s.frameEvery)
	defer ticker.Stop()
	defer s.stopLive()
	for {
		select {
		case <-ctx.Done():
			return
		case seconds := <-watches:
			s.lease.watch(seconds)
			if s.win == nil && s.lease.live() {
				guard(s.log, "start", func() { s.startLive(ctx) })
			}
		case <-ticker.C:
			if s.win != nil && !s.lease.live() {
				s.stopLive()
			}
			if s.win != nil {
				guard(s.log, "frame", s.sendFrame)
			}
		}
	}
}

func (s *sampler) startLive(ctx context.Context) {
	wctx, cancel := context.WithCancel(ctx)
	w := &liveWindow{ctx: wctx, cancel: cancel, streams: map[string]*stream{}}
	s.win = w
	s.host.reset()
	go func() {
		defer recoverPanic(s.log, "reconcile loop")
		t := time.NewTicker(s.reconcileEvery)
		defer t.Stop()
		for {
			guard(s.log, "reconcile", func() { s.reconcile(w) })
			select {
			case <-w.ctx.Done():
				return
			case <-t.C:
			}
		}
	}()
}

// stopLive cancels the window, and with it every stats stream.
func (s *sampler) stopLive() {
	if s.win != nil {
		s.win.cancel()
		s.win = nil
	}
}

// reconcile starts a stream for each running Kamal container that has none,
// and cancels the streams of containers that are gone or whose stream ended.
func (s *sampler) reconcile(w *liveWindow) {
	ctx, cancel := context.WithTimeout(w.ctx, dockerTimeout)
	defer cancel()
	listed, err := s.docker.listContainers(ctx)
	if err != nil {
		if w.ctx.Err() == nil {
			s.log.Warn("live stats: cannot list containers", "error", err)
		}
		return
	}
	want := liveContainerIDs(listed)

	w.mu.Lock()
	defer w.mu.Unlock()
	var failed int
	var firstErr error
	for id, st := range w.streams {
		_, wanted := want[id]
		if wanted && !st.done.Load() {
			continue
		}
		if err := st.failure(); err != nil && wanted {
			failed++
			if firstErr == nil {
				firstErr = err
			}
		}
		st.cancel()
		delete(w.streams, id) // a wanted one is restarted just below
	}
	for id := range want {
		if _, ok := w.streams[id]; !ok {
			w.streams[id] = s.startStream(w.ctx, id)
		}
	}
	if failed > 0 {
		s.log.Warn("live stats: streams ended early and are being restarted", "streams", failed, "first_error", firstErr)
	}
}

// liveContainerIDs is the running Kamal containers (the same classify filter
// snapshots use), at most maxLiveContainers of them, lowest ids first.
func liveContainerIDs(listed []listedContainer) map[string]struct{} {
	var ids []string
	for _, c := range listed {
		if c.State != "running" {
			continue
		}
		if _, ok := classify(containerName(c.Names), c.Labels); ok {
			ids = append(ids, c.ID)
		}
	}
	slices.Sort(ids)
	ids = ids[:min(len(ids), maxLiveContainers)]
	set := make(map[string]struct{}, len(ids))
	for _, id := range ids {
		set[id] = struct{}{}
	}
	return set
}

func (s *sampler) startStream(parent context.Context, id string) *stream {
	ctx, cancel := context.WithCancel(parent)
	st := &stream{cancel: cancel}
	go func() {
		defer st.done.Store(true)
		defer recoverPanic(s.log, "stats stream")
		err := s.docker.streamStats(ctx, id, func(c counters) { st.add(c, s.now()) })
		if ctx.Err() == nil && err != nil && !errors.Is(err, errNotFound) {
			st.fail(err)
		}
	}()
	return st
}

// sendFrame builds this second's frame from the host and the latest two
// samples of every stream, and hands it to the line.
func (s *sampler) sendFrame() {
	frame := liveFrame{Action: "stats", Containers: []containerFrame{}}
	if h, ok := s.host.sample(); ok {
		frame.Host = &h
	}
	now := s.now()
	s.win.mu.Lock()
	for id, st := range s.win.streams {
		if c, ok := st.frame(id, now); ok {
			frame.Containers = append(frame.Containers, c)
		}
	}
	s.win.mu.Unlock()
	slices.SortFunc(frame.Containers, func(a, b containerFrame) int { return strings.Compare(a.ID, b.ID) })

	body, err := json.Marshal(frame)
	if err != nil {
		s.log.Error("live stats: cannot encode frame", "error", err)
		return
	}
	s.send(body)
}

// stream holds the latest two samples of one container's stats stream. The
// stream goroutine writes it and the frame loop reads it.
type stream struct {
	cancel context.CancelFunc
	done   atomic.Bool // the goroutine has returned

	mu      sync.Mutex
	prev    counters
	cur     counters
	samples int
	arrived time.Time
	err     error
}

func (st *stream) add(c counters, now time.Time) {
	st.mu.Lock()
	defer st.mu.Unlock()
	st.prev, st.cur = st.cur, c
	st.samples++
	st.arrived = now
}

func (st *stream) fail(err error) {
	st.mu.Lock()
	defer st.mu.Unlock()
	st.err = err
}

func (st *stream) failure() error {
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.err
}

// frame is this container's entry, once it has two samples to compare.
func (st *stream) frame(id string, now time.Time) (containerFrame, bool) {
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.samples < 2 || now.Sub(st.arrived) > staleAfter {
		return containerFrame{}, false
	}
	return frameBetween(id, st.prev, st.cur)
}
