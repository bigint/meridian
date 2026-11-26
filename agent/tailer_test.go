package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// ---- a fake Docker that serves inspect and logs ----

// logEntry is one line a container has logged. ts is Docker's stamp.
type logEntry struct {
	stream byte // 1 stdout, 2 stderr
	ts     string
	msg    string
}

type logSub struct {
	ch   chan logEntry
	end  chan struct{}
	once sync.Once
}

type logBox struct {
	logsStatus int    // the HTTP status the logs endpoint answers with, when not 200
	inspectID  string // what inspect answers with, when it is not the id asked for
	name       string
	labels     map[string]string
	tty        bool
	status     string
	history    []logEntry
	subs       map[*logSub]struct{}
}

// logDocker serves /containers/json, /containers/{id}/json and
// /containers/{id}/logs, and counts who is following whom. Following streams
// the history the request asks for, then whatever push adds, until end, until
// the client hangs up, or, for a container that is not running, right away.
type logDocker struct {
	srv *httptest.Server

	mu       sync.Mutex
	boxes    map[string]*logBox
	requests []string
	active   map[string]int // open follow streams by container id
	follows  map[string]int // follow requests by container id
}

func newLogDocker(t *testing.T) *logDocker {
	fd := &logDocker{boxes: map[string]*logBox{}, active: map[string]int{}, follows: map[string]int{}}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /containers/json", fd.list)
	mux.HandleFunc("GET /containers/{id}/json", fd.inspect)
	mux.HandleFunc("GET /containers/{id}/logs", fd.logs)
	fd.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fd.mu.Lock()
		fd.requests = append(fd.requests, r.URL.RequestURI())
		fd.mu.Unlock()
		mux.ServeHTTP(w, r)
	}))
	t.Cleanup(fd.srv.Close)
	return fd
}

func (fd *logDocker) docker(t *testing.T) *dockerClient { return mustDocker(t, fd.srv.URL) }

// kamalApp is a running Kamal app container (name and labels as classify wants).
func kamalApp(history ...logEntry) *logBox {
	return &logBox{name: "web-web-production-3f2a", labels: map[string]string{"service": "web", "role": "web"}, status: "running", history: history, subs: map[*logSub]struct{}{}}
}

func (fd *logDocker) add(id string, b *logBox) *logBox {
	fd.mu.Lock()
	defer fd.mu.Unlock()
	if b.subs == nil {
		b.subs = map[*logSub]struct{}{}
	}
	fd.boxes[id] = b
	return b
}

func (fd *logDocker) list(w http.ResponseWriter, r *http.Request) {
	type entry struct {
		ID     string            `json:"Id"`
		Names  []string          `json:"Names"`
		Labels map[string]string `json:"Labels"`
		State  string            `json:"State"`
	}
	fd.mu.Lock()
	var out []entry
	for id, b := range fd.boxes {
		out = append(out, entry{id, []string{"/" + b.name}, b.labels, b.status})
	}
	fd.mu.Unlock()
	json.NewEncoder(w).Encode(out)
}

