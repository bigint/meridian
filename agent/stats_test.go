package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

// ---- docker stats: fixtures in, cores and bytes per second out ----

const statsTestID = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"

// streamBody serves body as the stats stream and returns the samples
// streamStats hands over, the error it ends with, and the request it made.
func streamBody(t *testing.T, body []byte) (samples []counters, request string, err error) {
	t.Helper()
	reqs := make(chan string, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reqs <- r.Method + " " + r.URL.RequestURI()
		w.Write(body)
	}))
	defer srv.Close()
	err = mustDocker(t, srv.URL).streamStats(context.Background(), statsTestID, func(c counters) { samples = append(samples, c) })
	return samples, <-reqs, err
}

func TestStatsFixturesBecomeRates(t *testing.T) {
	tests := []struct {
		name string
		file string
		want containerFrame
	}{
		// 1.5s apart: cpu 315ms busy = 0.21 cores; rx 10+12 B and tx 300+17 B
		// summed over two interfaces; memory is usage minus inactive_file.
		{"cgroup v2", "testdata/stats/cgroup-v2.jsonl", containerFrame{
			ID: statsTestID, CPUCores: 0.21,
			MemoryUsed: 71303168, MemoryLimit: 2147483648,
			NetRx: 14.7, NetTx: 211.3, DiskRead: 2000000, DiskWrite: 1000,
		}},
		// 2s apart: 1s busy = 0.5 cores; memory is usage minus total_inactive_file
		// (not inactive_file); Sync/Async/Total block io entries are not Read or Write.
		{"cgroup v1", "testdata/stats/cgroup-v1.jsonl", containerFrame{
			ID: statsTestID, CPUCores: 0.5,
			MemoryUsed: 71303168, MemoryLimit: 2147483648,
			NetRx: 200, NetTx: 450, DiskRead: 2048000, DiskWrite: 0,
		}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			body, err := os.ReadFile(tc.file)
			if err != nil {
				t.Fatal(err)
			}
			samples, request, err := streamBody(t, body)
			if err != nil || len(samples) != 2 {
				t.Fatalf("got %d samples, err %v; want 2", len(samples), err)
			}
			if want := "GET /containers/" + statsTestID + "/stats?stream=true"; request != want {
				t.Fatalf("request = %q, want %q", request, want)
			}
			got, ok := frameBetween(statsTestID, samples[0], samples[1])
			if !ok || got != tc.want {
				t.Fatalf("frame = %+v (ok=%v)\nwant    %+v", got, ok, tc.want)
			}
		})
	}
}

func TestStatsMemoryNeverUnderflows(t *testing.T) {
	// inactive_file larger than usage is ignored, as the docker CLI does.
	body := `{"read":"2026-11-25T10:00:01Z","memory_stats":{"usage":1000,"limit":5000,"stats":{"inactive_file":4000}}}`
	samples, _, err := streamBody(t, []byte(body))
	if err != nil || len(samples) != 1 || samples[0].memUsed != 1000 || samples[0].memLimit != 5000 {
		t.Fatalf("samples = %+v, err %v; want memory_used 1000", samples, err)
	}
}

func TestStatsToleratesMissingSections(t *testing.T) {
	// Host-network containers have no "networks"; some daemons send null blkio.
	body := `{"read":"2026-11-25T10:00:01Z","cpu_stats":{"cpu_usage":{"total_usage":7}},"networks":null,"blkio_stats":{"io_service_bytes_recursive":null}}`
	samples, _, err := streamBody(t, []byte(body))
	if err != nil || len(samples) != 1 {
		t.Fatalf("samples = %+v, err %v", samples, err)
	}
	if c := samples[0]; c.cpuNS != 7 || c.netRx != 0 || c.netTx != 0 || c.diskRead != 0 || c.diskWrite != 0 {
		t.Fatalf("counters = %+v", c)
	}
}

func TestStatsSkipsTheEmptySampleOfAStoppedContainer(t *testing.T) {
	body := `{"read":"0001-01-01T00:00:00Z"}` + "\n" + `{"read":"2026-11-25T10:00:01Z"}`
	samples, _, err := streamBody(t, []byte(body))
	if err != nil || len(samples) != 1 {
		t.Fatalf("samples = %+v, err %v; want only the real one", samples, err)
	}
}

