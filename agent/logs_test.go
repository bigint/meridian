package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"runtime"
	"slices"
	"strings"
	"testing"
	"testing/iotest"
	"time"
)

// ---- the Docker log stream: bytes in, lines out ----

// muxFrame is one frame of a multiplexed stream: stream 1 is stdout, 2 stderr.
func muxFrame(stream byte, payload string) []byte {
	return append(binary.BigEndian.AppendUint32([]byte{stream, 0, 0, 0}, uint32(len(payload))), payload...)
}

func readAllLogs(t *testing.T, r io.Reader, tty bool) ([]logLine, error) {
	t.Helper()
	var got []logLine
	err := readLogs(r, tty, func(l logLine) bool { got = append(got, l); return true })
	return got, err
}

// lineView is a line as the wire shows it.
type lineView struct{ T, S, M string }

func views(lines []logLine) []lineView {
	out := make([]lineView, len(lines))
	for i, l := range lines {
		out[i] = lineView{l.T, l.S, l.M}
	}
	return out
}

func TestReadLogsDemultiplexesAndSplitsLinesAcrossFrames(t *testing.T) {
	const (
		t1 = "2026-11-26T12:16:25.100000000Z"
		t2 = "2026-11-26T12:16:25.150000000Z"
		t3 = "2026-11-26T12:16:25.300000000Z"
		t4 = "2026-11-26T12:16:25.400000000Z"
	)
	// A stdout line that spans three frames with a whole stderr line in
	// between, then two more lines glued to the end of a frame.
	stream := slices.Concat(
		muxFrame(1, t1+" GET / 2"),
		muxFrame(2, t2+" warn: slow query\n"),
		muxFrame(1, "00 1."),
		muxFrame(1, "2ms\n"+t3+" second\n"+t4[:11]),
		muxFrame(1, t4[11:]+" third\n"),
	)
	want := []lineView{
		{t2, "err", "warn: slow query"},
		{t1, "out", "GET / 200 1.2ms"},
		{t3, "out", "second"},
		{t4, "out", "third"},
	}
	for name, r := range map[string]io.Reader{
		"in one read":      bytes.NewReader(stream),
		"a byte at a time": iotest.OneByteReader(bytes.NewReader(stream)),
		"in half-reads":    iotest.HalfReader(bytes.NewReader(stream)),
	} {
		got, err := readAllLogs(t, r, false)
		if err != nil || !slices.Equal(views(got), want) {
			t.Errorf("%s: err=%v\ngot  %+v\nwant %+v", name, err, views(got), want)
		}
	}
}

func TestReadLogsRawTTYStreamIsAllStdout(t *testing.T) {
	// A TTY has no frame headers, and its newlines are \r\n.
	raw := "2026-11-26T12:00:00.000000001Z first\r\n2026-11-26T12:00:00.000000002Z sec" + "ond\r\n2026-11-26T12:00:00.000000003Z no newline at the end"
	want := []lineView{
		{"2026-11-26T12:00:00.000000001Z", "out", "first"},
		{"2026-11-26T12:00:00.000000002Z", "out", "second"},
		{"2026-11-26T12:00:00.000000003Z", "out", "no newline at the end"},
	}
	for name, r := range map[string]io.Reader{"whole": strings.NewReader(raw), "bytewise": iotest.OneByteReader(strings.NewReader(raw))} {
		got, err := readAllLogs(t, r, true)
		if err != nil || !slices.Equal(views(got), want) {
			t.Errorf("%s: err=%v\ngot  %+v\nwant %+v", name, err, views(got), want)
		}
	}
}

