package main

import "time"

const (
	batchEvery    = 250 * time.Millisecond // a batch goes out at most this long after its first line
	maxBatchLines = 500
	maxBatchBytes = 256 << 10 // of m per batch
	budgetBytes   = 512 << 10 // of m per second for one container; the rest is dropped
	budgetWindow  = time.Second
)

// batcher groups one container's lines into the batches of the wire format:
// at most maxBatchLines and maxBatchBytes each, out at most batchEvery after
// the first line, and no more than budgetBytes of message per second. What the
// budget refuses is counted and reported in the next batch's dropped. Lines
// from history (the backlog) and live lines never share a batch.
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
	if b.used+len(l.M) > budgetBytes {
		b.dropped++
		b.touch(now)
		return
	}
	if len(b.lines) >= maxBatchLines || b.size+len(l.M) > maxBatchBytes {
		b.flush(false)
	}
	b.touch(now)
	b.used += len(l.M)
	b.size += len(l.M)
	b.lines = append(b.lines, l)
}

func (b *batcher) touch(now time.Time) {
	if b.opened.IsZero() {
		b.opened = now
	}
}

// flushDue sends the batch once it is batchEvery old.
func (b *batcher) flushDue() {
	if (len(b.lines) > 0 || b.dropped > 0) && b.now().Sub(b.opened) >= b.every {
		b.flush(false)
	}
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
	b.lines, b.size, b.dropped, b.opened = nil, 0, 0, time.Time{}
	b.emit(batch)
}