func (fd *logDocker) inspect(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	fd.mu.Lock()
	b := fd.boxes[id]
	var body []byte
	if b != nil {
		reported := id
		if b.inspectID != "" {
			reported = b.inspectID
		}
		body, _ = json.Marshal(map[string]any{
			"Id": reported, "Name": "/" + b.name,
			"Config": map[string]any{"Image": "registry.example.com/web:3f2a", "Labels": b.labels, "Tty": b.tty},
			"State":  map[string]any{"Status": b.status},
		})
	}
	fd.mu.Unlock()
	if b == nil {
		http.Error(w, `{"message":"No such container"}`, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}

func (fd *logDocker) logs(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	q := r.URL.Query()
	follow := q.Get("follow") == "1"
	tail, _ := strconv.Atoi(q.Get("tail"))

	fd.mu.Lock()
	b := fd.boxes[id]
	if b == nil {
		fd.mu.Unlock()
		http.Error(w, `{"message":"No such container"}`, http.StatusNotFound)
		return
	}
	if b.logsStatus != 0 {
		fd.mu.Unlock()
		http.Error(w, `{"message":"no logs for you"}`, b.logsStatus)
		return
	}
	history := slices.Clone(b.history)
	history = history[max(0, len(history)-tail):]
	if since := q.Get("since"); since != "" { // "<unix seconds>.<nanoseconds>", with tail=all
		sec, nsec, _ := strings.Cut(since, ".")
		s, _ := strconv.ParseInt(sec, 10, 64)
		ns, _ := strconv.ParseInt(nsec, 10, 64)
		from := time.Unix(s, ns)
		history = slices.DeleteFunc(slices.Clone(b.history), func(e logEntry) bool {
			at, _ := time.Parse(time.RFC3339Nano, e.ts)
			return at.Before(from)
		})
	}
	tty := b.tty
	var sub *logSub
	if follow && b.status == "running" {
		sub = &logSub{ch: make(chan logEntry, 1024), end: make(chan struct{})}
		b.subs[sub] = struct{}{}
		fd.active[id]++
		fd.follows[id]++
	}
	fd.mu.Unlock()
	if sub != nil {
		defer func() {
			fd.mu.Lock()
			delete(b.subs, sub)
			fd.active[id]--
			fd.mu.Unlock()
		}()
	}

	w.WriteHeader(http.StatusOK)
	w.(http.Flusher).Flush()
	write := func(e logEntry) {
		payload := e.ts + " " + e.msg + "\n"
		if tty {
			w.Write([]byte(strings.ReplaceAll(payload, "\n", "\r\n")))
		} else {
			w.Write(muxFrame(e.stream, payload))
		}
		w.(http.Flusher).Flush()
	}
	for _, e := range history {
		write(e)
	}
	if sub == nil {
		return // a stopped container, or a one-shot request: Docker closes the stream
	}
	for {
		select {
		case <-r.Context().Done():
			return
		case <-sub.end: // what was logged before the stop still reaches the reader
			for {
				select {
				case e := <-sub.ch:
					write(e)
				default:
					return
				}
			}
		case e := <-sub.ch:
			write(e)
		}
	}
}

// push logs lines in a running container.
func (fd *logDocker) push(id string, entries ...logEntry) {
	fd.mu.Lock()
	defer fd.mu.Unlock()
	b := fd.boxes[id]
	b.history = append(b.history, entries...)
	for sub := range b.subs {
		for _, e := range entries {
			sub.ch <- e
		}
	}
}

// stop closes the container's follow streams, as Docker does when it exits.
func (fd *logDocker) stop(id string) {
	fd.mu.Lock()
	defer fd.mu.Unlock()
	b := fd.boxes[id]
	b.status = "exited"
	for sub := range b.subs {
		sub.once.Do(func() { close(sub.end) })
	}
}

// cut closes the container's follow streams while it keeps running, as the
// socket proxy does to a stream idle for 10 minutes.
func (fd *logDocker) cut(id string) {
	fd.mu.Lock()
	defer fd.mu.Unlock()
	for sub := range fd.boxes[id].subs {
		sub.once.Do(func() { close(sub.end) })
	}
}

func (fd *logDocker) restart(id string) {
	fd.mu.Lock()
	defer fd.mu.Unlock()
	fd.boxes[id].status = "running"
}

func (fd *logDocker) activeFor(id string) int {
	fd.mu.Lock()
	defer fd.mu.Unlock()
	return fd.active[id]
}

func (fd *logDocker) activeTotal() int {
	fd.mu.Lock()
	defer fd.mu.Unlock()
	n := 0
	for _, c := range fd.active {
		n += c
	}
	return n
}

func (fd *logDocker) followsFor(id string) int {
	fd.mu.Lock()
	defer fd.mu.Unlock()
	return fd.follows[id]
}

func (fd *logDocker) allRequests() []string {
	fd.mu.Lock()
	defer fd.mu.Unlock()
	return slices.Clone(fd.requests)
}

// logRequests are the requests made to one container's logs endpoint.
func (fd *logDocker) logRequests(id string) []string {
	var out []string
	for _, r := range fd.allRequests() {
		if strings.HasPrefix(r, "/containers/"+id+"/logs") {
			out = append(out, r)
		}
	}
	return out
}

func containerID(n int) string { return fmt.Sprintf("%064x", n) }

// The fake clock starts at 2026-11-25 10:00:00 UTC. History is stamped
// before it, live lines after.
func stampAt(d time.Duration) string {
	return newFakeClock().Now().Add(d).Format("2006-01-02T15:04:05.000000000Z07:00")
}

func old(stream byte, secondsAgo int, msg string) logEntry {
	return logEntry{stream, stampAt(-time.Duration(secondsAgo) * time.Second), msg}
}

func fresh(stream byte, secondsLater int, msg string) logEntry {
	return logEntry{stream, stampAt(time.Duration(secondsLater) * time.Second), msg}
}

// ---- the tailer, behind the ActionCable line ----

// logsOut is anything the agent sends about logs: a batch, or a reply.
type logsOut struct {
	Action    string `json:"action"`
	Container string `json:"container"`
	Backlog   bool   `json:"backlog"`
	Lines     []struct {
		T string `json:"t"`
		S string `json:"s"`
		M string `json:"m"`
	} `json:"lines"`
	Dropped int    `json:"dropped"`
	Ended   bool   `json:"ended"`
	Off     bool   `json:"off"`
	Refused string `json:"refused"`
	raw     string
}

func (o logsOut) messages() []string {
	var out []string
	for _, l := range o.Lines {
		out = append(out, l.M)
	}
	return out
}

type logRig struct {
	fd    *logDocker
	cs    *cableServer
	c     *srvConn
	clock *fakeClock
	tl    *tailer
}

// startLogRig connects a line to a fake server and runs a tailer behind it,
// on a fake clock for leases and with fast timers.
func startLogRig(t *testing.T, fd *logDocker, enabled bool, tweak ...func(*tailer)) *logRig {
	t.Helper()
	rig := &logRig{fd: fd, cs: newCableServer(t), clock: newFakeClock()}
	l, _ := startLine(t, rig.cs.srv.URL, nil)
	rig.tl = newTailer(fd.docker(t), l.send, discardLog(), rig.clock.Now, enabled, "")
	rig.tl.sweepEvery, rig.tl.batchEvery = 20*time.Millisecond, 20*time.Millisecond
	for _, f := range tweak {
		f(rig.tl)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { rig.tl.run(ctx, l.tails); close(done) }()
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("tailer.run did not return after cancel")
		}
	})
	rig.c = rig.cs.accept(t)
	rig.c.welcome(t)
	rig.c.confirm()
	return rig
}