func TestReadLogsEndsCleanlyOrReportsWhyNot(t *testing.T) {
	const ts = "2026-11-26T12:00:00.000000000Z "
	whole := slices.Concat(muxFrame(1, ts+"one\n"), muxFrame(2, ts+"par"))

	t.Run("a clean end, with the partial last line still delivered", func(t *testing.T) {
		got, err := readAllLogs(t, bytes.NewReader(whole), false)
		if err != nil || len(got) != 2 || got[1].M != "par" || got[1].S != "err" {
			t.Fatalf("err=%v lines=%+v", err, views(got))
		}
	})
	t.Run("cut off in the middle of a frame", func(t *testing.T) {
		got, err := readAllLogs(t, bytes.NewReader(whole[:len(whole)-1]), false)
		if !errors.Is(err, io.ErrUnexpectedEOF) || len(got) != 2 {
			t.Fatalf("err=%v lines=%+v, want an unexpected EOF and what was read", err, views(got))
		}
	})
	t.Run("cut off in the middle of a header", func(t *testing.T) {
		if _, err := readAllLogs(t, bytes.NewReader(slices.Concat(whole, []byte{1, 0, 0})), false); !errors.Is(err, io.ErrUnexpectedEOF) {
			t.Fatalf("err=%v, want an unexpected EOF", err)
		}
	})
	t.Run("not a multiplexed stream at all", func(t *testing.T) {
		for _, junk := range []string{"2026-11-26T12:00:00Z plain text\n", string([]byte{3, 0, 0, 0, 0, 0, 0, 1, 'x'})} {
			if _, err := readAllLogs(t, strings.NewReader(junk), false); !errors.Is(err, errBadFrame) {
				t.Errorf("%q: err=%v, want errBadFrame", junk, err)
			}
		}
	})
	t.Run("the caller stops it", func(t *testing.T) {
		n := 0
		err := readLogs(bytes.NewReader(whole), false, func(logLine) bool { n++; return false })
		if err != nil || n != 1 {
			t.Fatalf("err=%v after %d lines, want to stop at the first", err, n)
		}
	})
}

func TestReadLogsSplitsTheTimestampOff(t *testing.T) {
	for _, tc := range []struct {
		raw          string
		wantT, wantM string
	}{
		{"2026-11-26T12:16:25.123456789Z GET / 200", "2026-11-26T12:16:25.123456789Z", "GET / 200"},
		{"2026-11-26T14:16:25.5+02:00 other zone", "2026-11-26T14:16:25.5+02:00", "other zone"},
		{"2026-11-26T12:16:25.123456789Z  two spaces", "2026-11-26T12:16:25.123456789Z", " two spaces"},
		{"2026-11-26T12:16:25.123456789Z ", "2026-11-26T12:16:25.123456789Z", ""},
		// Not a timestamp: nothing is split off, nothing is lost.
		{"hello world", "", "hello world"},
		{"2026-13-45T99:99:99Z impossible", "", "2026-13-45T99:99:99Z impossible"},
		{strings.Repeat("x", 60) + " late space", "", strings.Repeat("x", 60) + " late space"},
	} {
		got, err := readAllLogs(t, strings.NewReader(tc.raw+"\n"), true)
		if err != nil || len(got) != 1 || got[0].T != tc.wantT || got[0].M != tc.wantM {
			t.Errorf("%q: err=%v got %+v, want t=%q m=%q", tc.raw, err, views(got), tc.wantT, tc.wantM)
		}
	}
}

