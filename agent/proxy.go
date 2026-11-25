package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"time"
)

const maxProxyState = 8 << 20

// ProxyRoute is one kamal-proxy service as recorded in its state file.
type ProxyRoute struct {
	Name          string   `json:"name"`
	Hosts         []string `json:"hosts"`
	ActiveTargets []string `json:"active_targets"`
}

// kamal-proxy (v0.10.3, internal/server/service.go marshalledService) writes
// options.hosts and active_targets; older releases wrote top-level hosts and
// active_target. Both are read here.
type proxyStateService struct {
	Name    string `json:"name"`
	Options struct {
		Hosts []string `json:"hosts"`
	} `json:"options"`
	ActiveTargets      []string `json:"active_targets"`
	LegacyHosts        []string `json:"hosts"`
	LegacyActiveTarget string   `json:"active_target"`
}

// proxyRetryWait is how long to wait before re-reading a state file that did
// not parse. kamal-proxy truncates and rewrites it in place, so a read can
// land mid-write.
var proxyRetryWait = func() { time.Sleep(250 * time.Millisecond) }

func readProxyRoutes(path string) ([]ProxyRoute, error) {
	var lastErr error
	for attempt := range 2 {
		if attempt > 0 {
			proxyRetryWait()
		}
		data, err := readLimited(path, maxProxyState)
		if err != nil {
			return nil, err
		}
		routes, err := parseProxyState(data)
		if err == nil {
			return routes, nil
		}
		lastErr = err
	}
	return nil, lastErr
}

func parseProxyState(data []byte) ([]ProxyRoute, error) {
	var services []proxyStateService
	if err := json.Unmarshal(data, &services); err != nil {
		return nil, fmt.Errorf("parse kamal-proxy state: %w", err)
	}
	routes := make([]ProxyRoute, 0, len(services))
	for _, s := range services {
		hosts := s.Options.Hosts
		if len(hosts) == 0 {
			hosts = s.LegacyHosts
		}
		targets := s.ActiveTargets
		if len(targets) == 0 && s.LegacyActiveTarget != "" {
			targets = []string{s.LegacyActiveTarget}
		}
		r := ProxyRoute{Name: s.Name, Hosts: []string{}, ActiveTargets: []string{}}
		for _, h := range hosts {
			if h == "" {
				h = "*" // kamal-proxy's own rendering of the catch-all host
			}
			r.Hosts = append(r.Hosts, h)
		}
		r.ActiveTargets = append(r.ActiveTargets, targets...)
		routes = append(routes, r)
	}
	return routes, nil
}

func readLimited(path string, limit int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("%s is larger than %d bytes", path, limit)
	}
	return data, nil
}