func (r *logRig) tail(container string, seconds, backlog int) {
	r.c.sendJSON(fmt.Sprintf(`{"identifier":%s,"message":{"type":"tail","container":%q,"seconds":%d,"backlog":%d}}`,
		jsonString(testIdentifier), container, seconds, backlog))
}

// next is the next logs message the agent sends.
func (r *logRig) next(t *testing.T) logsOut {
	t.Helper()
	var cmd cableCommand
	if err := json.Unmarshal([]byte(r.c.recvText(t)), &cmd); err != nil {
		t.Fatal(err)
	}
	if cmd.Command != "message" || cmd.Identifier != testIdentifier {
		t.Fatalf("command = %q identifier = %q", cmd.Command, cmd.Identifier)
	}
	var out logsOut
	if err := json.Unmarshal([]byte(cmd.Data), &out); err != nil {
		t.Fatalf("undecodable message %s: %v", cmd.Data, err)
	}
	out.raw = cmd.Data
	return out
}

// until reads messages until one satisfies pred, and returns all it read.
func (r *logRig) until(t *testing.T, what string, pred func(logsOut) bool) []logsOut {
	t.Helper()
	var got []logsOut
	for {
		o := r.next(t)
		got = append(got, o)
		if pred(o) {
			return got
		}
		if len(got) > 100 {
			t.Fatalf("no message with %s in %d messages", what, len(got))
		}
	}
}

// lines reads batches until n lines have arrived.
func (r *logRig) lines(t *testing.T, n int) []logsOut {
	t.Helper()
	total := 0
	return r.until(t, fmt.Sprintf("%d lines", n), func(o logsOut) bool { total += len(o.Lines); return total >= n })
}

// settle returns once the tailer has handled every tail sent before it: it
// asks about a container that does not exist and waits for the refusal.
func (r *logRig) settle(t *testing.T) {
	t.Helper()
	r.tail(containerID(0xdead), 30, 0)
	r.until(t, "the refusal that settles the tailer", func(o logsOut) bool { return o.Container == containerID(0xdead) })
}

func (r *logRig) expectSilence(t *testing.T, d time.Duration) {
	t.Helper()
	deadline := time.After(d)
	for {
		select {
		case f, ok := <-r.c.in:
			if ok && f.op == opText {
				t.Fatalf("the agent sent %s", f.payload)
			}
			if !ok {
				t.Fatal("connection closed")
			}
		case <-deadline:
			return
		}
	}
}

func allMessages(batches []logsOut) []string {
	var out []string
	for _, b := range batches {
		out = append(out, b.messages()...)
	}
	return out
}

func TestTailStreamsTheBacklogThenLiveLinesInTheDocumentedShape(t *testing.T) {
	fd := newLogDocker(t)
	id := containerID(0xa1)
	fd.add(id, kamalApp(
		old(1, 30, "boot"),
		old(2, 20, "warn: cold cache"),
		old(1, 10, "listening"),
	))
	rig := startLogRig(t, fd, true)

	rig.tail(id, 30, 200)
	first := rig.next(t)
	if !first.Backlog || first.Container != id || first.Action != "logs" || first.Ended || first.Dropped != 0 {
		t.Fatalf("first batch = %s", first.raw)
	}
	if got := first.messages(); !slices.Equal(got, []string{"boot", "warn: cold cache", "listening"}) {
		t.Fatalf("backlog lines = %v", got)
	}
	if l := first.Lines; l[0].S != "out" || l[1].S != "err" || l[2].S != "out" || l[1].T != stampAt(-20*time.Second) {
		t.Fatalf("lines = %+v, want out/err/out and Docker's own timestamps", l)
	}
	assertJSONKeys(t, "batch", []byte(first.raw), "action", "container", "backlog", "lines", "dropped", "ended")
	var shape struct{ Lines []json.RawMessage }
	json.Unmarshal([]byte(first.raw), &shape)
	assertJSONKeys(t, "line", shape.Lines[0], "t", "s", "m")

	// The one request: following, both streams, timestamps, the backlog asked for.
	if reqs := fd.logRequests(id); len(reqs) != 1 || reqs[0] != "/containers/"+id+"/logs?follow=1&stdout=1&stderr=1&timestamps=1&tail=200" {
		t.Fatalf("docker log requests = %q", reqs)
	}

	// New lines follow within moments, and are not backlog.
	fd.push(id, fresh(1, 1, "GET / 200 1.2ms"), fresh(2, 2, "warn: slow query"))
	live := rig.lines(t, 2)
	if got := allMessages(live); !slices.Equal(got, []string{"GET / 200 1.2ms", "warn: slow query"}) {
		t.Fatalf("live lines = %v", got)
	}
	for _, b := range live {
		if b.Backlog || b.Ended {
			t.Fatalf("live batch = %s", b.raw)
		}
	}

	// A renewal with no backlog only extends the lease: nothing else is requested.
	rig.tail(id, 30, 0)
	fd.push(id, fresh(1, 3, "after the renewal"))
	if got := allMessages(rig.lines(t, 1)); !slices.Equal(got, []string{"after the renewal"}) {
		t.Fatalf("got %v", got)
	}
	if n := fd.followsFor(id); n != 1 {
		t.Fatalf("%d follow requests, want the one", n)
	}
}