func TestReadLogsMakesMessagesFitTheWireFormat(t *testing.T) {
	const ts = "2026-11-26T12:16:25.123456789Z "
	line := func(msg string) string { return ts + msg + "\n" }
	one := func(t *testing.T, msg string) string {
		t.Helper()
		got, err := readAllLogs(t, strings.NewReader(line(msg)), true)
		if err != nil || len(got) != 1 {
			t.Fatalf("err=%v lines=%d", err, len(got))
		}
		return got[0].M
	}

	t.Run("CRLF loses its carriage return, an inner one stays", func(t *testing.T) {
		if got := one(t, "windows\r"); got != "windows" {
			t.Errorf("got %q", got)
		}
		if got := one(t, "progress 10%\rprogress 20%\r"); got != "progress 10%\rprogress 20%" {
			t.Errorf("got %q", got)
		}
	})
	t.Run("every invalid byte becomes U+FFFD, valid text is untouched", func(t *testing.T) {
		if got, want := one(t, "caf\xc3\xa9 \xff\xfe ok \xe2\x82 €"), "café �� ok �� €"; got != want {
			t.Errorf("got %q, want %q", got, want)
		}
	})
	t.Run("ANSI escapes pass through", func(t *testing.T) {
		if got := one(t, "\x1b[31mred\x1b[0m"); got != "\x1b[31mred\x1b[0m" {
			t.Errorf("got %q", got)
		}
	})
	t.Run("8192 bytes stay whole, one more is cut with an ellipsis", func(t *testing.T) {
		if got := one(t, strings.Repeat("x", 8192)); got != strings.Repeat("x", 8192) {
			t.Errorf("8192 bytes: got %d bytes", len(got))
		}
		if got, want := one(t, strings.Repeat("x", 8193)), strings.Repeat("x", 8192)+"…"; got != want {
			t.Errorf("8193 bytes: got %d bytes ending %q", len(got), got[len(got)-6:])
		}
	})
	t.Run("the cut never splits a character", func(t *testing.T) {
		// "é" takes bytes 8191 and 8192 (0-based): cutting at 8192 would halve it.
		if got, want := one(t, strings.Repeat("a", 8191)+"é"+"tail"), strings.Repeat("a", 8191)+"…"; got != want {
			t.Errorf("got %d bytes, want the 8191 a's and an ellipsis", len(got))
		}
	})
	t.Run("invalid bytes are replaced before the cut is measured", func(t *testing.T) {
		// 3000 invalid bytes become 9000 bytes of U+FFFD.
		got := one(t, strings.Repeat("\xff", 3000))
		if len(got) != 8190+len("…") || !strings.HasSuffix(got, "�…") {
			t.Errorf("got %d bytes", len(got))
		}
	})
	t.Run("a huge line is bounded and the next one is unharmed", func(t *testing.T) {
		stream := ts + strings.Repeat("y", 4<<20) + "\n" + line("after")
		got, err := readAllLogs(t, strings.NewReader(stream), true)
		if err != nil || len(got) != 2 {
			t.Fatalf("err=%v lines=%d", err, len(got))
		}
		if got[0].M != strings.Repeat("y", 8192)+"…" || got[1].M != "after" || got[1].T == "" {
			t.Errorf("first is %d bytes; second is %+v", len(got[0].M), got[1])
		}
	})
}

// repeatReader is n bytes of one byte value.
type repeatReader struct {
	b byte
	n int
}

func (r *repeatReader) Read(p []byte) (int, error) {
	if r.n == 0 {
		return 0, io.EOF
	}
	n := min(len(p), r.n)
	for i := range n {
		p[i] = r.b
	}
	r.n -= n
	return n, nil
}

func TestReadLogsDoesNotBufferALineWithoutANewline(t *testing.T) {
	// 64 MiB of one line: a reader that kept it would allocate at least that.
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	var got []logLine
	stream := io.MultiReader(strings.NewReader("2026-11-26T12:16:25Z "), &repeatReader{'z', 64 << 20}, strings.NewReader("\nnext\n"))
	err := readLogs(stream, true, func(l logLine) bool { got = append(got, l); return true })
	runtime.ReadMemStats(&after)
	if err != nil || len(got) != 2 || len(got[0].M) != 8192+len("…") || got[1].M != "next" {
		t.Fatalf("err=%v lines=%d", err, len(got))
	}
	if alloc := after.TotalAlloc - before.TotalAlloc; alloc > 16<<20 {
		t.Fatalf("reading one 64 MiB line allocated %d MiB", alloc>>20)
	}
}

// ---- batching ----

// batchRig is a batcher on a clock the test turns.
type batchRig struct {
	clock   *fakeClock
	b       *batcher
	batches []logBatch
}

func newBatchRig() *batchRig {
	r := &batchRig{clock: newFakeClock()}
	r.b = newBatcher("c0ffee", r.clock.Now, func(b logBatch) { r.batches = append(r.batches, b) })
	return r
}

func (r *batchRig) add(history bool, ms ...string) {
	for _, m := range ms {
		r.b.add(logLine{T: "t", S: "out", M: m}, history)
	}
}