func TestFrameBetweenNeverReportsNegativeOrMissingIntervals(t *testing.T) {
	at := time.Date(2026, 11, 25, 10, 0, 0, 0, time.UTC)
	prev := counters{at: at, cpuNS: 900, netRx: 900, diskWrite: 900}
	// A restarted container's counters start over.
	got, ok := frameBetween("id", prev, counters{at: at.Add(time.Second), cpuNS: 100, netRx: 100, diskWrite: 100})
	if !ok || got.CPUCores != 0 || got.NetRx != 0 || got.DiskWrite != 0 {
		t.Fatalf("after a counter reset: %+v ok=%v, want zero rates", got, ok)
	}
	for _, cur := range []counters{{at: at}, {at: at.Add(-time.Second)}} {
		if _, ok := frameBetween("id", prev, cur); ok {
			t.Fatalf("a frame was made from samples %s apart", cur.at.Sub(prev.at))
		}
	}
}

func TestStreamStatsEndsAsTheCallerOrDockerDoes(t *testing.T) {
	t.Run("container not found", func(t *testing.T) {
		srv := httptest.NewServer(http.NotFoundHandler())
		defer srv.Close()
		err := mustDocker(t, srv.URL).streamStats(context.Background(), statsTestID, func(counters) {})
		if !errors.Is(err, errNotFound) {
			t.Fatalf("err = %v, want errNotFound", err)
		}
	})
	t.Run("an error status", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Error(w, "no", http.StatusForbidden) }))
		defer srv.Close()
		if err := mustDocker(t, srv.URL).streamStats(context.Background(), statsTestID, func(counters) {}); err == nil {
			t.Fatal("want an error for 403")
		}
	})
	t.Run("a cancelled context cuts an open stream", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			io.WriteString(w, `{"read":"2026-11-25T10:00:01Z"}`+"\n")
			w.(http.Flusher).Flush()
			<-r.Context().Done()
		}))
		defer srv.Close()
		ctx, cancel := context.WithCancel(context.Background())
		got := make(chan struct{}, 1)
		done := make(chan error, 1)
		go func() {
			done <- mustDocker(t, srv.URL).streamStats(ctx, statsTestID, func(counters) { got <- struct{}{} })
		}()
		<-got
		cancel()
		select {
		case err := <-done:
			if !errors.Is(err, context.Canceled) {
				t.Fatalf("err = %v, want context.Canceled", err)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("streamStats did not return after cancel")
		}
	})
	t.Run("a runaway sample is cut off", func(t *testing.T) {
		huge := `{"read":"` + strings.Repeat("x", 3*maxStatsSample)
		_, _, err := streamBody(t, []byte(huge))
		if !errors.Is(err, errSampleTooLarge) {
			t.Fatalf("err = %v, want errSampleTooLarge", err)
		}
	})
}

func TestDockerStreamClientHasNoOverallTimeout(t *testing.T) {
	// An overall Timeout would kill every stats stream after 10 seconds.
	for _, host := range []string{"unix:///var/run/docker.sock", "tcp://docker-proxy:2375"} {
		dc := mustDocker(t, host)
		if dc.stream.Timeout != 0 {
			t.Errorf("%s: stream client Timeout = %s, want none", host, dc.stream.Timeout)
		}
		if dc.http.Timeout != dockerTimeout {
			t.Errorf("%s: one-shot client Timeout = %s, want %s", host, dc.http.Timeout, dockerTimeout)
		}
	}
}

// ---- host metrics from /proc ----

func fakeStatfs(path string) (uint64, uint64, error) {
	if path != "/host/etc/hostname" {
		return 0, 0, fmt.Errorf("unexpected path %q", path)
	}
	return 42949672960, 9663676416, nil
}

func TestHostMetricsFromProc(t *testing.T) {
	h := &hostMetrics{proc: "testdata/proc-a", statfs: fakeStatfs}
	h.reset() // the baseline
	h.proc = "testdata/proc-b"
	got, ok := h.sample()
	if !ok {
		t.Fatal("no host sample")
	}
	// proc-b is 200 ticks later on 2 cores, 45 of them busy (not idle, not
	// iowait): 45/200 of 2 cores. Memory is MemTotal - MemAvailable.
	total, used := uint64(42949672960), uint64(9663676416)
	want := hostFrame{
		CPUCores: 0.45, Cores: 2,
		MemoryUsed: 72351744, MemoryTotal: 2147483648,
		Load1:    1.25,
		DiskUsed: &used, DiskTotal: &total,
	}
	gotJSON, _ := json.Marshal(got)
	wantJSON, _ := json.Marshal(want)
	if !bytes.Equal(gotJSON, wantJSON) {
		t.Fatalf("host = %s\nwant   %s", gotJSON, wantJSON)
	}
	assertJSONKeys(t, "host", gotJSON, "cpu_cores", "cores", "memory_used", "memory_total", "load1", "disk_used", "disk_total")

	// Every sample is measured from the one before it.
	again, ok := h.sample()
	if !ok || again.CPUCores != 0 {
		t.Fatalf("an unchanged /proc/stat should read as idle, got %+v ok=%v", again, ok)
	}
}