func TestTailWithNoBacklogSendsOnlyNewLines(t *testing.T) {
	fd := newLogDocker(t)
	id := containerID(0xa1)
	fd.add(id, kamalApp(old(1, 5, "before")))
	rig := startLogRig(t, fd, true)

	rig.tail(id, 30, 0)
	waitFor(t, "the follow", func() bool { return fd.activeFor(id) == 1 })
	if reqs := fd.logRequests(id); len(reqs) != 1 || !strings.HasSuffix(reqs[0], "&tail=0") {
		t.Fatalf("docker log requests = %q, want tail=0", reqs)
	}
	fd.push(id, fresh(1, 1, "after"))
	got := rig.lines(t, 1)
	if m := allMessages(got); !slices.Equal(m, []string{"after"}) || got[0].Backlog {
		t.Fatalf("got %+v", got)
	}
}

func TestTailRefusesWhatIsNotKamalsAndSaysWhy(t *testing.T) {
	fd := newLogDocker(t)
	grafana, kamalDB, gone := containerID(0xe5), containerID(0xc3), containerID(0xff)
	fd.add(grafana, &logBox{name: "grafana", labels: map[string]string{}, status: "running", history: []logEntry{old(1, 1, "secret")}})
	fd.add(kamalDB, &logBox{name: "web-db", labels: map[string]string{"service": "web-db"}, status: "running"})
	rig := startLogRig(t, fd, true)

	rig.tail(grafana, 30, 200)
	rig.tail(gone, 30, 200)
	got := map[string]logsOut{}
	for len(got) < 2 {
		o := rig.next(t)
		got[o.Container] = o
	}
	if o := got[grafana]; o.Refused != "not a Kamal container" || len(o.Lines) != 0 {
		t.Fatalf("grafana: %s", o.raw)
	}
	assertJSONKeys(t, "refusal", []byte(got[grafana].raw), "action", "container", "refused")
	if o := got[gone]; o.Refused != "container not found" || o.Action != "logs" {
		t.Fatalf("missing container: %s", o.raw)
	}
	if reqs := fd.logRequests(grafana); len(reqs) != 0 {
		t.Fatalf("the agent read a non-Kamal container's logs: %q", reqs)
	}

	// A Kamal accessory is fine.
	rig.tail(kamalDB, 30, 0)
	waitFor(t, "the accessory's follow", func() bool { return fd.activeFor(kamalDB) == 1 })
	rig.expectSilence(t, 100*time.Millisecond)
}

func TestTailRefusesAnIdThatIsReallyANameOrAPrefix(t *testing.T) {
	// Docker resolves a name before a prefix, so a 64-hex "id" can be another
	// container's name. The inspect then reports the real id.
	fd := newLogDocker(t)
	named := containerID(0xaa)
	box := kamalApp(old(1, 1, "not yours"))
	box.inspectID = containerID(0xbb)
	fd.add(named, box)
	rig := startLogRig(t, fd, true)

	rig.tail(named, 30, 10)
	if o := rig.next(t); o.Container != named || o.Refused != refusedNotFound {
		t.Fatalf("got %s", o.raw)
	}
	if reqs := fd.logRequests(named); len(reqs) != 0 {
		t.Fatalf("the agent read logs for %q", reqs)
	}
}

func TestTailRefusesAContainerWhoseLogsCannotBeRead(t *testing.T) {
	fd := newLogDocker(t)
	vanished, noDriver := containerID(0xd1), containerID(0xd2)
	fd.add(vanished, &logBox{name: "web-db", labels: map[string]string{"service": "web-db"}, status: "running", logsStatus: http.StatusNotFound})
	// Docker answers 501 for a logging driver that cannot be read back (syslog, none).
	fd.add(noDriver, &logBox{name: "web-db", labels: map[string]string{"service": "web-db"}, status: "running", logsStatus: http.StatusNotImplemented})
	rig := startLogRig(t, fd, true)

	rig.tail(vanished, 30, 10)
	rig.tail(noDriver, 30, 10)
	got := map[string]string{}
	for len(got) < 2 {
		o := rig.next(t)
		got[o.Container] = o.Refused
	}
	if got[vanished] != refusedNotFound || got[noDriver] != refusedDocker {
		t.Fatalf("refusals = %v", got)
	}
}

func TestTailNeverFollowsTheAgentsOwnContainer(t *testing.T) {
	fd := newLogDocker(t)
	self := containerID(0xa9)
	fd.add(self, &logBox{name: "web-agent", labels: map[string]string{"service": "web-agent"}, status: "running"})
	rig := startLogRig(t, fd, true, func(tl *tailer) { tl.self = self[:12] })

	rig.tail(self, 30, 200)
	if o := rig.next(t); o.Refused != refusedSelf || o.Container != self {
		t.Fatalf("got %s", o.raw)
	}
	if reqs := fd.allRequests(); len(reqs) != 0 {
		t.Fatalf("docker was asked %q", reqs)
	}
}

