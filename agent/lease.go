package main

import "time"

// maxLease caps how far one watch message can extend the lease.
const maxLease = 120 * time.Second

// lease says whether anyone is watching. Meridian extends it with relative
// seconds, so the two hosts' clocks never meet. It is not safe for concurrent
// use: the sampler's loop is its only owner.
type lease struct {
	now   func() time.Time
	until time.Time // live_until
}

// watch applies {"type":"watch","seconds":n}:
// live_until = max(live_until, now + min(n, 120 s)).
func (l *lease) watch(seconds int) {
	d := time.Duration(min(max(seconds, 0), int(maxLease/time.Second))) * time.Second // clamp both ends first: no overflow
	if until := l.now().Add(d); until.After(l.until) {
		l.until = until
	}
}

func (l *lease) live() bool { return l.now().Before(l.until) }
