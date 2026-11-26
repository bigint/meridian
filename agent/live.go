package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"sync"
	"time"
)

// startLive runs the live line, the stats sampler and the log tailer beside
// the snapshot loop, which it never touches. The returned channel closes once
// all have stopped after ctx ends. With MERIDIAN_LIVE off nothing starts, and
// since container logs ride the line they are off too.
func (a *agent) startLive(ctx context.Context) <-chan struct{} {
	done := make(chan struct{})
	if !a.cfg.live {
		if a.cfg.logs {
			a.log.Warn("MERIDIAN_LOGS is on but MERIDIAN_LIVE is off: container logs ride the live line, so they are off too")
		}
		close(done)
		return done
	}
	go func() {
		defer close(done)
		defer recoverPanic(a.log, "live")
		l, err := newLine(a.cfg, a.log, a.rand)
		if err != nil {
			a.log.Error("live stats disabled", "error", err)
			return
		}
		s := newSampler(a.docker, newHostMetrics(), l.send, a.log, time.Now)
		tl := newTailer(a.docker, l.send, a.log, time.Now, a.cfg.logs, ownContainerID(os.ReadFile, os.Hostname))
		var wg sync.WaitGroup
		wg.Go(func() { l.run(ctx) })
		wg.Go(func() { tl.run(ctx, l.tails) })
		s.run(ctx, l.watches)
		wg.Wait()
	}()
	return done
}

// recoverPanic is deferred at the top of every goroutine the live path
// starts: a bug there must cost a log line, never the agent.
func recoverPanic(log *slog.Logger, what string) {
	if r := recover(); r != nil {
		log.Error("recovered from panic", "in", what, "panic", fmt.Sprint(r))
	}
}