func TestTailWithLogsOffAnswersOffOncePerRequestAndDoesNothingElse(t *testing.T) {
	fd := newLogDocker(t)
	id := containerID(0xa1)
	fd.add(id, kamalApp(old(1, 1, "secret")))
	rig := startLogRig(t, fd, false)

	for i := range 3 {
		rig.tail(id, 30, 200)
		o := rig.next(t)
		if !o.Off || o.Container != id || o.Action != "logs" || len(o.Lines) != 0 || o.Refused != "" {
			t.Fatalf("answer %d = %s", i, o.raw)
		}
		assertJSONKeys(t, "off reply", []byte(o.raw), "action", "container", "off")
	}
	rig.expectSilence(t, 150*time.Millisecond)
	if reqs := fd.allRequests(); len(reqs) != 0 {
		t.Fatalf("docker was asked %q with logs off", reqs)
	}
}

func TestLeaseLapseStopsFollowingAndClosesTheDockerStream(t *testing.T) {
	fd := newLogDocker(t)
	id := containerID(0xa1)
	fd.add(id, kamalApp())
	rig := startLogRig(t, fd, true)

	rig.tail(id, 30, 0)
	waitFor(t, "the follow", func() bool { return fd.activeFor(id) == 1 })

	// A renewal 20s in extends the lease to 50s, so 40s later it still holds.
	rig.clock.Advance(20 * time.Second)
	rig.tail(id, 30, 0)
	rig.settle(t)
	rig.clock.Advance(20 * time.Second)
	fd.push(id, fresh(1, 1, "still here"))
	if got := allMessages(rig.lines(t, 1)); !slices.Equal(got, []string{"still here"}) {
		t.Fatalf("got %v", got)
	}
	if fd.activeFor(id) != 1 {
		t.Fatal("the renewed lease was cut short")
	}

	rig.clock.Advance(11 * time.Second) // 51s: past the renewed lease
	waitFor(t, "the Docker stream to be closed", func() bool { return fd.activeFor(id) == 0 })
	rig.expectSilence(t, 150*time.Millisecond) // a lapse is not an end: Meridian is told nothing

	// The next lease follows it again, from a fresh request.
	rig.tail(id, 30, 0)
	waitFor(t, "the follow to start again", func() bool { return fd.activeFor(id) == 1 })
	rig.expectSilence(t, 50*time.Millisecond)
	if n := fd.followsFor(id); n != 2 {
		t.Fatalf("%d follow requests, want 2", n)
	}
}

func TestSecondTailWithBacklogWhileFollowingFetchesTheHistoryOnce(t *testing.T) {
	fd := newLogDocker(t)
	id := containerID(0xa1)
	fd.add(id, kamalApp(
		old(1, 60, "one"), old(1, 50, "two"), old(2, 40, "three"), old(1, 30, "four"), old(1, 20, "five"), old(1, 10, "six"),
	))
	rig := startLogRig(t, fd, true)

	rig.tail(id, 30, 0) // following, with no history
	waitFor(t, "the follow", func() bool { return fd.activeFor(id) == 1 })

	rig.tail(id, 30, 4) // someone opens the logs: the last 4 lines, separately
	got := rig.lines(t, 4)
	if m := allMessages(got); !slices.Equal(m, []string{"three", "four", "five", "six"}) {
		t.Fatalf("backlog = %v", m)
	}
	for _, b := range got {
		if !b.Backlog || b.Ended {
			t.Fatalf("batch = %s, want backlog", b.raw)
		}
	}
	if got[0].Lines[0].S != "err" {
		t.Fatalf("the fetch lost the stream of %+v", got[0].Lines[0])
	}
	reqs := fd.logRequests(id)
	if len(reqs) != 2 || !strings.HasSuffix(reqs[0], "follow=1&stdout=1&stderr=1&timestamps=1&tail=0") ||
		reqs[1] != "/containers/"+id+"/logs?follow=0&stdout=1&stderr=1&timestamps=1&tail=4" {
		t.Fatalf("docker log requests = %q, want the follow, then one non-following request for 4 lines", reqs)
	}

	// The follow was never disturbed, and its lines are not backlog.
	fd.push(id, fresh(1, 1, "seven"))
	live := rig.lines(t, 1)
	if live[0].Backlog || !slices.Equal(allMessages(live), []string{"seven"}) {
		t.Fatalf("live = %+v", live)
	}
	if n := fd.followsFor(id); n != 1 {
		t.Fatalf("%d follow requests, want the one", n)
	}
}

func TestTailAllowsTwentyContainersAndRefusesTheNext(t *testing.T) {
	fd := newLogDocker(t)
	for i := 1; i <= 21; i++ {
		fd.add(containerID(i), kamalApp())
	}
	rig := startLogRig(t, fd, true)

	for i := 1; i <= 20; i++ {
		rig.tail(containerID(i), 30, 0)
	}
	waitFor(t, "twenty follows", func() bool { return fd.activeTotal() == 20 })

	rig.tail(containerID(21), 30, 0)
	if o := rig.next(t); o.Container != containerID(21) || o.Refused != refusedCap {
		t.Fatalf("got %s, want the 21st refused for the cap", o.raw)
	}
	rig.tail(containerID(5), 30, 0) // an existing one is only renewed
	rig.expectSilence(t, 100*time.Millisecond)
	if fd.activeTotal() != 20 || len(fd.logRequests(containerID(21))) != 0 {
		t.Fatal("the 21st container was followed")
	}

	// One ends and its slot is free again.
	fd.stop(containerID(1))
	if o := rig.next(t); o.Container != containerID(1) || !o.Ended {
		t.Fatalf("got %s", o.raw)
	}
	// Ended is sent just before the follower is marked done, so the first
	// renewal may land a moment early; Meridian renews again within 10s.
	waitFor(t, "the 21st to be followed", func() bool {
		rig.tail(containerID(21), 30, 0)
		return fd.activeFor(containerID(21)) == 1
	})
}

