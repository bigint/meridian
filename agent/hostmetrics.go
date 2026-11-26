package main

import (
	"fmt"
	"math"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	hostProc     = "/host/proc"
	hostDiskPath = "/host/etc/hostname"
	maxProcFile  = 1 << 20
)

// hostFrame is the "host" object of a stats frame.
type hostFrame struct {
	CPUCores    float64 `json:"cpu_cores"`
	Cores       int     `json:"cores"`
	MemoryUsed  uint64  `json:"memory_used"`
	MemoryTotal uint64  `json:"memory_total"`
	Load1       float64 `json:"load1"`
	DiskUsed    *uint64 `json:"disk_used,omitempty"`
	DiskTotal   *uint64 `json:"disk_total,omitempty"`
}

// hostMetrics reads the host's /proc, mounted into the agent at hostProc.
// CPU is a rate, so it remembers the previous /proc/stat reading. It is used
// by one goroutine.
type hostMetrics struct {
	proc     string
	diskPath string
	statfs   func(path string) (total, used uint64, err error)

	prev    cpuTimes
	hasPrev bool
}

func newHostMetrics() *hostMetrics {
	return &hostMetrics{proc: hostProc, diskPath: hostDiskPath, statfs: statfsUsage}
}

// cpuTimes is the aggregate "cpu" line of /proc/stat in clock ticks.
type cpuTimes struct{ busy, total uint64 }

// reset takes the baseline the next sample's CPU rate is measured from.
func (h *hostMetrics) reset() {
	t, _, err := h.readStat()
	h.prev, h.hasPrev = t, err == nil
}

// sample reports the host, or false when /proc is not mounted or unreadable.
// It also reports false for the one sample that has no baseline yet.
func (h *hostMetrics) sample() (hostFrame, bool) {
	cur, cores, err := h.readStat()
	if err != nil {
		h.hasPrev = false
		return hostFrame{}, false
	}
	prev, hadPrev := h.prev, h.hasPrev
	h.prev, h.hasPrev = cur, true
	if !hadPrev {
		return hostFrame{}, false
	}
	memUsed, memTotal, err := h.readMemory()
	if err != nil {
		return hostFrame{}, false
	}
	load1, err := h.readLoad1()
	if err != nil {
		return hostFrame{}, false
	}

	f := hostFrame{Cores: cores, MemoryUsed: memUsed, MemoryTotal: memTotal, Load1: load1}
	if cur.total > prev.total && cur.busy >= prev.busy {
		busyShare := float64(cur.busy-prev.busy) / float64(cur.total-prev.total)
		f.CPUCores = roundTo(busyShare*float64(cores), 3)
	}
	if total, used, err := h.statfs(h.diskPath); err == nil {
		f.DiskTotal, f.DiskUsed = &total, &used
	}
	return f, true
}

func (h *hostMetrics) readStat() (cpuTimes, int, error) {
	data, err := readLimited(filepath.Join(h.proc, "stat"), maxProcFile)
	if err != nil {
		return cpuTimes{}, 0, err
	}
	return parseProcStat(string(data))
}

// parseProcStat reads the aggregate cpu line (user nice system idle iowait
// irq softirq steal: guest time is already inside user) and counts the cpuN
// lines.
func parseProcStat(data string) (t cpuTimes, cores int, err error) {
	var found bool
	for line := range strings.Lines(data) {
		fields := strings.Fields(line)
		if len(fields) == 0 || !strings.HasPrefix(fields[0], "cpu") {
			continue
		}
		if fields[0] != "cpu" {
			if _, err := strconv.Atoi(fields[0][3:]); err == nil {
				cores++
			}
			continue
		}
		var idle uint64
		for i, f := range fields[1:min(len(fields), 9)] {
			v, err := strconv.ParseUint(f, 10, 64)
			if err != nil {
				return cpuTimes{}, 0, fmt.Errorf("stat: %w", err)
			}
			t.total += v
			if i == 3 || i == 4 { // idle, iowait
				idle += v
			}
		}
		t.busy = t.total - idle
		found = true
	}
	if !found || cores == 0 {
		return cpuTimes{}, 0, fmt.Errorf("stat: no cpu lines")
	}
	return t, cores, nil
}

func (h *hostMetrics) readMemory() (used, total uint64, err error) {
	data, err := readLimited(filepath.Join(h.proc, "meminfo"), maxProcFile)
	if err != nil {
		return 0, 0, err
	}
	return parseMeminfo(string(data))
}

// parseMeminfo returns MemTotal-MemAvailable and MemTotal, in bytes.
func parseMeminfo(data string) (used, total uint64, err error) {
	var avail uint64
	var haveTotal, haveAvail bool
	for line := range strings.Lines(data) {
		name, rest, ok := strings.Cut(line, ":")
		if !ok || (name != "MemTotal" && name != "MemAvailable") {
			continue
		}
		fields := strings.Fields(rest)
		if len(fields) == 0 {
			continue
		}
		kb, err := strconv.ParseUint(fields[0], 10, 64)
		if err != nil {
			return 0, 0, fmt.Errorf("meminfo %s: %w", name, err)
		}
		if name == "MemTotal" {
			total, haveTotal = kb*1024, true
		} else {
			avail, haveAvail = kb*1024, true
		}
	}
	if !haveTotal || !haveAvail || avail > total {
		return 0, 0, fmt.Errorf("meminfo: MemTotal/MemAvailable missing or inconsistent")
	}
	return total - avail, total, nil
}

func (h *hostMetrics) readLoad1() (float64, error) {
	data, err := readLimited(filepath.Join(h.proc, "loadavg"), maxProcFile)
	if err != nil {
		return 0, err
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return 0, fmt.Errorf("loadavg: empty")
	}
	v, err := strconv.ParseFloat(fields[0], 64)
	if err != nil || !(v >= 0) || math.IsInf(v, 0) { // also rejects NaN, which JSON cannot carry
		return 0, fmt.Errorf("loadavg: bad value %q", fields[0])
	}
	return v, nil
}
