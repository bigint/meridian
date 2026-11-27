package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	dockerTimeout     = 10 * time.Second
	maxDockerResponse = 16 << 20
)

var errNotFound = errors.New("not found")

// dockerClient speaks to the Docker Engine API. It only ever issues GETs.
type dockerClient struct {
	http *http.Client // bounded by dockerTimeout, for one-shot calls
	// stream has no overall Timeout, which would cut a long-lived response
	// off. Only the time to the response headers is bounded.
	stream *http.Client
	base   string
}

func newDockerClient(host string) (*dockerClient, error) {
	if host == "" {
		host = "unix:///var/run/docker.sock"
	}
	var transport *http.Transport
	base := "http://docker"
	switch {
	case strings.HasPrefix(host, "unix://"):
		path := strings.TrimPrefix(host, "unix://")
		transport = &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", path)
			},
		}
	case strings.HasPrefix(host, "tcp://"), strings.HasPrefix(host, "http://"):
		u, err := url.Parse(host)
		if err != nil || u.Host == "" {
			return nil, fmt.Errorf("cannot parse %q", host)
		}
		transport = http.DefaultTransport.(*http.Transport).Clone()
		// Never through HTTP_PROXY: inspect responses carry every container's
		// environment, and the socket proxy is a neighbour, not the internet.
		transport.Proxy = nil
		base = "http://" + u.Host
	default:
		return nil, fmt.Errorf("unsupported scheme in %q (want unix:// or tcp://)", host)
	}
	transport.ResponseHeaderTimeout = dockerTimeout
	return &dockerClient{
		http:   &http.Client{Transport: transport, Timeout: dockerTimeout},
		stream: &http.Client{Transport: transport},
		base:   base,
	}, nil
}

// open sends GET path with client and returns the response, whose body the
// caller closes. Any status but 200 is an error: errNotFound for a 404.
func (c *dockerClient) open(ctx context.Context, client *http.Client, path string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.base+path, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("GET %s: %w", path, err)
	}
	if resp.StatusCode == http.StatusOK {
		return resp, nil
	}
	io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, fmt.Errorf("GET %s: %w", path, errNotFound)
	}
	return nil, fmt.Errorf("GET %s: unexpected status %s", path, resp.Status)
}

// get decodes the JSON answer to GET path into v.
func (c *dockerClient) get(ctx context.Context, path string, v any) error {
	resp, err := c.open(ctx, c.http, path)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxDockerResponse)).Decode(v); err != nil {
		return fmt.Errorf("GET %s: decode: %w", path, err)
	}
	return nil
}

// The structs below decode only the fields the agent reports. Env, Cmd,
// Mounts and everything else in Docker's response are never read.

type listedContainer struct {
	ID     string            `json:"Id"`
	Names  []string          `json:"Names"`
	Labels map[string]string `json:"Labels"`
	State  string            `json:"State"`
}

type inspectedContainer struct {
	ID     string `json:"Id"`
	Name   string `json:"Name"`
	Config struct {
		Image  string            `json:"Image"`
		Labels map[string]string `json:"Labels"`
		Tty    bool              `json:"Tty"` // the log stream is raw, not multiplexed
	} `json:"Config"`
	State struct {
		Status    string `json:"Status"`
		StartedAt string `json:"StartedAt"`
		Health    *struct {
			Status string `json:"Status"`
		} `json:"Health"`
	} `json:"State"`
}

func (c *dockerClient) listContainers(ctx context.Context) ([]listedContainer, error) {
	var out []listedContainer
	err := c.get(ctx, "/containers/json?all=1", &out)
	return out, err
}

func (c *dockerClient) inspectContainer(ctx context.Context, id string) (inspectedContainer, error) {
	var out inspectedContainer
	err := c.get(ctx, "/containers/"+url.PathEscape(id)+"/json", &out)
	return out, err
}