func assertJSONKeys(t *testing.T, what string, raw []byte, want ...string) {
	t.Helper()
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("%s: %v in %s", what, err, raw)
	}
	assertKeys(t, what, m, want...)
}

func TestHostMetricsAreOmittedWithoutProc(t *testing.T) {
	h := &hostMetrics{proc: "testdata/not-mounted", statfs: fakeStatfs}
	h.reset()
	if _, ok := h.sample(); ok {
		t.Fatal("host reported without /host/proc")
	}
}

func TestHostMetricsNeedABaselineForCPU(t *testing.T) {
	h := &hostMetrics{proc: "testdata/proc-a", statfs: fakeStatfs}
	if _, ok := h.sample(); ok { // no reset: nothing to measure the rate against
		t.Fatal("a CPU rate was reported from a single reading")
	}
	if _, ok := h.sample(); !ok {
		t.Fatal("the next sample should have a baseline")
	}
}

func TestHostMetricsOmitDiskWhenStatfsFails(t *testing.T) {
	h := &hostMetrics{proc: "testdata/proc-a", statfs: func(string) (uint64, uint64, error) { return 0, 0, os.ErrNotExist }}
	h.reset()
	got, ok := h.sample()
	if !ok {
		t.Fatal("the rest of the host should still be reported")
	}
	raw, _ := json.Marshal(got)
	assertJSONKeys(t, "host", raw, "cpu_cores", "cores", "memory_used", "memory_total", "load1")
}

func TestStatfsUsageReportsTheFilesystemOfAFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hostname")
	if err := os.WriteFile(path, []byte("app-1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	total, used, err := statfsUsage(path)
	if err != nil || total == 0 || used > total {
		t.Fatalf("total=%d used=%d err=%v", total, used, err)
	}
	if _, _, err := statfsUsage(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("want an error for a missing file")
	}
}

func TestProcParsersRejectGarbage(t *testing.T) {
	if _, _, err := parseProcStat("intr 1 2 3\n"); err == nil {
		t.Error("stat without a cpu line should fail")
	}
	if _, _, err := parseProcStat("cpu 1 2 x 4\ncpu0 1 2 3 4\n"); err == nil {
		t.Error("stat with a non-numeric field should fail")
	}
	if _, _, err := parseMeminfo("MemTotal: 100 kB\n"); err == nil {
		t.Error("meminfo without MemAvailable should fail")
	}
	if _, _, err := parseMeminfo("MemTotal: 100 kB\nMemAvailable: 200 kB\n"); err == nil {
		t.Error("meminfo with more available than total should fail")
	}
	dir := t.TempDir()
	for _, bad := range []string{"NaN 0 0 1/1 1\n", "-1 0 0 1/1 1\n", "Inf 0 0 1/1 1\n", ""} {
		os.WriteFile(filepath.Join(dir, "loadavg"), []byte(bad), 0o644)
		if _, err := (&hostMetrics{proc: dir}).readLoad1(); err == nil {
			t.Errorf("loadavg %q should fail: JSON cannot carry it", bad)
		}
	}
}

// ---- the lease ----

func TestLeaseMath(t *testing.T) {
	clock := newFakeClock()
	l := &lease{now: clock.Now}
	if l.live() {
		t.Fatal("a new lease is live")
	}

	l.watch(30)
	clock.Advance(29 * time.Second)
	if !l.live() {
		t.Fatal("a 30s lease should hold at 29s")
	}
	clock.Advance(2 * time.Second)
	if l.live() {
		t.Fatal("a 30s lease should have lapsed at 31s")
	}

	// A renewal extends it from now, a shorter one never shortens it.
	l = &lease{now: clock.Now}
	l.watch(30) // until +30
	clock.Advance(10 * time.Second)
	l.watch(5) // would be +15: ignored
	clock.Advance(15 * time.Second)
	if !l.live() {
		t.Fatal("a shorter watch must not shorten the lease (live_until = max)")
	}
	l.watch(30) // until +25+30 = +55 from the start of this block
	clock.Advance(29 * time.Second)
	if !l.live() {
		t.Fatal("a renewal should extend the lease")
	}
	clock.Advance(2 * time.Second)
	if l.live() {
		t.Fatal("the renewed lease should lapse 30s after the renewal")
	}
}

func TestLeaseCapsAtTwoMinutesAndIgnoresNonsense(t *testing.T) {
	clock := newFakeClock()
	l := &lease{now: clock.Now}
	l.watch(1 << 40) // no overflow, just the cap
	clock.Advance(119 * time.Second)
	if !l.live() {
		t.Fatal("capped lease should hold at 119s")
	}
	clock.Advance(2 * time.Second)
	if l.live() {
		t.Fatal("capped lease should have lapsed at 121s")
	}

	l = &lease{now: clock.Now}
	l.watch(0)
	l.watch(-30)
	if l.live() {
		t.Fatal("zero and negative watches must not make the lease live")
	}
}

func TestLeaseIgnoresNegativesTooLargeToMultiply(t *testing.T) {
	// -9223372037 s is below math.MinInt64 ns: unclamped, it wraps to +292 years.
	clock := newFakeClock()
	l := &lease{now: clock.Now}
	l.watch(-9223372037)
	if l.live() {
		t.Fatalf("a negative watch made the lease live until %v", l.until)
	}
}

// ---- config ----

func TestLoadConfigLiveSwitch(t *testing.T) {
	load := func(live string) (config, error) {
		env := map[string]string{"MERIDIAN_URL": "https://m.example.com", "MERIDIAN_TOKEN": "t", "MERIDIAN_MACHINE_ID": "m", "MERIDIAN_LIVE": live}
		return loadConfig(func(k string) string { return env[k] }, func(string) ([]byte, error) { return nil, os.ErrNotExist }, true)
	}
	for live, want := range map[string]bool{"": true, "1": true, "true": true, "TRUE": true, "0": false, "false": false, "False": false} {
		cfg, err := load(live)
		if err != nil || cfg.live != want {
			t.Errorf("MERIDIAN_LIVE=%q: live=%v err=%v, want live=%v", live, cfg.live, err, want)
		}
	}
	if _, err := load("maybe"); err == nil {
		t.Error("MERIDIAN_LIVE=maybe: want an error")
	}
}

// ---- a fake Docker that streams stats ----

// liveDocker serves the container list and a stats stream per container,
// and keeps count of who is streaming. Stream sample k is stamped k seconds
// after the first, whatever the wall clock says, and every counter rises by a
// constant per sample, so the rates a frame reports are exact.
type liveDocker struct {
	srv         *httptest.Server
	sampleEvery time.Duration

	mu       sync.Mutex
	list     []byte
	requests []string
	active   map[string]int // open stats streams by container id
	started  map[string]int // stats requests by container id
	endAfter map[string]int // streams that end by themselves after n samples
}

func newLiveDocker(t *testing.T) *liveDocker {
	fd := &liveDocker{sampleEvery: 10 * time.Millisecond, active: map[string]int{}, started: map[string]int{}, endAfter: map[string]int{}}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /containers/json", func(w http.ResponseWriter, r *http.Request) {
		fd.mu.Lock()
		body := fd.list
		fd.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.Write(body)
	})
	mux.HandleFunc("GET /containers/{id}/stats", fd.stats)
	fd.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fd.mu.Lock()
		fd.requests = append(fd.requests, r.Method+" "+r.URL.RequestURI())
		fd.mu.Unlock()
		mux.ServeHTTP(w, r)
	}))
	t.Cleanup(fd.srv.Close)
	return fd
}