func TestEndedIsSentOnceWhenDockerClosesTheStream(t *testing.T) {
	fd := newLogDocker(t)
	id := containerID(0xa1)
	fd.add(id, kamalApp(old(1, 5, "history")))
	rig := startLogRig(t, fd, true)

	rig.tail(id, 30, 10)
	waitFor(t, "the follow", func() bool { return fd.activeFor(id) == 1 })
	fd.push(id, fresh(1, 1, "last words"))
	fd.stop(id)

	got := rig.until(t, "ended", func(o logsOut) bool { return o.Ended })
	if m := allMessages(got); !slices.Equal(m, []string{"history", "last words"}) {
		t.Fatalf("lines before the end = %v", m)
	}
	last := got[len(got)-1]
	if last.Backlog || !last.Ended || last.Container != id {
		t.Fatalf("last batch = %s", last.raw)
	}
	for _, b := range got[:len(got)-1] {
		if b.Ended {
			t.Fatal("ended was sent more than once")
		}
	}

	// A stopped container has nothing new to say: renewals do not reopen it,
	// and no second ended follows.
	for range 3 {
		rig.tail(id, 30, 0)
	}
	rig.expectSilence(t, 150*time.Millisecond)
	if n := fd.followsFor(id); n != 1 {
		t.Fatalf("%d follow requests for a stopped container, want the one", n)
	}

	// Started again, the next lease follows it.
	fd.restart(id)
	waitFor(t, "the follow after the restart", func() bool {
		rig.tail(id, 30, 0)
		return fd.activeFor(id) == 1
	})
	fd.push(id, fresh(1, 2, "back"))
	if got := allMessages(rig.lines(t, 1)); !slices.Equal(got, []string{"back"}) {
		t.Fatalf("got %v", got)
	}
}

// A burst of short lines is not sent as fast as it is read: full batches
// wait their turn, and the reader holds Docker's stream meanwhile, so no line
// is lost and none of them jumps the queue.
func TestTailSpacesFullBatchesInsteadOfBurstingThem(t *testing.T) {
	fd := newLogDocker(t)
	id := containerID(0xa7)
	fd.add(id, kamalApp())
	rig := startLogRig(t, fd, true)
	rig.tail(id, 30, 0)
	waitFor(t, "the follow", func() bool { return fd.activeFor(id) == 1 })

	burst := make([]logEntry, 0, 5000)
	for i := range 5000 {
		burst = append(burst, fresh(1, 1, fmt.Sprint(i)))
	}
	start := time.Now()
	fd.push(id, burst...)
	got := rig.lines(t, 5000)
	elapsed := time.Since(start)
	if n := len(allMessages(got)); n != 5000 {
		t.Fatalf("%d lines arrived, want 5000", n)
	}
	// Ten full batches, each at least batchEvery (20ms here) after the last.
	if min := 9 * rig.tl.batchEvery; elapsed < min {
		t.Fatalf("%d batches in %v, want them spread over at least %v", len(got), elapsed, min)
	}
}

// A follow stream closed under a running container is not the container
// stopping: the agent reopens it from its last line, sends no ended, and
// loses and repeats nothing.
func TestTailReopensAStreamCutWhileTheContainerRuns(t *testing.T) {
	fd := newLogDocker(t)
	id := containerID(0xa8)
	fd.add(id, kamalApp(old(1, 5, "history")))
	rig := startLogRig(t, fd, true, func(tl *tailer) { tl.reopenAfter = 100 * time.Millisecond })
	rig.tail(id, 30, 10)
	waitFor(t, "the follow", func() bool { return fd.activeFor(id) == 1 })
	fd.push(id, fresh(1, 1, "before the cut"))
	got := rig.lines(t, 2)

	fd.cut(id)
	waitFor(t, "the cut", func() bool { return fd.activeFor(id) == 0 })
	fd.push(id, fresh(1, 2, "while cut")) // logged before the agent reopens
	waitFor(t, "the reopened follow", func() bool { return fd.activeFor(id) == 1 })
	fd.push(id, fresh(1, 3, "after the reopen"))
	got = append(got, rig.lines(t, 2)...)

	if m := allMessages(got); !slices.Equal(m, []string{"history", "before the cut", "while cut", "after the reopen"}) {
		t.Fatalf("lines = %v", m)
	}
	for _, b := range got {
		if b.Ended {
			t.Fatalf("ended was sent for a running container: %s", b.raw)
		}
	}
	reqs := fd.logRequests(id)
	if len(reqs) != 2 || !strings.Contains(reqs[1], "follow=1") || !strings.Contains(reqs[1], "&since=") {
		t.Fatalf("log requests = %v, want the follow then a follow since the last line", reqs)
	}

	// Once it really stops, ended comes.
	fd.stop(id)
	rig.until(t, "ended", func(o logsOut) bool { return o.Ended })
}

