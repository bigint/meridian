package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	shaProd  = "3f2a9c1e5b7d4a6f8e0c2b4d6f8a0c1e3b5d7f9a"
	shaNoDst = "9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c"
)

// fakeDocker serves testdata/ fixtures as the Docker Engine API and records
// every request it receives.
type fakeDocker struct {
	mu       sync.Mutex
	requests []string
}

func (f *fakeDocker) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	f.requests = append(f.requests, r.Method+" "+r.URL.RequestURI())
	f.mu.Unlock()

	if r.Method != http.MethodGet {
		http.Error(w, "read-only", http.StatusMethodNotAllowed)
		return
	}
	switch {
	case r.URL.Path == "/containers/json" && r.URL.Query().Get("all") == "1":
		serveFile(w, "testdata/containers.json")
	case strings.HasPrefix(r.URL.Path, "/containers/") && strings.HasSuffix(r.URL.Path, "/json"):
		id := filepath.Base(strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/containers/"), "/json"))
		serveFile(w, filepath.Join("testdata", "inspect", id+".json"))
	default:
		http.NotFound(w, r)
	}
}

func (f *fakeDocker) seen() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.requests)
}

func serveFile(w http.ResponseWriter, path string) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		http.Error(w, `{"message":"No such container"}`, http.StatusNotFound)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(data)
}

// startUnixDocker serves fakeDocker on a unix socket and returns its DOCKER_HOST.
func startUnixDocker(t *testing.T) (*fakeDocker, string) {
	t.Helper()
	// Short dir: unix socket paths are limited to ~104 bytes on macOS.
	dir, err := os.MkdirTemp("", "dk")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	sock := filepath.Join(dir, "d.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	fake := &fakeDocker{}
	srv := httptest.NewUnstartedServer(fake)
	srv.Listener.Close()
	srv.Listener = ln
	srv.Start()
	t.Cleanup(srv.Close)
	return fake, "unix://" + sock
}

func mustDocker(t *testing.T, host string) *dockerClient {
	t.Helper()
	dc, err := newDockerClient(host)
	if err != nil {
		t.Fatal(err)
	}
	return dc
}

func testAgent(t *testing.T, dockerHost string, cfg config) *agent {
	cfg.dockerHost = dockerHost
	return &agent{
		cfg:    cfg,
		docker: mustDocker(t, dockerHost),
		http:   &http.Client{Timeout: 5 * time.Second},
		log:    slog.New(slog.NewTextHandler(io.Discard, nil)),
		rand:   func() float64 { return 0.5 },
	}
}

var wantContainers = []kamalContainer{
	{
		ID: strings.Repeat("d4", 32), Name: "kamal-proxy", Image: "basecamp/kamal-proxy:v0.10.3",
		Kind: kindProxy, State: "running", StartedAt: "2026-11-16T00:00:00Z",
	},
	{
		ID: strings.Repeat("c3", 32), Name: "web-db", Image: "postgres:17", Service: "web-db",
		Kind: kindAccessory, State: "running", StartedAt: "2026-11-16T00:00:00Z",
	},
	{
		ID: strings.Repeat("b2", 32), Name: "web-web-" + shaNoDst,
		Image:   "registry.example.com/acme/web:" + shaNoDst,
		Service: "web", Role: "web", Version: shaNoDst,
		Kind: kindApp, State: "exited", StartedAt: "2026-11-20T08:30:00Z",
	},
	{
		ID: strings.Repeat("a1", 32), Name: "web-web-production-" + shaProd,
		Image:   "registry.example.com/acme/web:" + shaProd,
		Service: "web", Role: "web", Destination: "production", Version: shaProd,
		Kind: kindApp, State: "running", Health: "healthy", StartedAt: "2026-11-25T10:00:00.123456789Z",
	},
}

func TestCollectContainersOverUnixSocket(t *testing.T) {
	fake, host := startUnixDocker(t)
	got, err := collectContainers(context.Background(), mustDocker(t, host))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, wantContainers) {
		gotJSON, _ := json.MarshalIndent(got, "", "  ")
		t.Fatalf("containers mismatch:\n%s", gotJSON)
	}

	want := []string{
		"GET /containers/json?all=1",
		"GET /containers/" + strings.Repeat("a1", 32) + "/json",
		"GET /containers/" + strings.Repeat("b2", 32) + "/json",
		"GET /containers/" + strings.Repeat("c3", 32) + "/json",
		"GET /containers/" + strings.Repeat("d4", 32) + "/json",
	}
	if seen := fake.seen(); !reflect.DeepEqual(seen, want) {
		t.Fatalf("docker requests = %q, want %q (the unrelated container must not be inspected)", seen, want)
	}
}

