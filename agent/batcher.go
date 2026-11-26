package main

import "time"

const (
	batchEvery    = 250 * time.Millisecond // a batch goes out at most this long after its first line
	maxBatchLines = 500
	maxBatchBytes = 256 << 10 // of m per batch
	budgetBytes   = 512 << 10 // of m, plus lineOverhead per line, per second for one container; the rest is dropped
	budgetWindow  = time.Second
	// What a line costs beyond its message: its JSON on the wire (keys, stamp,
	// stream) is about this much, so short and empty lines are not free.
	lineOverhead = 64
)

// batcher groups one container's lines into the batches of the wire format:
// at most maxBatchLines and maxBatchBytes each, out at most batchEvery after
// the first line, and no more than budgetBytes of message (plus lineOverhead a
// line) per second. What the budget refuses is counted and reported in the
// next batch's dropped. Lines from history (the backlog) and live lines never
// share a batch. Batches go out at most once per every, so Meridian's
// per-agent frame cap holds: a caller that finds the batch held either waits
// before adding more (history, which is bounded) or drops the line with skip,
// which counts it like the budget's drops (live lines, which are not).
//
// A batcher belongs to one goroutine; it never blocks and never queues beyond
// the one batch it is building. emit decides what happens to a finished batch.
type batcher struct {
	container string
	now       func() time.Time
	every     time.Duration // batchEvery; tests shorten it
	emit      func(logBatch)

	backlog bool // the batch being built is history
	lines   []logLine
	size    int       // bytes of m in lines
	dropped int       // lines the budget refused since the last batch
	opened  time.Time // when the batch got its first line or drop
	sent    time.Time // when the last batch went out

	window time.Time // start of the current budget second
	used   int       // bytes of m taken in that second
}

func newBatcher(container string, now func() time.Time, emit func(logBatch)) *batcher {
	return &batcher{container: container, now: now, every: batchEvery, emit: emit}
}

// add takes one line, history saying whether it is part of the backlog.
func (b *batcher) add(l logLine, history bool) {
	now := b.now()
	if len(b.lines) > 0 && b.backlog != history {
		b.flush(false)
	}
	if len(b.lines) == 0 {
		b.backlog = history
	}

	if now.Sub(b.window) >= budgetWindow {
		b.window, b.used = now, 0
	}
	cost := len(l.M) + lineOverhead
	if b.used+cost > budgetBytes {
		b.dropped++
		b.touch(now)
		return
	}
	if len(b.lines) >= maxBatchLines || b.size+len(l.M) > maxBatchBytes {
		b.flush(false)
	}
	b.touch(now)
	b.used += cost
	b.size += len(l.M)
	b.lines = append(b.lines, l)
}

func (b *batcher) touch(now time.Time) {
	if b.opened.IsZero() {
		b.opened = now
	}
}

// flushDue sends the batch once it is every old, or once it is full and the
// last batch went out every ago.
func (b *batcher) flushDue() {
	now := b.now()
	if (len(b.lines) > 0 || b.dropped > 0) && (now.Sub(b.opened) >= b.every || b.full() && now.Sub(b.sent) >= b.every) {
		b.flush(false)
	}
}

// full says the next line might not fit in the batch.
func (b *batcher) full() bool {
	return len(b.lines) >= maxBatchLines || b.size+maxLineBytes+len("…") > maxBatchBytes
}

// held says the batch is full and may not go out yet: the caller waits (for
// wait at most) before adding another line.
func (b *batcher) held() bool { return b.full() && b.now().Sub(b.sent) < b.every }

func (b *batcher) wait() time.Duration { return max(b.every-b.now().Sub(b.sent), 0) }

// skip counts a line the caller dropped because the batch was held. It is
// reported in the next batch's dropped, as the budget's drops are.
func (b *batcher) skip() {
	b.dropped++
	b.touch(b.now())
}

// finish sends what is left with ended set: Docker closed the stream.
func (b *batcher) finish() { b.flush(true) }

// flush sends the batch. An empty one is sent only if it carries dropped or
// ended.
func (b *batcher) flush(ended bool) {
	if !ended && len(b.lines) == 0 && b.dropped == 0 {
		return
	}
	batch := logBatch{Action: "logs", Container: b.container, Backlog: b.backlog, Lines: b.lines, Dropped: b.dropped, Ended: ended}
	if batch.Lines == nil {
		batch.Lines = []logLine{}
	}
	b.lines, b.size, b.dropped, b.opened, b.sent = nil, 0, 0, time.Time{}, b.now()
	b.emit(batch)
}