func (fd *liveDocker) docker(t *testing.T) *dockerClient { return mustDocker(t, fd.srv.URL) }

// usageFor: cpu differs by container (a = 0.01 cores, b = 0.02, ...).
func usageFor(id string) (cpuNS uint64) { return uint64(id[0]-'a'+1) * 10_000_000 }

const (
	usageMem    = 50_000_000
	usageInact  = 2_000_000
	usageLimit  = 1 << 30
	usageRxPerS = 1500
	usageTxPerS = 3000
	usageRdPerS = 4096
	usageWrPerS = 8192
)

func (fd *liveDocker) stats(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	fd.mu.Lock()
	fd.active[id]++
	fd.started[id]++
	limit := fd.endAfter[id]
	fd.mu.Unlock()
	defer func() {
		fd.mu.Lock()
		fd.active[id]--
		fd.mu.Unlock()
	}()

	base := time.Date(2026, 11, 25, 10, 0, 0, 0, time.UTC)
	for k := 0; ; k++ {
		n := uint64(k)
		fmt.Fprintf(w, `{"read":%q,"cpu_stats":{"cpu_usage":{"total_usage":%d}},`+
			`"memory_stats":{"usage":%d,"limit":%d,"stats":{"inactive_file":%d}},`+
			`"networks":{"eth0":{"rx_bytes":%d,"tx_bytes":%d}},`+
			`"blkio_stats":{"io_service_bytes_recursive":[{"op":"read","value":%d},{"op":"write","value":%d}]}}`+"\n",
			base.Add(time.Duration(k)*time.Second).Format(time.RFC3339Nano),
			n*usageFor(id), usageMem, usageLimit, usageInact,
			n*usageRxPerS, n*usageTxPerS, n*usageRdPerS, n*usageWrPerS)
		w.(http.Flusher).Flush()
		if limit > 0 && k+1 >= limit {
			return
		}
		select {
		case <-r.Context().Done():
			return
		case <-time.After(fd.sampleEvery):
		}
	}
}

