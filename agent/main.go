// Command meridian-agent is a read-only observer that runs on each Kamal host.
// It lists the host's Kamal containers through the Docker API and POSTs a
// snapshot of them to Meridian on a jittered interval. While someone has the
// server's page open in Meridian it also streams live CPU, memory and network
// stats over an outbound WebSocket, and with MERIDIAN_LOGS on, the logs of the
// Kamal containers someone is reading.
package main

import (
	"context"
	"flag"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// version is set at build time with -ldflags "-X main.version=...".
var version = "dev"

const (
	maxPayload  = 1 << 20 // bytes; larger snapshots drop containers
	maxBackoff  = 5 * time.Minute
	tickTimeout = 30 * time.Second
	postTimeout = 15 * time.Second
	postPath    = "/agent/snapshots"
)

func main() {
	printOnly := flag.Bool("print", false, "collect one snapshot, print it to stdout and exit without posting")
	flag.Parse()

	logger := slog.New(slog.NewJSONHandler(os.Stderr, nil))

	cfg, err := loadConfig(os.Getenv, os.ReadFile, !*printOnly)
	if err != nil {
		logger.Error("invalid configuration", "error", err)
		os.Exit(2)
	}
	docker, err := newDockerClient(cfg.dockerHost)
	if err != nil {
		logger.Error("invalid DOCKER_HOST", "error", err)
		os.Exit(2)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	a := &agent{
		cfg:    cfg,
		docker: docker,
		http:   &http.Client{Timeout: postTimeout},
		log:    logger,
		rand:   rand.Float64,
	}

	if *printOnly {
		body, err := a.snapshotBody(ctx)
		if err != nil {
			logger.Error("snapshot failed", "error", err)
			os.Exit(1)
		}
		os.Stdout.Write(append(body, '\n'))
		return
	}

	logger.Info("meridian agent starting",
		"version", version, "url", cfg.url, "interval", cfg.interval.String(),
		"machine_id", cfg.machineID, "hostname", cfg.hostname, "live", cfg.live, "logs", cfg.logs)
	if plainHTTP(cfg.url) {
		logger.Warn("MERIDIAN_URL is plain http: the token and every report cross the network unencrypted. Use https://, or keep Meridian on a network you trust, such as a VPN or tailnet",
			"url", cfg.url)
	}
	liveDone := a.startLive(ctx)
	a.run(ctx)
	select { // let the live line say goodbye, but never hold up shutdown
	case <-liveDone:
	case <-time.After(2 * time.Second):
	}
	logger.Info("meridian agent stopped")
}