func TestCollectContainersOverTCP(t *testing.T) {
	srv := httptest.NewServer(&fakeDocker{})
	defer srv.Close()
	got, err := collectContainers(context.Background(), mustDocker(t, "tcp://"+srv.Listener.Addr().String()))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(wantContainers) {
		t.Fatalf("got %d containers, want %d", len(got), len(wantContainers))
	}
}

func TestCollectSkipsContainerRemovedBeforeInspect(t *testing.T) {
	list := `[{"Id":"gone","Names":["/web-web-abc"],"Labels":{"service":"web","role":"web"}}]`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/containers/json" {
			io.WriteString(w, list)
			return
		}
		http.Error(w, `{"message":"No such container"}`, http.StatusNotFound)
	}))
	defer srv.Close()
	got, err := collectContainers(context.Background(), mustDocker(t, srv.URL))
	if err != nil || len(got) != 0 {
		t.Fatalf("got %v, %v; want no containers and no error", got, err)
	}
}

func TestClassify(t *testing.T) {
	tests := []struct {
		name    string
		labels  map[string]string
		ok      bool
		kind    string
		version string
	}{
		{"web-web-production-abc123", map[string]string{"service": "web", "role": "web", "destination": "production"}, true, kindApp, "abc123"},
		{"web-web-abc123", map[string]string{"service": "web", "role": "web", "destination": ""}, true, kindApp, "abc123"},
		{"web-web-abc123", map[string]string{"service": "web", "role": "web"}, true, kindApp, "abc123"},
		{"web-workers-staging-abc123_uncommitted_0123", map[string]string{"service": "web", "role": "workers", "destination": "staging"}, true, kindApp, "abc123_uncommitted_0123"},
		{"renamed-by-hand", map[string]string{"service": "web", "role": "web"}, true, kindApp, ""},
		{"web-redis", map[string]string{"service": "web-redis"}, true, kindAccessory, ""},
		{"kamal-proxy", nil, true, kindProxy, ""},
		{"grafana", map[string]string{"com.docker.compose.service": "grafana"}, false, "", ""},
		{"loner", map[string]string{"role": "web"}, false, "", ""},
	}
	for _, tt := range tests {
		c, ok := classify(tt.name, tt.labels)
		if ok != tt.ok || c.Kind != tt.kind || c.Version != tt.version {
			t.Errorf("classify(%q, %v) = kind %q version %q ok %v; want %q %q %v",
				tt.name, tt.labels, c.Kind, c.Version, ok, tt.kind, tt.version, tt.ok)
		}
	}
}