func lineCounts(batches []logBatch) []int {
	var out []int
	for _, b := range batches {
		out = append(out, len(b.Lines))
	}
	return out
}

func TestBatcherSendsAtMostFiveHundredLinesPerBatchAndEveryQuarterSecond(t *testing.T) {
	r := newBatchRig()
	for range 1200 {
		r.add(false, "x")
	}
	if got := lineCounts(r.batches); !slices.Equal(got, []int{500, 500}) {
		t.Fatalf("batches of %v, want two full ones of 500", got)
	}
	r.clock.Advance(249 * time.Millisecond)
	r.b.flushDue()
	if len(r.batches) != 2 {
		t.Fatal("the rest went out before 250ms")
	}
	r.clock.Advance(time.Millisecond)
	r.b.flushDue()
	if got := lineCounts(r.batches); !slices.Equal(got, []int{500, 500, 200}) {
		t.Fatalf("batches of %v, want the last 200 once the batch is 250ms old", got)
	}
	r.clock.Advance(time.Hour)
	r.b.flushDue()
	if len(r.batches) != 3 {
		t.Fatal("an empty batch was sent")
	}
}

func TestBatcherKeepsABatchUnder256KiBOfMessage(t *testing.T) {
	r := newBatchRig()
	chunk := strings.Repeat("m", 8000)
	for range 60 { // 480000 bytes: under the second's budget, over the batch size
		r.add(false, chunk)
	}
	r.b.flush(false)
	for _, b := range r.batches {
		size := 0
		for _, l := range b.Lines {
			size += len(l.M)
		}
		if size > 256<<10 {
			t.Errorf("a batch carries %d bytes of message", size)
		}
	}
	if got := lineCounts(r.batches); !slices.Equal(got, []int{32, 28}) {
		t.Fatalf("batches of %v, want 32 (256000 bytes) then the remaining 28", got)
	}
}

func TestBatcherDropsAndCountsLinesBeyondHalfAMiBPerSecond(t *testing.T) {
	r := newBatchRig()
	chunk := strings.Repeat("m", 8000)
	for range 80 { // 640000 bytes offered in one second: 65 fit under 524288
		r.add(false, chunk)
	}
	r.clock.Advance(batchEvery)
	r.b.flushDue()
	kept, dropped := 0, 0
	for _, b := range r.batches {
		kept += len(b.Lines)
		dropped += b.Dropped
	}
	if kept != 65 || dropped != 15 {
		t.Fatalf("kept %d lines and reported %d dropped, want 65 and 15", kept, dropped)
	}
	if last := r.batches[len(r.batches)-1]; last.Dropped != 15 {
		t.Fatalf("the drops should be reported in the batch after them, got %+v", lineCounts(r.batches))
	}

	// The next second has a fresh budget, and the drops are not reported again.
	r.clock.Advance(time.Second)
	r.add(false, chunk)
	r.clock.Advance(batchEvery)
	r.b.flushDue()
	last := r.batches[len(r.batches)-1]
	if len(last.Lines) != 1 || last.Lines[0].M != chunk || last.Dropped != 0 {
		t.Fatalf("last batch = %d lines, dropped %d, want the one fresh line and no drops", len(last.Lines), last.Dropped)
	}
}

// The budget charges each line its JSON overhead, so a container printing
// blank lines (m is "" once the timestamp is off) is bounded too.
func TestBatcherChargesEveryLineAnOverhead(t *testing.T) {
	r := newBatchRig()
	for range 100_000 { // one second of blank lines
		r.add(false, "")
	}
	r.b.flush(false)
	kept, dropped := 0, 0
	for _, b := range r.batches {
		kept += len(b.Lines)
		dropped += b.Dropped
	}
	if want := budgetBytes / lineOverhead; kept != want || dropped != 100_000-want {
		t.Fatalf("kept %d blank lines and dropped %d, want %d kept", kept, dropped, want)
	}
}