func (fd *liveDocker) setList(body []byte) {
	fd.mu.Lock()
	defer fd.mu.Unlock()
	fd.list = body
}

func (fd *liveDocker) activeStreams() int {
	fd.mu.Lock()
	defer fd.mu.Unlock()
	n := 0
	for _, c := range fd.active {
		n += c
	}
	return n
}

func (fd *liveDocker) activeFor(id string) int {
	fd.mu.Lock()
	defer fd.mu.Unlock()
	return fd.active[id]
}

func (fd *liveDocker) startedFor(id string) int {
	fd.mu.Lock()
	defer fd.mu.Unlock()
	return fd.started[id]
}

func (fd *liveDocker) streamedIDs() []string {
	fd.mu.Lock()
	defer fd.mu.Unlock()
	var ids []string
	for id := range fd.started {
		ids = append(ids, id)
	}
	slices.Sort(ids)
	return ids
}

func (fd *liveDocker) allRequests() []string {
	fd.mu.Lock()
	defer fd.mu.Unlock()
	return slices.Clone(fd.requests)
}

// containerList renders a /containers/json body: "<hex byte>:<name>:<state>"
// entries; names starting with "kamal-" or "web-" get Kamal labels.
func containerList(entries ...string) []byte {
	type entry struct {
		ID     string            `json:"Id"`
		Names  []string          `json:"Names"`
		Labels map[string]string `json:"Labels"`
		State  string            `json:"State"`
	}
	var out []entry
	for _, e := range entries {
		parts := strings.Split(e, ":")
		labels := map[string]string{}
		switch {
		case strings.HasPrefix(parts[1], "web-web"):
			labels = map[string]string{"service": "web", "role": "web"}
		case strings.HasPrefix(parts[1], "web-"):
			labels = map[string]string{"service": parts[1]}
		}
		out = append(out, entry{ID: strings.Repeat(parts[0], 32), Names: []string{"/" + parts[1]}, Labels: labels, State: parts[2]})
	}
	b, _ := json.Marshal(out)
	return b
}

var (
	idA1 = strings.Repeat("a1", 32)
	idC3 = strings.Repeat("c3", 32)
	idD4 = strings.Repeat("d4", 32)
)

// ---- the sampler ----

type liveSampler struct {
	*sampler
	frames chan liveFrame
	clock  *fakeClock
}

// startSampler runs a sampler on a fake clock with fast intervals. send
// defaults to collecting frames on ls.frames; opts adjust it before it runs.
func startSampler(t *testing.T, docker *dockerClient, host *hostMetrics, send func([]byte) bool, watches <-chan int, opts ...func(*sampler)) *liveSampler {
	t.Helper()
	ls := &liveSampler{frames: make(chan liveFrame, 1000), clock: newFakeClock()}
	if send == nil {
		send = func(body []byte) bool {
			var f liveFrame
			if err := json.Unmarshal(body, &f); err != nil {
				t.Errorf("undecodable frame: %v", err)
			}
			select {
			case ls.frames <- f:
			default:
			}
			return true
		}
	}
	ls.sampler = newSampler(docker, host, send, discardLog(), ls.clock.Now)
	ls.frameEvery, ls.reconcileEvery = 20*time.Millisecond, 40*time.Millisecond
	for _, opt := range opts {
		opt(ls.sampler)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { ls.run(ctx, watches); close(done) }()
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("sampler.run did not return after cancel")
		}
	})
	return ls
}

func (ls *liveSampler) frameWith(t *testing.T, what string, pred func(liveFrame) bool) liveFrame {
	t.Helper()
	timeout := time.After(5 * time.Second)
	for {
		select {
		case f := <-ls.frames:
			if pred(f) {
				return f
			}
		case <-timeout:
			t.Fatalf("no frame with %s", what)
		}
	}
}

func (ls *liveSampler) expectSilence(t *testing.T, d time.Duration) {
	t.Helper()
	// Drain whatever was already in flight, then nothing more may come.
	for quiet := false; !quiet; {
		select {
		case <-ls.frames:
		case <-time.After(100 * time.Millisecond):
			quiet = true
		}
	}
	select {
	case <-ls.frames:
		t.Fatal("a frame was sent while nobody was watching")
	case <-time.After(d):
	}
}

func frameIDs(f liveFrame) []string {
	var ids []string
	for _, c := range f.Containers {
		ids = append(ids, c.ID)
	}
	return ids
}

func testHost() *hostMetrics {
	return &hostMetrics{proc: "testdata/proc-b", statfs: fakeStatfs}
}