func TestSnapshotShapeAndNoSecrets(t *testing.T) {
	_, host := startUnixDocker(t)
	a := testAgent(t, host, config{
		machineID: "0123456789abcdef0123456789abcdef",
		hostname:  "app-1.example.com",
		labels:    map[string]string{"region": "sgp", "provider": "ovh"},
		interval:  defaultInterval,
	})
	body, err := a.snapshotBody(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	for _, forbidden := range []string{"SHOULD_NOT_LEAK", `"Env"`, `"Cmd"`, `"Mounts"`, `"Args"`, "Binds", "Entrypoint", "postgres://", "/srv/"} {
		if strings.Contains(string(body), forbidden) {
			t.Errorf("snapshot contains %q:\n%s", forbidden, body)
		}
	}

	var doc map[string]json.RawMessage
	if err := json.Unmarshal(body, &doc); err != nil {
		t.Fatal(err)
	}
	assertKeys(t, "snapshot", doc, "agent_version", "machine_id", "hostname", "interval_seconds", "labels", "containers")
	if got := string(doc["interval_seconds"]); got != "15" {
		t.Errorf("interval_seconds = %s, want 15, the default interval before jitter", got)
	}

	var containers []map[string]json.RawMessage
	json.Unmarshal(doc["containers"], &containers)
	if len(containers) != 4 {
		t.Fatalf("got %d containers, want 4", len(containers))
	}
	for _, c := range containers {
		assertKeys(t, "container", c, "id", "name", "image", "service", "role", "destination", "version", "kind", "state", "health", "started_at")
	}
}

func assertKeys(t *testing.T, what string, m map[string]json.RawMessage, want ...string) {
	t.Helper()
	var got []string
	for k := range m {
		got = append(got, k)
	}
	slices.Sort(got)
	slices.Sort(want)
	if !slices.Equal(got, want) {
		t.Errorf("%s keys = %v, want %v", what, got, want)
	}
}

func TestNextDelay(t *testing.T) {
	tests := []struct {
		failures int
		r        float64
		want     time.Duration
	}{
		{0, 0.5, 15 * time.Second},
		{0, 0, 12 * time.Second},
		{0, 0.999999, 18 * time.Second},
		{1, 0.5, 30 * time.Second},
		{3, 0.5, 120 * time.Second},
		{5, 0.5, maxBackoff},
		{100, 0.999999, maxBackoff},
		{100, 0, 4 * time.Minute}, // jittered below the cap too, so a fleet spreads out
	}
	for _, tt := range tests {
		got := nextDelay(15*time.Second, tt.failures, tt.r).Round(time.Second)
		if got != tt.want {
			t.Errorf("nextDelay(15s, %d, %v) = %s, want %s", tt.failures, tt.r, got, tt.want)
		}
	}
}

// A long interval is the agent's own pace, not a backoff: it is kept until
// a failure, and the first failure retries within maxBackoff.
func TestNextDelayKeepsAnIntervalLongerThanTheCap(t *testing.T) {
	if got := nextDelay(10*time.Minute, 0, 0.5); got != 10*time.Minute {
		t.Errorf("no failure: %s, want the 10m interval", got)
	}
	if got := nextDelay(10*time.Minute, 1, 0.999999); got != maxBackoff {
		t.Errorf("one failure: %s, want %s", got, maxBackoff)
	}
}

func TestEncodeCappedTruncatesContainers(t *testing.T) {
	snap := snapshot{AgentVersion: "test", MachineID: "m", Hostname: "h"}
	for range 20000 {
		snap.Containers = append(snap.Containers, kamalContainer{
			ID: strings.Repeat("f", 64), Name: "web-web-production-" + shaProd, Image: "registry.example.com/acme/web:" + shaProd,
			Service: "web", Role: "web", Destination: "production", Version: shaProd, Kind: kindApp, State: "running",
		})
	}
	body, truncated, err := encodeCapped(snap, maxPayload)
	if err != nil {
		t.Fatal(err)
	}
	if !truncated || len(body) > maxPayload {
		t.Fatalf("truncated=%v len=%d; want truncated and <= %d", truncated, len(body), maxPayload)
	}
	var got snapshot
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatal(err)
	}
	if !got.Truncated || len(got.Containers) == 0 || len(got.Containers) >= 20000 {
		t.Fatalf("decoded truncated=%v containers=%d", got.Truncated, len(got.Containers))
	}
	// One more container must not have fit.
	got.Containers = append(got.Containers, snap.Containers[0])
	if b, _ := json.Marshal(got); len(b) <= maxPayload {
		t.Fatalf("truncation dropped more than necessary")
	}
}

func TestEncodeCappedSmallSnapshotUntouched(t *testing.T) {
	body, truncated, err := encodeCapped(snapshot{MachineID: "m"}, maxPayload)
	if err != nil || truncated {
		t.Fatalf("truncated=%v err=%v", truncated, err)
	}
	if !strings.Contains(string(body), `"containers":[]`) || !strings.Contains(string(body), `"labels":{}`) {
		t.Fatalf("empty collections must encode as [] and {}: %s", body)
	}
}

func TestEncodeCappedErrorsInsteadOfPanicking(t *testing.T) {
	snap := snapshot{Labels: map[string]string{"huge": strings.Repeat("x", 2*maxPayload)}, Containers: []kamalContainer{{Name: "a"}}}
	if _, _, err := encodeCapped(snap, maxPayload); err == nil {
		t.Fatal("want error when labels alone exceed the cap")
	}
}