func TestTailOfAStoppedContainerSendsItsHistoryAndEnded(t *testing.T) {
	fd := newLogDocker(t)
	id := containerID(0xb2)
	box := kamalApp(old(1, 9, "one"), old(1, 8, "two"))
	box.status = "exited" // Kamal keeps old versions around
	fd.add(id, box)
	rig := startLogRig(t, fd, true)

	rig.tail(id, 30, 200)
	got := rig.until(t, "ended", func(o logsOut) bool { return o.Ended })
	if m := allMessages(got); !slices.Equal(m, []string{"one", "two"}) {
		t.Fatalf("lines = %v", m)
	}
	for _, b := range got {
		if !b.Backlog {
			t.Fatalf("batch %s: a stopped container has only history", b.raw)
		}
	}
}

func TestTailFollowsARawTTYStream(t *testing.T) {
	fd := newLogDocker(t)
	id := containerID(0xa1)
	box := kamalApp(old(1, 5, "from a terminal"))
	box.tty = true
	fd.add(id, box)
	rig := startLogRig(t, fd, true)

	rig.tail(id, 30, 10)
	rig.lines(t, 1)
	fd.push(id, fresh(2, 1, "even stderr is out"))
	got := rig.lines(t, 1)
	if got[0].Lines[0].M != "even stderr is out" || got[0].Lines[0].S != "out" || got[0].Backlog {
		t.Fatalf("got %s", got[0].raw)
	}
}

func TestTailKeepsConsumingWhileTheLineIsDownAndNeverReplays(t *testing.T) {
	fd := newLogDocker(t)
	id := containerID(0xa1)
	fd.add(id, kamalApp())

	var up atomic.Bool
	var mu sync.Mutex
	var sent []logsOut
	send := func(frame []byte) bool {
		if !up.Load() {
			return false
		}
		var o logsOut
		json.Unmarshal(frame, &o)
		mu.Lock()
		sent = append(sent, o)
		mu.Unlock()
		return true
	}
	clock := newFakeClock()
	tl := newTailer(fd.docker(t), send, discardLog(), clock.Now, true, "")
	tl.sweepEvery, tl.batchEvery = 20*time.Millisecond, 20*time.Millisecond
	tails := make(chan tailRequest, 8)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { tl.run(ctx, tails); close(done) }()
	defer func() { cancel(); <-done }()

	tails <- tailRequest{container: id, seconds: 30}
	waitFor(t, "the follow", func() bool { return fd.activeFor(id) == 1 })
	fd.push(id, fresh(1, 1, "lost 1"), fresh(1, 2, "lost 2"))
	time.Sleep(150 * time.Millisecond) // batched, offered to a line that is down, dropped

	up.Store(true)
	fd.push(id, fresh(1, 3, "kept"))
	waitFor(t, "the first line after the line came back", func() bool {
		mu.Lock()
		defer mu.Unlock()
		return len(sent) > 0
	})
	mu.Lock()
	defer mu.Unlock()
	if got := allMessages(sent); !slices.Equal(got, []string{"kept"}) {
		t.Fatalf("sent %v, want only what was logged after the line came back", got)
	}
}