func TestSamplerStreamsOnlyWhileWatchedAndOnlyRunningKamalContainers(t *testing.T) {
	fd := newLiveDocker(t)
	fd.setList(containerList(
		"a1:web-web-production-3f2a:running", // app
		"b2:web-web-9b8c:exited",             // stopped: Kamal keeps old versions
		"c3:web-db:running",                  // accessory
		"e5:grafana:running",                 // not Kamal's
	))
	watches := make(chan int, 8)
	ls := startSampler(t, fd.docker(t), testHost(), nil, watches)

	ls.expectSilence(t, 200*time.Millisecond)
	if n := len(fd.allRequests()); n != 0 {
		t.Fatalf("docker was called %d times before anybody watched: %v", n, fd.allRequests())
	}

	watches <- 30
	f := ls.frameWith(t, "both running Kamal containers", func(f liveFrame) bool { return len(f.Containers) == 2 })
	if ids := frameIDs(f); !slices.Equal(ids, []string{idA1, idC3}) {
		t.Fatalf("frame containers = %v, want the running Kamal ones: %v", ids, []string{idA1, idC3})
	}
	if got := fd.streamedIDs(); !slices.Equal(got, []string{idA1, idC3}) {
		t.Fatalf("stats streams opened for %v, want only the running Kamal containers", got)
	}
	for _, r := range fd.allRequests() {
		if !strings.HasPrefix(r, "GET ") {
			t.Fatalf("docker was sent a non-GET request: %s", r)
		}
	}

	// Values are exactly the rates of the stream: no wall clock involved.
	want := containerFrame{
		ID: idA1, CPUCores: 0.01,
		MemoryUsed: usageMem - usageInact, MemoryLimit: usageLimit,
		NetRx: usageRxPerS, NetTx: usageTxPerS, DiskRead: usageRdPerS, DiskWrite: usageWrPerS,
	}
	if f.Containers[0] != want {
		t.Fatalf("container frame = %+v\nwant           %+v", f.Containers[0], want)
	}
	if f.Containers[1].CPUCores != 0.03 {
		t.Fatalf("second container cpu_cores = %v, want 0.03", f.Containers[1].CPUCores)
	}
	if f.Host == nil || f.Host.Cores != 2 || f.Host.Load1 != 1.25 || f.Host.MemoryTotal != 2147483648 {
		t.Fatalf("host = %+v", f.Host)
	}

	// The lease lapses: every stream is cancelled and the frames stop.
	ls.clock.Advance(31 * time.Second)
	waitFor(t, "all stats streams to be cancelled", func() bool { return fd.activeStreams() == 0 })
	ls.expectSilence(t, 200*time.Millisecond)

	// Meridian renews: streaming starts over.
	watches <- 30
	ls.frameWith(t, "both containers again", func(f liveFrame) bool { return len(f.Containers) == 2 })
	if fd.startedFor(idA1) != 2 {
		t.Fatalf("a1 streamed %d times, want a fresh stream per live period (2)", fd.startedFor(idA1))
	}
}

func TestSamplerFollowsContainersComingAndGoing(t *testing.T) {
	fd := newLiveDocker(t)
	fd.setList(containerList("a1:web-web-production-3f2a:running", "c3:web-db:running"))
	watches := make(chan int, 8)
	ls := startSampler(t, fd.docker(t), testHost(), nil, watches)
	watches <- 30
	ls.frameWith(t, "a1 and c3", func(f liveFrame) bool { return slices.Equal(frameIDs(f), []string{idA1, idC3}) })

	// c3 stops, kamal-proxy starts.
	fd.setList(containerList("a1:web-web-production-3f2a:running", "c3:web-db:exited", "d4:kamal-proxy:running"))
	ls.frameWith(t, "a1 and d4", func(f liveFrame) bool { return slices.Equal(frameIDs(f), []string{idA1, idD4}) })
	waitFor(t, "c3's stream to be cancelled", func() bool { return fd.activeFor(idC3) == 0 })
	if fd.startedFor(idA1) != 1 {
		t.Fatalf("a1's stream was restarted (%d starts) though nothing changed for it", fd.startedFor(idA1))
	}
}

func TestSamplerRestartsAStreamThatEnded(t *testing.T) {
	fd := newLiveDocker(t)
	fd.endAfter[idA1] = 3 // the stream drops after three samples
	fd.setList(containerList("a1:web-web-production-3f2a:running"))
	watches := make(chan int, 8)
	ls := startSampler(t, fd.docker(t), testHost(), nil, watches)
	watches <- 30
	waitFor(t, "the dropped stream to be reopened", func() bool { return fd.startedFor(idA1) >= 2 })
	ls.frameWith(t, "a1 after the restart", func(f liveFrame) bool { return slices.Equal(frameIDs(f), []string{idA1}) })
}