// A caller that waits while the batch is held sends at most one batch per
// batchEvery, however fast lines come: AgentChannel drops an agent's frames
// past 100 a second, and an agent tails up to 20 containers.
func TestBatcherFullBatchesWaitTheirTurn(t *testing.T) {
	r := newBatchRig()
	var sentAt []time.Time
	r.b.emit = func(b logBatch) { r.batches = append(r.batches, b); sentAt = append(sentAt, r.clock.Now()) }
	for added := 0; added < 5000; {
		if r.b.held() {
			r.clock.Advance(time.Millisecond)
			r.b.flushDue()
			continue
		}
		r.add(false, "x")
		added++
	}
	r.clock.Advance(batchEvery)
	r.b.flushDue()
	lines := 0
	for _, b := range r.batches {
		lines += len(b.Lines)
	}
	if lines != 5000 {
		t.Fatalf("%d of 5000 lines went out", lines)
	}
	for i := 1; i < len(sentAt); i++ {
		if gap := sentAt[i].Sub(sentAt[i-1]); gap < batchEvery {
			t.Fatalf("batch %d went out %v after the one before, want at least %v", i, gap, batchEvery)
		}
	}
}

func TestBatcherReportsDropsEvenWithoutLines(t *testing.T) {
	r := newBatchRig()
	chunk := strings.Repeat("m", 8000)
	for range 70 { // spend the second's budget
		r.add(false, chunk)
	}
	r.b.flush(false)
	r.batches = nil

	r.add(false, chunk) // over budget: dropped, and no line to carry the count
	r.clock.Advance(batchEvery)
	r.b.flushDue()
	if len(r.batches) != 1 || len(r.batches[0].Lines) != 0 || r.batches[0].Dropped != 1 {
		t.Fatalf("batches = %+v, want one with no lines and dropped 1", r.batches)
	}
}

