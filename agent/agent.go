package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"time"
)

type agent struct {
	cfg    config
	docker *dockerClient
	http   *http.Client
	log    *slog.Logger
	rand   func() float64 // in [0, 1)
}

// run sends a snapshot immediately, then once per jittered interval, backing
// off exponentially while sends fail. It returns when ctx is cancelled.
func (a *agent) run(ctx context.Context) {
	failures := 0
	for {
		err := a.tick(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			failures++
			a.log.Warn("snapshot failed", "error", err, "consecutive_failures", failures)
		} else {
			if failures > 0 {
				a.log.Info("snapshot delivered", "after_failures", failures)
			}
			failures = 0
		}

		timer := time.NewTimer(a.delayAfter(err, failures))
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}

// delayAfter is how long to wait before the next snapshot: the jittered
// interval, doubled per failure, and after a 429 never sooner than Meridian's
// Retry-After (jittered up to 20% later, so a fleet told the same wait does
// not come back at once).
func (a *agent) delayAfter(err error, failures int) time.Duration {
	delay := nextDelay(a.cfg.interval, failures, a.rand())
	var busy *retryAfterError
	if errors.As(err, &busy) {
		delay = max(delay, min(time.Duration(float64(busy.after)*(1+0.2*a.rand())), maxBackoff))
	}
	return delay
}

func (a *agent) tick(parent context.Context) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("recovered from panic: %v", r)
		}
	}()
	ctx, cancel := context.WithTimeout(parent, tickTimeout)
	defer cancel()

	body, err := a.snapshotBody(ctx)
	if err != nil {
		return err
	}
	return postSnapshot(ctx, a.http, a.cfg.url+postPath, a.cfg.token, body)
}

func (a *agent) snapshotBody(ctx context.Context) ([]byte, error) {
	containers, err := collectContainers(ctx, a.docker)
	if err != nil {
		return nil, fmt.Errorf("docker: %w", err)
	}
	snap := snapshot{
		AgentVersion:    version,
		MachineID:       a.cfg.machineID,
		Hostname:        a.cfg.hostname,
		IntervalSeconds: intervalSeconds(a.cfg.interval),
		Labels:          a.cfg.labels,
		Containers:      containers,
	}
	body, truncated, err := encodeCapped(snap, maxPayload)
	if err != nil {
		return nil, err
	}
	if truncated {
		a.log.Warn("snapshot truncated to fit payload cap", "limit_bytes", maxPayload, "containers_total", len(containers))
	}
	return body, nil
}

// newSnapshotClient bounds the whole POST. Like the live line's client, it
// does not follow redirects: net/http would resend the Authorization header
// to the same host over plain http, and turn the POST into a GET on a 301 or
// 302. A redirect is reported as the unexpected status it is.
func newSnapshotClient() *http.Client {
	return &http.Client{
		Timeout:       postTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

func postSnapshot(ctx context.Context, client *http.Client, endpoint, token string, body []byte) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "meridian-agent/"+version)
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("post snapshot: %w", err)
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	if resp.StatusCode == http.StatusTooManyRequests {
		return &retryAfterError{status: resp.Status, after: parseRetryAfter(resp.Header.Get("Retry-After"), time.Now())}
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return fmt.Errorf("post snapshot: unexpected status %s", resp.Status)
	}
	return nil
}

// retryAfterError is a 429, with how long Meridian asked the agent to wait
// (0 when it did not say).
type retryAfterError struct {
	status string
	after  time.Duration
}

func (e *retryAfterError) Error() string {
	return fmt.Sprintf("post snapshot: unexpected status %s (retry after %s)", e.status, e.after)
}

// parseRetryAfter reads a Retry-After header: delay-seconds or an HTTP date.
// Anything else, or a time already past, is 0.
func parseRetryAfter(v string, now time.Time) time.Duration {
	if secs, err := strconv.Atoi(v); err == nil {
		return time.Duration(min(max(secs, 0), int(maxBackoff/time.Second))) * time.Second
	}
	if at, err := http.ParseTime(v); err == nil && at.After(now) {
		return min(at.Sub(now), maxBackoff)
	}
	return 0
}

// intervalSeconds is the snapshot interval as Meridian is told it: whole
// seconds, at least 1.
func intervalSeconds(d time.Duration) int {
	return max(int(d.Round(time.Second)/time.Second), 1)
}

// nextDelay is interval doubled per consecutive failure, jittered by ±20%
// from r in [0, 1). After a failure it is never more than maxBackoff; with
// none it is the interval as configured, however long.
func nextDelay(interval time.Duration, failures int, r float64) time.Duration {
	if failures == 0 {
		return jittered(interval, r)
	}
	return min(jittered(doubled(interval, maxBackoff, failures), r), maxBackoff)
}

// doubled is d doubled n times, but no more than ceiling. Both backoffs use
// it: the snapshot loop's and the live line's.
func doubled(d, ceiling time.Duration, n int) time.Duration {
	for i := 0; i < n && d < ceiling; i++ {
		d *= 2
	}
	return min(d, ceiling)
}

// jittered scales d by a factor in [0.8, 1.2) from r in [0, 1).
func jittered(d time.Duration, r float64) time.Duration {
	return time.Duration(float64(d) * (0.8 + 0.4*r))
}