func TestSamplerSkipsAStalledContainer(t *testing.T) {
	fd := newLiveDocker(t)
	fd.endAfter[idA1] = 3
	fd.setList(containerList("a1:web-web-production-3f2a:running", "c3:web-db:running"))
	// Reconciling does not run again, so a1's stream stays dead once it ends.
	watches := make(chan int, 8)
	ls := startSampler(t, fd.docker(t), testHost(), nil, watches, func(s *sampler) { s.reconcileEvery = time.Hour })
	watches <- 30
	ls.frameWith(t, "both", func(f liveFrame) bool { return len(f.Containers) == 2 })
	// Wait for the agent's end of a1's stream, not Docker's: a sample still
	// being decoded when the clock jumps would arrive fresh and stay fresh.
	// (The frame just received orders this read of win after its write.)
	w := ls.win
	waitFor(t, "a1's stream to end", func() bool {
		w.mu.Lock()
		defer w.mu.Unlock()
		st := w.streams[idA1]
		return st != nil && st.done.Load()
	})
	// The clock jumps 10s: both are stale until a new sample lands, and only
	// c3 is still streaming.
	ls.clock.Advance(10 * time.Second)
	ls.frameWith(t, "c3 alone", func(f liveFrame) bool { return slices.Equal(frameIDs(f), []string{idC3}) })
}

func TestSamplerSurvivesPanics(t *testing.T) {
	// A nil docker client panics inside reconcile. The frame loop must carry on.
	var logs syncBuffer
	watches := make(chan int, 1)
	ls := startSampler(t, nil, testHost(), nil, watches, func(s *sampler) {
		s.log = slog.New(slog.NewTextHandler(&logs, nil))
		s.reconcileEvery = 20 * time.Millisecond
	})

	watches <- 30
	ls.frameWith(t, "a host-only frame", func(f liveFrame) bool { return f.Host != nil && len(f.Containers) == 0 })
	ls.frameWith(t, "another frame after the panic", func(liveFrame) bool { return true })
	waitFor(t, "the panic to be logged", func() bool { return strings.Contains(logs.String(), "recovered from panic") })
}

type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

func TestLiveContainerIDsCapsAtFiveHundred(t *testing.T) {
	var listed []listedContainer
	for i := range 600 {
		listed = append(listed, listedContainer{
			ID: fmt.Sprintf("%064x", i), Names: []string{"/web-db"}, Labels: map[string]string{"service": "web-db"}, State: "running",
		})
	}
	listed = append(listed,
		listedContainer{ID: "ffff", Names: []string{"/old"}, Labels: map[string]string{"service": "web-db"}, State: "exited"},
		listedContainer{ID: "eeee", Names: []string{"/grafana"}, Labels: map[string]string{}, State: "running"},
	)
	ids := liveContainerIDs(listed)
	if len(ids) != maxLiveContainers {
		t.Fatalf("got %d ids, want %d", len(ids), maxLiveContainers)
	}
	for _, id := range []string{fmt.Sprintf("%064x", 0), fmt.Sprintf("%064x", 499)} {
		if _, ok := ids[id]; !ok {
			t.Errorf("id %s missing: the lowest ids should be kept", id)
		}
	}
	for _, id := range []string{fmt.Sprintf("%064x", 500), "ffff", "eeee"} {
		if _, ok := ids[id]; ok {
			t.Errorf("id %s should not be streamed", id)
		}
	}
}

// ---- the whole path: ActionCable in, stats frames out ----