func TestBatcherKeepsHistoryAndLiveLinesApart(t *testing.T) {
	r := newBatchRig()
	r.add(true, "old 1", "old 2")
	r.add(false, "new 1")
	r.add(true, "old 3") // a late history line starts its own batch
	r.b.flush(false)
	var got []string
	for _, b := range r.batches {
		for _, l := range b.Lines {
			got = append(got, fmt.Sprintf("%v:%s", b.Backlog, l.M))
		}
	}
	if want := []string{"true:old 1", "true:old 2", "false:new 1", "true:old 3"}; !slices.Equal(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	if got := lineCounts(r.batches); !slices.Equal(got, []int{2, 1, 1}) {
		t.Fatalf("batches of %v", got)
	}
}

func TestBatcherEndsWithTheLastLinesOrOnItsOwn(t *testing.T) {
	r := newBatchRig()
	r.add(false, "last words")
	r.b.finish()
	if len(r.batches) != 1 || !r.batches[0].Ended || len(r.batches[0].Lines) != 1 {
		t.Fatalf("batches = %+v, want one batch with the line and ended", r.batches)
	}

	r = newBatchRig()
	r.b.finish()
	if len(r.batches) != 1 || !r.batches[0].Ended || len(r.batches[0].Lines) != 0 {
		t.Fatalf("batches = %+v, want an empty batch with ended", r.batches)
	}
}

func TestBatchesHaveTheDocumentedShape(t *testing.T) {
	batch := logBatch{
		Action: "logs", Container: "c0ffee", Backlog: true, Dropped: 2,
		Lines: []logLine{{T: "2026-11-26T12:16:25.123456789Z", S: "out", M: "GET / 200 1.2ms", at: time.Now()}, {T: "2026-11-26T12:16:25.2Z", S: "err", M: "warn"}},
	}
	got, _ := json.Marshal(batch)
	want := `{"action":"logs","container":"c0ffee","backlog":true,` +
		`"lines":[{"t":"2026-11-26T12:16:25.123456789Z","s":"out","m":"GET / 200 1.2ms"},{"t":"2026-11-26T12:16:25.2Z","s":"err","m":"warn"}],` +
		`"dropped":2,"ended":false}`
	if string(got) != want {
		t.Errorf("batch =  %s\nwant      %s", got, want)
	}

	r := newBatchRig()
	r.b.finish()
	if got, _ := json.Marshal(r.batches[0]); string(got) != `{"action":"logs","container":"c0ffee","backlog":false,"lines":[],"dropped":0,"ended":true}` {
		t.Errorf("an ended batch with no lines = %s; lines must be [], never null", got)
	}

	for _, tc := range []struct {
		reply logReply
		want  string
	}{
		{logReply{Action: "logs", Container: "c0ffee", Off: true}, `{"action":"logs","container":"c0ffee","off":true}`},
		{logReply{Action: "logs", Container: "c0ffee", Refused: "not a Kamal container"}, `{"action":"logs","container":"c0ffee","refused":"not a Kamal container"}`},
	} {
		if got, _ := json.Marshal(tc.reply); string(got) != tc.want {
			t.Errorf("reply = %s, want %s", got, tc.want)
		}
	}
}

// ---- config and identity ----

func TestLoadConfigLogsSwitch(t *testing.T) {
	load := func(logs string) (config, error) {
		env := map[string]string{"MERIDIAN_URL": "https://m.example.com", "MERIDIAN_TOKEN": "t", "MERIDIAN_MACHINE_ID": "m", "MERIDIAN_LOGS": logs}
		return loadConfig(func(k string) string { return env[k] }, func(string) ([]byte, error) { return nil, os.ErrNotExist }, true)
	}
	for logs, want := range map[string]bool{"": false, "0": false, "false": false, "1": true, "true": true, "TRUE": true, "T": true} {
		cfg, err := load(logs)
		if err != nil || cfg.logs != want {
			t.Errorf("MERIDIAN_LOGS=%q: logs=%v err=%v, want logs=%v", logs, cfg.logs, err, want)
		}
	}
	for _, bad := range []string{"maybe", "yes", "on", "2"} {
		if _, err := load(bad); err == nil || !strings.Contains(err.Error(), "MERIDIAN_LOGS") {
			t.Errorf("MERIDIAN_LOGS=%q: err=%v, want an error naming the variable", bad, err)
		}
	}
}

func TestOwnContainerIDComesFromTheMountsThenTheHostname(t *testing.T) {
	id := strings.Repeat("ab12", 16)
	other := strings.Repeat("cd34", 16)
	mountinfo := "2467 2455 0:52 / / rw - overlay overlay rw\n" +
		"2468 2467 8:1 /var/lib/docker/volumes/kamal-proxy-config/_data /kamal-proxy ro - ext4 /dev/sda1 rw\n" +
		"2469 2467 8:1 /var/lib/docker/containers/" + id + "/resolv.conf /etc/resolv.conf rw - ext4 /dev/sda1 rw\n" +
		"2470 2467 8:1 /var/lib/docker/containers/" + id + "/hostname /etc/hostname rw - ext4 /dev/sda1 rw\n"
	files := func(content string, err error) func(string) ([]byte, error) {
		return func(p string) ([]byte, error) {
			if p != "/proc/self/mountinfo" {
				t.Errorf("read %s", p)
			}
			return []byte(content), err
		}
	}
	host := func(h string) func() (string, error) { return func() (string, error) { return h, nil } }

	for _, tc := range []struct {
		name     string
		readFile func(string) ([]byte, error)
		hostname string
		want     string
	}{
		{"mounts", files(mountinfo, nil), "app-1", id},
		{"mounts win over the hostname", files(mountinfo, nil), other[:12], id},
		{"only the agent's own mounts count", files("1 2 0:1 /var/lib/docker/containers/"+other+"/hostname /data/hostname rw - ext4 x rw\n", nil), "app-1", ""},
		{"docker's default hostname is the short id", files("", os.ErrNotExist), other[:12], other[:12]},
		{"a named host is no help", files("", os.ErrNotExist), "app-1", ""},
		{"nor is a 12-letter name", files("", os.ErrNotExist), "my-app-host1", ""},
	} {
		if got := ownContainerID(tc.readFile, host(tc.hostname)); got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}
