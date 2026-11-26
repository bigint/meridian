package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"sort"
	"strings"
)

const (
	kindApp       = "app"
	kindAccessory = "accessory"
	kindProxy     = "proxy"

	proxyContainerName = "kamal-proxy"
)

// Snapshot is the JSON document POSTed to Meridian.
type Snapshot struct {
	AgentVersion string            `json:"agent_version"`
	MachineID    string            `json:"machine_id"`
	Hostname     string            `json:"hostname"`
	Labels       map[string]string `json:"labels"`
	Containers   []Container       `json:"containers"`
	Truncated    bool              `json:"truncated,omitempty"`
}

type Container struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Image       string `json:"image"`
	Service     string `json:"service"`
	Role        string `json:"role"`
	Destination string `json:"destination"`
	Version     string `json:"version"`
	Kind        string `json:"kind"`
	State       string `json:"state"`
	Health      string `json:"health"`
	StartedAt   string `json:"started_at"`
}

// classify decides whether a container is Kamal's and fills in the fields
// derived from its name and labels.
//
// App containers carry service, role and destination labels and are named
// "<service>-<role>[-<destination>]-<version>" (kamal v2.12.0,
// lib/kamal/configuration/role.rb and commands/app.rb). Accessories carry only
// a service label ("<service>-<accessory>"). kamal-proxy is recognised by name.
func classify(name string, labels map[string]string) (Container, bool) {
	service, role, destination := labels["service"], labels["role"], labels["destination"]
	c := Container{Name: name, Service: service, Role: role, Destination: destination}
	switch {
	case service != "" && role != "":
		c.Kind = kindApp
		parts := []string{service, role}
		if destination != "" {
			parts = append(parts, destination)
		}
		if prefix := strings.Join(parts, "-") + "-"; strings.HasPrefix(name, prefix) {
			c.Version = strings.TrimPrefix(name, prefix)
		}
	case name == proxyContainerName:
		c.Kind = kindProxy
	case service != "":
		c.Kind = kindAccessory
	default:
		return Container{}, false
	}
	return c, true
}

func containerName(names []string) string {
	if len(names) == 0 {
		return ""
	}
	return strings.TrimPrefix(names[0], "/")
}

// collectContainers lists every container, keeps Kamal's, and inspects each
// one for state, health and start time.
func collectContainers(ctx context.Context, docker *dockerClient) ([]Container, error) {
	listed, err := docker.listContainers(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]Container, 0, len(listed))
	for _, l := range listed {
		if _, ok := classify(containerName(l.Names), l.Labels); !ok {
			continue
		}
		in, err := docker.inspectContainer(ctx, l.ID)
		if errors.Is(err, errNotFound) {
			continue // removed between list and inspect
		}
		if err != nil {
			return nil, err
		}
		c, ok := classify(strings.TrimPrefix(in.Name, "/"), in.Config.Labels)
		if !ok {
			continue
		}
		c.ID = in.ID
		c.Image = in.Config.Image
		if c.Image == "" {
			c.Image = l.Image
		}
		c.State = in.State.Status
		if in.State.Health != nil {
			c.Health = in.State.Health.Status
		}
		if !strings.HasPrefix(in.State.StartedAt, "0001-01-01") {
			c.StartedAt = in.State.StartedAt
		}
		out = append(out, c)
	}
	slices.SortFunc(out, func(a, b Container) int { return strings.Compare(a.Name, b.Name) })
	return out, nil
}

// encodeCapped marshals s, dropping trailing containers until the document
// fits in limit bytes.
func encodeCapped(s Snapshot, limit int) ([]byte, bool, error) {
	if s.Labels == nil {
		s.Labels = map[string]string{}
	}
	if s.Containers == nil {
		s.Containers = []Container{}
	}
	body, err := json.Marshal(s)
	if err != nil || len(body) <= limit {
		return body, false, err
	}

	all := s.Containers
	s.Truncated = true
	encode := func(n int) ([]byte, bool) {
		s.Containers = all[:n]
		b, err := json.Marshal(s)
		return b, err == nil && len(b) <= limit
	}
	// Smallest n that does not fit; n-1 is the most that does.
	n := sort.Search(len(all)+1, func(n int) bool { _, ok := encode(n); return !ok })
	if n > 0 {
		b, _ := encode(n - 1)
		return b, true, nil
	}
	return nil, true, fmt.Errorf("snapshot exceeds %d bytes even without containers", limit)
}