func TestWatchMessageTurnsOnStatsFrames(t *testing.T) {
	fd := newLiveDocker(t)
	body, err := os.ReadFile("testdata/containers.json")
	if err != nil {
		t.Fatal(err)
	}
	fd.setList(body)
	cs := newCableServer(t)
	l, _ := startLine(t, cs.srv.URL, nil)
	ls := startSampler(t, fd.docker(t), testHost(), l.send, l.watches)

	c := cs.accept(t)
	c.welcome(t)
	c.confirm()

	// Nobody is watching: nothing streams and nothing is sent.
	select {
	case f := <-c.in:
		t.Fatalf("frame %q sent before any watch", f.payload)
	case <-time.After(300 * time.Millisecond):
	}
	if n := len(fd.allRequests()); n != 0 {
		t.Fatalf("docker was called before any watch: %v", fd.allRequests())
	}

	c.watch(30)
	var raw string
	var cmd cableCommand
	for {
		raw = c.recvText(t)
		cmd = cableCommand{}
		if err := json.Unmarshal([]byte(raw), &cmd); err != nil {
			t.Fatalf("undecodable command %s: %v", raw, err)
		}
		if strings.Count(cmd.Data, `"cpu_cores"`) == 4 { // host + the 3 running Kamal containers
			break
		}
	}
	if cmd.Command != "message" || cmd.Identifier != testIdentifier {
		t.Fatalf("command = %q identifier = %q", cmd.Command, cmd.Identifier)
	}

	// The documented shape of the frame.
	assertJSONKeys(t, "frame", []byte(cmd.Data), "action", "host", "containers")
	var doc struct {
		Action     string            `json:"action"`
		Host       json.RawMessage   `json:"host"`
		Containers []json.RawMessage `json:"containers"`
	}
	if err := json.Unmarshal([]byte(cmd.Data), &doc); err != nil {
		t.Fatal(err)
	}
	if doc.Action != "stats" || len(doc.Containers) != 3 {
		t.Fatalf("frame = %s", cmd.Data)
	}
	assertJSONKeys(t, "host", doc.Host, "cpu_cores", "cores", "memory_used", "memory_total", "load1", "disk_used", "disk_total")
	for _, c := range doc.Containers {
		assertJSONKeys(t, "container", c, "id", "cpu_cores", "memory_used", "memory_limit", "net_rx", "net_tx", "disk_read", "disk_write")
	}
	var frame liveFrame
	json.Unmarshal([]byte(cmd.Data), &frame)
	if ids := frameIDs(frame); !slices.Equal(ids, []string{idA1, idC3, idD4}) {
		t.Fatalf("containers = %v, want the proxy, the accessory and the running app, by id", ids)
	}
	if frame.Host.MemoryUsed != 72351744 || *frame.Host.DiskTotal != 42949672960 {
		t.Fatalf("host = %+v", frame.Host)
	}

	// The lease lapses: the streams are cut and the frames stop.
	ls.clock.Advance(31 * time.Second)
	waitFor(t, "all stats streams to be cancelled", func() bool { return fd.activeStreams() == 0 })
	for quiet := false; !quiet; { // frames already on the wire
		select {
		case <-c.in:
		case <-time.After(100 * time.Millisecond):
			quiet = true
		}
	}
	select {
	case f := <-c.in:
		t.Fatalf("frame %q sent after the lease lapsed", f.payload)
	case <-time.After(200 * time.Millisecond):
	}

	// And the next watch brings them back.
	c.watch(30)
	for {
		var next cableCommand
		json.Unmarshal([]byte(c.recvText(t)), &next)
		if strings.Count(next.Data, `"cpu_cores"`) == 4 {
			break
		}
	}
}

func TestStartLiveWiresTheLineWhenEnabledAndNotWhenOff(t *testing.T) {
	fd := newLiveDocker(t)
	fd.setList(containerList("a1:web-web-production-3f2a:running"))
	cs := newCableServer(t)

	t.Run("off", func(t *testing.T) {
		a := testAgent(t, "tcp://"+fd.srv.Listener.Addr().String(), config{url: cs.srv.URL, token: "tok", machineID: "0123456789abcdef", live: false})
		select {
		case <-a.startLive(context.Background()):
		case <-time.After(time.Second):
			t.Fatal("startLive should return a closed channel with MERIDIAN_LIVE off")
		}
		cs.noConnectionWithin(t, 300*time.Millisecond)
	})

	t.Run("on", func(t *testing.T) {
		a := testAgent(t, "tcp://"+fd.srv.Listener.Addr().String(), config{url: cs.srv.URL, token: "tok", machineID: "0123456789abcdef", live: true})
		ctx, cancel := context.WithCancel(context.Background())
		done := a.startLive(ctx)
		c := cs.accept(t)
		if got := c.header.Get("Authorization"); got != "Bearer tok" {
			t.Fatalf("Authorization = %q", got)
		}
		c.welcome(t)
		c.confirm()
		c.watch(30)
		for { // a real frame comes through the production wiring
			var cmd cableCommand
			json.Unmarshal([]byte(c.recvText(t)), &cmd)
			if strings.Contains(cmd.Data, idA1) {
				break
			}
		}
		cancel()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Fatal("the live path did not stop after cancel")
		}
	})
}

func TestDiskUsageRefusesMemoryFilesystems(t *testing.T) {
	for _, fsType := range []uint64{tmpfsMagic, ramfsMagic} {
		if _, _, err := diskUsage(fsType, 4096, 1000, 900); err == nil {
			t.Errorf("fs type %#x: want an error, a RAM filesystem is not the host's disk", fsType)
		}
	}
	const ext4 = 0xef53
	total, used, err := diskUsage(ext4, 4096, 1000, 900)
	if err != nil || total != 4096*1000 || used != 4096*100 {
		t.Fatalf("ext4: got total=%d used=%d err=%v", total, used, err)
	}
}