func TestPostSnapshot(t *testing.T) {
	var gotAuth, gotType, gotPath, gotMethod string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth, gotType, gotPath, gotMethod = r.Header.Get("Authorization"), r.Header.Get("Content-Type"), r.URL.Path, r.Method
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()

	if err := postSnapshot(context.Background(), srv.Client(), srv.URL+postPath, "tok", []byte(`{}`)); err != nil {
		t.Fatal(err)
	}
	if gotMethod != http.MethodPost || gotPath != "/agent/snapshots" || gotAuth != "Bearer tok" || gotType != "application/json" {
		t.Fatalf("method=%q path=%q auth=%q type=%q", gotMethod, gotPath, gotAuth, gotType)
	}
}

func TestPostSnapshotRejectsNon2xx(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "nope", http.StatusUnauthorized)
	}))
	defer srv.Close()
	if err := postSnapshot(context.Background(), srv.Client(), srv.URL, "bad", []byte(`{}`)); err == nil {
		t.Fatal("want error on 401")
	}
}

// A redirect is a failure, never followed: following it would resend the
// token, over plain http if that is where it points.
func TestPostSnapshotDoesNotFollowRedirects(t *testing.T) {
	var redirectedAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/elsewhere" {
			redirectedAuth = r.Header.Get("Authorization")
			w.WriteHeader(http.StatusAccepted)
			return
		}
		http.Redirect(w, r, "/elsewhere", http.StatusPermanentRedirect)
	}))
	defer srv.Close()
	err := postSnapshot(context.Background(), newSnapshotClient(), srv.URL+postPath, "tok", []byte(`{}`))
	if err == nil || !strings.Contains(err.Error(), "308") {
		t.Fatalf("err = %v, want the 308 reported as an unexpected status", err)
	}
	if redirectedAuth != "" {
		t.Fatal("the redirect was followed and the token sent again")
	}
}

func TestIntervalSecondsIsWholeAndAtLeastOne(t *testing.T) {
	for d, want := range map[time.Duration]int{15 * time.Second: 15, time.Minute: 60, 1500 * time.Millisecond: 2, time.Second: 1, 1100 * time.Millisecond: 1} {
		if got := intervalSeconds(d); got != want {
			t.Errorf("intervalSeconds(%v) = %d, want %d", d, got, want)
		}
	}
}

// A 429 says when to come back: the agent waits at least that long, even
// when its own backoff would retry sooner.
func TestPostSnapshotHonoursRetryAfterOn429(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Retry-After", "120")
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer srv.Close()
	err := postSnapshot(context.Background(), srv.Client(), srv.URL, "t", []byte(`{}`))
	if err == nil {
		t.Fatal("want an error on 429")
	}
	a := &agent{cfg: config{interval: defaultInterval}, rand: func() float64 { return 0 }}
	if got := a.delayAfter(err, 1); got < 2*time.Minute {
		t.Fatalf("after a 429 with Retry-After: 120 the agent retries in %v", got)
	}
	if got := a.delayAfter(errors.New("boom"), 1); got != 24*time.Second {
		t.Fatalf("an ordinary failure waits %v, want the doubled, jittered interval (24s)", got)
	}
}

func TestParseRetryAfter(t *testing.T) {
	now := time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC)
	for v, want := range map[string]time.Duration{
		"30":                            30 * time.Second,
		"0":                             0,
		"-5":                            0,
		"86400":                         maxBackoff,
		"Thu, 26 Nov 2026 12:01:00 GMT": time.Minute,
		"Thu, 26 Nov 2026 11:00:00 GMT": 0,
		"soon":                          0,
		"":                              0,
	} {
		if got := parseRetryAfter(v, now); got != want {
			t.Errorf("parseRetryAfter(%q) = %v, want %v", v, got, want)
		}
	}
}

