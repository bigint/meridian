package main

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const defaultInterval = 15 * time.Second

type config struct {
	url        string // Meridian base URL, no trailing slash
	token      string
	dockerHost string
	interval   time.Duration
	labels     map[string]string
	machineID  string
	hostname   string
	proxyState string
}

// Host files are preferred over the container's own: inside the agent
// container /etc/machine-id and the hostname belong to the container.
var (
	machineIDPaths = []string{"/host/etc/machine-id", "/etc/machine-id"}
	hostnamePaths  = []string{"/host/etc/hostname"}
)

func loadConfig(getenv func(string) string, readFile func(string) ([]byte, error), requireServer bool) (config, error) {
	cfg := config{
		token:      strings.TrimSpace(getenv("MERIDIAN_TOKEN")),
		dockerHost: getenv("DOCKER_HOST"),
		proxyState: getenv("MERIDIAN_PROXY_STATE"),
		interval:   defaultInterval,
	}

	if raw := strings.TrimSpace(getenv("MERIDIAN_URL")); raw != "" {
		u, err := url.Parse(raw)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			return cfg, fmt.Errorf("MERIDIAN_URL must be an http(s) URL, got %q", raw)
		}
		cfg.url = strings.TrimRight(raw, "/")
	}
	if requireServer {
		if cfg.url == "" {
			return cfg, errors.New("MERIDIAN_URL is required")
		}
		if cfg.token == "" {
			return cfg, errors.New("MERIDIAN_TOKEN is required")
		}
	}

	if raw := strings.TrimSpace(getenv("MERIDIAN_INTERVAL")); raw != "" {
		d, err := parseInterval(raw)
		if err != nil {
			return cfg, err
		}
		cfg.interval = d
	}

	labels, err := parseLabels(getenv("MERIDIAN_LABELS"))
	if err != nil {
		return cfg, err
	}
	cfg.labels = labels

	cfg.machineID = strings.TrimSpace(getenv("MERIDIAN_MACHINE_ID"))
	if cfg.machineID == "" {
		cfg.machineID = firstFile(readFile, machineIDPaths)
	}
	if cfg.machineID == "" {
		return cfg, fmt.Errorf("no machine id: set MERIDIAN_MACHINE_ID or mount the host's /etc/machine-id at %s", machineIDPaths[0])
	}

	cfg.hostname = strings.TrimSpace(getenv("MERIDIAN_HOSTNAME"))
	if cfg.hostname == "" {
		cfg.hostname = firstFile(readFile, hostnamePaths)
	}
	if cfg.hostname == "" {
		cfg.hostname, _ = os.Hostname()
	}
	return cfg, nil
}

// parseInterval accepts Go durations ("30s", "1m") or bare seconds ("30").
func parseInterval(raw string) (time.Duration, error) {
	d, err := time.ParseDuration(raw)
	if err != nil {
		secs, serr := strconv.Atoi(raw)
		if serr != nil {
			return 0, fmt.Errorf("MERIDIAN_INTERVAL: %q is not a duration", raw)
		}
		d = time.Duration(secs) * time.Second
	}
	if d < time.Second {
		return 0, fmt.Errorf("MERIDIAN_INTERVAL must be at least 1s, got %s", d)
	}
	return d, nil
}

// parseLabels parses "region=sgp,provider=ovh".
func parseLabels(raw string) (map[string]string, error) {
	labels := map[string]string{}
	for part := range strings.SplitSeq(raw, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		k, v, ok := strings.Cut(part, "=")
		k = strings.TrimSpace(k)
		if !ok || k == "" {
			return nil, fmt.Errorf("MERIDIAN_LABELS: %q is not key=value", part)
		}
		labels[k] = strings.TrimSpace(v)
	}
	return labels, nil
}

func firstFile(readFile func(string) ([]byte, error), paths []string) string {
	for _, p := range paths {
		if b, err := readFile(p); err == nil {
			if s := strings.TrimSpace(string(b)); s != "" {
				return s
			}
		}
	}
	return ""
}