func TestTailSurvivesAPanicInAFollower(t *testing.T) {
	fd := newLogDocker(t)
	a, b := containerID(0xa1), containerID(0xb2)
	fd.add(a, kamalApp(old(1, 1, "boom")))
	fd.add(b, kamalApp(old(1, 1, "fine")))

	var logs syncBuffer
	var calls atomic.Int32
	got := make(chan logsOut, 16)
	send := func(frame []byte) bool {
		if calls.Add(1) == 1 {
			panic("a bug in the send path")
		}
		var o logsOut
		json.Unmarshal(frame, &o)
		got <- o
		return true
	}
	clock := newFakeClock()
	tl := newTailer(fd.docker(t), send, slog.New(slog.NewTextHandler(&logs, nil)), clock.Now, true, "")
	tl.sweepEvery, tl.batchEvery = 20*time.Millisecond, 20*time.Millisecond
	tails := make(chan tailRequest, 8)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { tl.run(ctx, tails); close(done) }()
	defer func() { cancel(); <-done }()

	tails <- tailRequest{container: a, seconds: 30, backlog: 10} // its first batch panics
	waitFor(t, "the panic to be logged", func() bool { return strings.Contains(logs.String(), "recovered from panic") })
	waitFor(t, "the broken follower to be gone", func() bool { return fd.activeFor(a) == 0 })

	tails <- tailRequest{container: b, seconds: 30, backlog: 10}
	select {
	case o := <-got:
		if o.Container != b || !slices.Equal(o.messages(), []string{"fine"}) {
			t.Fatalf("got %+v", o)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the tailer stopped serving after a panic")
	}
	tails <- tailRequest{container: a, seconds: 30, backlog: 10} // and the failed one can start again
	select {
	case o := <-got:
		if o.Container != a || !slices.Equal(o.messages(), []string{"boom"}) {
			t.Fatalf("got %+v", o)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the failed container could not be followed again")
	}
}

// ---- the line's side ----

func TestLineDeliversTailMessagesAndNeverBlocks(t *testing.T) {
	cs := newCableServer(t)
	l, _ := startLine(t, cs.srv.URL, nil)
	c := cs.accept(t)
	c.welcome(t)
	c.confirm()

	id := containerID(0xa1)
	msg := func(identifier, body string) {
		c.sendJSON(fmt.Sprintf(`{"identifier":%s,"message":%s}`, jsonString(identifier), body))
	}
	msg(testIdentifier, `{"type":"tail","container":"not an id","seconds":30,"backlog":10}`)
	msg(testIdentifier, `{"type":"tail","container":"`+strings.ToUpper(containerID(0xabc))+`","seconds":30}`)
	msg(testIdentifier, `{"type":"tail","container":"`+id[:12]+`","seconds":30}`)
	msg(`{"channel":"OtherChannel"}`, `{"type":"tail","container":"`+id+`","seconds":99}`)
	msg(testIdentifier, `{"type":"tail","container":"`+id+`","seconds":"soon"}`)
	msg(testIdentifier, `{"type":"tail","container":"`+id+`","seconds":30,"backlog":5000}`)
	msg(testIdentifier, `{"type":"tail","container":"`+id+`","seconds":15,"backlog":-3}`)
	msg(testIdentifier, `{"type":"tail","container":"`+id+`","seconds":20}`)

	want := []tailRequest{{id, 30, 1000}, {id, 15, 0}, {id, 20, 0}}
	for i, w := range want {
		select {
		case got := <-l.tails:
			if got != w {
				t.Fatalf("tail %d = %+v, want %+v (invalid ids, other channels and nonsense never arrive; the backlog is clamped to 0..1000)", i, got, w)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("tail %d never arrived", i)
		}
	}

	// Nobody is reading: the 33rd message is dropped, not waited for.
	done := make(chan struct{})
	go func() {
		defer close(done)
		for range 100 {
			l.deliver(cableMessage{Identifier: testIdentifier, Message: json.RawMessage(`{"type":"tail","container":"` + id + `","seconds":30}`)})
		}
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("deliver blocked on a tailer that was not reading")
	}
	if n := len(l.tails); n != cap(l.tails) {
		t.Fatalf("%d tails queued, want the channel full at %d", n, cap(l.tails))
	}
}

func TestStartLiveFollowsLogsOnlyWhenTheyAreOnAndWarnsWhenLiveIsOff(t *testing.T) {
	fd := newLogDocker(t)
	id := containerID(0xa1)
	fd.add(id, kamalApp(logEntry{1, time.Now().Add(-time.Hour).Format(time.RFC3339Nano), "from before"}))
	cs := newCableServer(t)
	dockerHost := "tcp://" + fd.srv.Listener.Addr().String()

	t.Run("logs on but live off", func(t *testing.T) {
		var logs syncBuffer
		a := testAgent(t, dockerHost, config{url: cs.srv.URL, token: "tok", machineID: "0123456789abcdef", live: false, logs: true})
		a.log = slog.New(slog.NewTextHandler(&logs, nil))
		<-a.startLive(context.Background())
		if n := strings.Count(logs.String(), "MERIDIAN_LOGS is on but MERIDIAN_LIVE is off"); n != 1 {
			t.Fatalf("the inconsistent setting was logged %d times, want once:\n%s", n, logs.String())
		}
		cs.noConnectionWithin(t, 200*time.Millisecond)
	})

	t.Run("live off and logs off is just off", func(t *testing.T) {
		var logs syncBuffer
		a := testAgent(t, dockerHost, config{url: cs.srv.URL, token: "tok", machineID: "0123456789abcdef"})
		a.log = slog.New(slog.NewTextHandler(&logs, nil))
		<-a.startLive(context.Background())
		if logs.String() != "" {
			t.Fatalf("logged %q", logs.String())
		}
	})

	for _, tc := range []struct {
		name string
		logs bool
	}{{"logs off", false}, {"logs on", true}} {
		t.Run(tc.name, func(t *testing.T) {
			a := testAgent(t, dockerHost, config{url: cs.srv.URL, token: "tok", machineID: "0123456789abcdef", live: true, logs: tc.logs})
			ctx, cancel := context.WithCancel(context.Background())
			done := a.startLive(ctx)
			c := cs.accept(t)
			c.welcome(t)
			c.confirm()
			c.sendJSON(fmt.Sprintf(`{"identifier":%s,"message":{"type":"tail","container":%q,"seconds":30,"backlog":50}}`, jsonString(testIdentifier), id))
			for {
				var cmd cableCommand
				json.Unmarshal([]byte(c.recvText(t)), &cmd)
				var o logsOut
				json.Unmarshal([]byte(cmd.Data), &o)
				if o.Action != "logs" {
					continue // a stats frame
				}
				if tc.logs {
					if !o.Backlog || !slices.Equal(o.messages(), []string{"from before"}) {
						t.Fatalf("got %s", cmd.Data)
					}
				} else if !o.Off {
					t.Fatalf("got %s, want off", cmd.Data)
				}
				break
			}
			cancel()
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Fatal("the live path did not stop after cancel")
			}
			if !tc.logs && len(fd.allRequests()) != 0 {
				t.Fatalf("docker was asked %q with logs off", fd.allRequests())
			}
			waitFor(t, "the Docker stream to close", func() bool { return fd.activeFor(id) == 0 })
		})
	}
}