func TestRunPostsImmediatelyAndStopsOnCancel(t *testing.T) {
	_, host := startUnixDocker(t)
	received := make(chan snapshot, 1)
	meridian := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var s snapshot
		json.NewDecoder(r.Body).Decode(&s)
		select {
		case received <- s:
		default:
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer meridian.Close()

	a := testAgent(t, host, config{url: meridian.URL, token: "t", interval: time.Hour, machineID: "m"})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { a.run(ctx); close(done) }()

	select {
	case s := <-received:
		if len(s.Containers) != 4 || s.MachineID != "m" {
			t.Fatalf("unexpected snapshot %+v", s)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no snapshot posted")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("run did not return after cancel")
	}
}

func TestTickRecoversFromPanic(t *testing.T) {
	a := &agent{} // nil docker client: collectContainers dereferences it
	if err := a.tick(context.Background()); err == nil || !strings.Contains(err.Error(), "panic") {
		t.Fatalf("tick err = %v, want recovered panic", err)
	}
}

func TestLoadConfig(t *testing.T) {
	env := map[string]string{
		"MERIDIAN_URL":      "https://meridian.example.com/",
		"MERIDIAN_TOKEN":    "secret",
		"MERIDIAN_LABELS":   " region=sgp, provider=ovh ,",
		"MERIDIAN_INTERVAL": "30",
	}
	files := map[string]string{"/host/etc/machine-id": "hostid\n", "/etc/machine-id": "containerid\n", "/host/etc/hostname": "app-1\n"}
	readFile := func(p string) ([]byte, error) {
		if s, ok := files[p]; ok {
			return []byte(s), nil
		}
		return nil, fs.ErrNotExist
	}
	getenv := func(k string) string { return env[k] }

	cfg, err := loadConfig(getenv, readFile, true)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.url != "https://meridian.example.com" || cfg.interval != 30*time.Second || cfg.machineID != "hostid" || cfg.hostname != "app-1" {
		t.Fatalf("cfg = %+v", cfg)
	}
	if !reflect.DeepEqual(cfg.labels, map[string]string{"region": "sgp", "provider": "ovh"}) {
		t.Fatalf("labels = %v", cfg.labels)
	}

	env["MERIDIAN_MACHINE_ID"] = "override"
	if cfg, _ := loadConfig(getenv, readFile, true); cfg.machineID != "override" {
		t.Fatalf("MERIDIAN_MACHINE_ID should win, got %q", cfg.machineID)
	}

	for key, bad := range map[string]string{"MERIDIAN_LABELS": "region", "MERIDIAN_INTERVAL": "soon", "MERIDIAN_URL": "ftp://x"} {
		old := env[key]
		env[key] = bad
		if _, err := loadConfig(getenv, readFile, true); err == nil {
			t.Errorf("%s=%q: want error", key, bad)
		}
		env[key] = old
	}

	delete(env, "MERIDIAN_TOKEN")
	if _, err := loadConfig(getenv, readFile, true); err == nil {
		t.Error("missing token: want error")
	}
	if _, err := loadConfig(getenv, readFile, false); err != nil {
		t.Errorf("print mode should not need a token: %v", err)
	}
}

// An HTTP_PROXY set for reaching Meridian must not carry Docker traffic:
// inspect responses hold every container's environment.
func TestDockerClientNeverUsesAnHTTPProxy(t *testing.T) {
	for _, host := range []string{"tcp://web-meridian_docker:2375", "unix:///var/run/docker.sock"} {
		c, err := newDockerClient(host)
		if err != nil {
			t.Fatal(err)
		}
		for name, client := range map[string]*http.Client{"one-shot": c.http, "stream": c.stream} {
			tr, ok := client.Transport.(*http.Transport)
			if !ok {
				t.Fatalf("%s %s client uses %T, which honours HTTP_PROXY", host, name, client.Transport)
			}
			if tr.Proxy != nil {
				t.Fatalf("%s %s client has a proxy function", host, name)
			}
		}
	}
}

func TestNewDockerClientRejectsUnknownScheme(t *testing.T) {
	if _, err := newDockerClient("ssh://host"); err == nil {
		t.Fatal("want error for ssh://")
	}
}

func TestPlainHTTP(t *testing.T) {
	for raw, want := range map[string]bool{
		"https://meridian.example.com": false,
		"http://localhost:3000":        false,
		"http://meridian.localhost":    false,
		"http://127.0.0.1:3000":        false,
		"http://[::1]:3000":            false,
		"http://meridian.example.com":  true,
		"http://10.0.0.5:3000":         true,
		"":                             false,
	} {
		if got := plainHTTP(raw); got != want {
			t.Errorf("plainHTTP(%q) = %v, want %v", raw, got, want)
		}
	}
}
