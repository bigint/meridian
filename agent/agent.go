package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
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
		if err := a.tick(ctx); err != nil {
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

		timer := time.NewTimer(nextDelay(a.cfg.interval, failures, a.rand()))
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
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
	snap := Snapshot{
		AgentVersion: version,
		MachineID:    a.cfg.machineID,
		Hostname:     a.cfg.hostname,
		Labels:       a.cfg.labels,
		Containers:   containers,
	}
	if a.cfg.proxyState != "" {
		routes, err := readProxyRoutes(a.cfg.proxyState)
		if err != nil {
			a.log.Warn("kamal-proxy state unreadable; omitting proxy_routes", "error", err)
		} else {
			snap.ProxyRoutes = routes
		}
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
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return fmt.Errorf("post snapshot: unexpected status %s", resp.Status)
	}
	return nil
}

// nextDelay is interval doubled per consecutive failure (capped at
// maxBackoff), scaled by a jitter factor in [0.8, 1.2) from r in [0, 1).
func nextDelay(interval time.Duration, failures int, r float64) time.Duration {
	d := interval
	for i := 0; i < failures && d < maxBackoff; i++ {
		d *= 2
	}
	d = time.Duration(float64(d) * (0.8 + 0.4*r))
	if failures > 0 && d > maxBackoff {
		d = maxBackoff
	}
	return d
}
