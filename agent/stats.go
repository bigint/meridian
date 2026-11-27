package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/url"
	"strings"
	"time"
)

// maxStatsSample bounds how much of the stream is buffered while decoding one
// sample. A real sample is a few KiB.
const maxStatsSample = 1 << 20

var errSampleTooLarge = errors.New("stats sample too large")

// dockerStats decodes the fields the live frame needs from one sample of
// GET /containers/{id}/stats. Both cgroup flavours are covered: v2 reports
// memory_stats.stats.inactive_file, v1 total_inactive_file.
type dockerStats struct {
	Read     time.Time `json:"read"`
	CPUStats struct {
		CPUUsage struct {
			TotalUsage uint64 `json:"total_usage"`
		} `json:"cpu_usage"`
	} `json:"cpu_stats"`
	MemoryStats struct {
		Usage uint64 `json:"usage"`
		Limit uint64 `json:"limit"`
		Stats struct {
			InactiveFile      *uint64 `json:"inactive_file"`
			TotalInactiveFile *uint64 `json:"total_inactive_file"`
		} `json:"stats"`
	} `json:"memory_stats"`
	Networks map[string]struct {
		RxBytes uint64 `json:"rx_bytes"`
		TxBytes uint64 `json:"tx_bytes"`
	} `json:"networks"`
	BlkioStats struct {
		IOServiceBytesRecursive []struct {
			Op    string `json:"op"`
			Value uint64 `json:"value"`
		} `json:"io_service_bytes_recursive"`
	} `json:"blkio_stats"`
}

// counters is one sample reduced to what a frame reports: gauges as they are,
// cumulative totals that become rates once two samples are compared.
type counters struct {
	at        time.Time
	cpuNS     uint64
	memUsed   uint64
	memLimit  uint64
	netRx     uint64
	netTx     uint64
	diskRead  uint64
	diskWrite uint64
}

func (d *dockerStats) counters() counters {
	c := counters{
		at:       d.Read,
		cpuNS:    d.CPUStats.CPUUsage.TotalUsage,
		memUsed:  d.MemoryStats.Usage,
		memLimit: d.MemoryStats.Limit,
	}
	// What the docker CLI does: page cache the kernel can drop is not "used".
	inactive := d.MemoryStats.Stats.TotalInactiveFile
	if inactive == nil {
		inactive = d.MemoryStats.Stats.InactiveFile
	}
	if inactive != nil && *inactive < c.memUsed {
		c.memUsed -= *inactive
	}
	for _, n := range d.Networks {
		c.netRx += n.RxBytes
		c.netTx += n.TxBytes
	}
	for _, e := range d.BlkioStats.IOServiceBytesRecursive {
		switch {
		case strings.EqualFold(e.Op, "read"):
			c.diskRead += e.Value
		case strings.EqualFold(e.Op, "write"):
			c.diskWrite += e.Value
		}
	}
	return c
}

// containerFrame is one container's entry in a stats frame.
type containerFrame struct {
	ID          string  `json:"id"`
	CPUCores    float64 `json:"cpu_cores"`
	MemoryUsed  uint64  `json:"memory_used"`
	MemoryLimit uint64  `json:"memory_limit"`
	NetRx       float64 `json:"net_rx"`
	NetTx       float64 `json:"net_tx"`
	DiskRead    float64 `json:"disk_read"`
	DiskWrite   float64 `json:"disk_write"`
}

// frameBetween turns two consecutive samples into rates. It reports false
// when the samples are not in time order, because there is no interval.
func frameBetween(id string, prev, cur counters) (containerFrame, bool) {
	seconds := cur.at.Sub(prev.at).Seconds()
	if seconds <= 0 {
		return containerFrame{}, false
	}
	rate := func(cur, prev uint64) float64 {
		if cur < prev { // counter reset, e.g. the container restarted
			return 0
		}
		return float64(cur-prev) / seconds
	}
	return containerFrame{
		ID:          id,
		CPUCores:    roundTo(rate(cur.cpuNS, prev.cpuNS)/1e9, 3),
		MemoryUsed:  cur.memUsed,
		MemoryLimit: cur.memLimit,
		NetRx:       roundTo(rate(cur.netRx, prev.netRx), 1),
		NetTx:       roundTo(rate(cur.netTx, prev.netTx), 1),
		DiskRead:    roundTo(rate(cur.diskRead, prev.diskRead), 1),
		DiskWrite:   roundTo(rate(cur.diskWrite, prev.diskWrite), 1),
	}, true
}

func roundTo(v float64, places int) float64 {
	scale := math.Pow10(places)
	return math.Round(v*scale) / scale
}

// streamStats reads GET /containers/{id}/stats?stream=true and calls fn for
// every sample until ctx ends or the stream does. A stream that ends because
// the container stopped returns nil.
func (c *dockerClient) streamStats(ctx context.Context, id string, fn func(counters)) error {
	path := "/containers/" + url.PathEscape(id) + "/stats?stream=true"
	resp, err := c.open(ctx, c.stream, path)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	budget := &budgetReader{r: resp.Body, left: maxStatsSample}
	dec := json.NewDecoder(budget)
	for {
		var sample dockerStats
		if err := dec.Decode(&sample); err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if errors.Is(err, io.EOF) {
				return nil
			}
			return fmt.Errorf("GET %s: decode: %w", path, err)
		}
		budget.left = maxStatsSample
		if sample.Read.IsZero() { // a stopped container's final, empty sample
			continue
		}
		fn(sample.counters())
	}
}

// budgetReader fails once more than left bytes are read without the caller
// topping the budget up, so one runaway JSON value cannot grow without bound.
type budgetReader struct {
	r    io.Reader
	left int
}

func (b *budgetReader) Read(p []byte) (int, error) {
	if b.left <= 0 {
		return 0, errSampleTooLarge
	}
	if len(p) > b.left {
		p = p[:b.left]
	}
	n, err := b.r.Read(p)
	b.left -= n
	return n, err
}
