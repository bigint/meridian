# meridian-agent

A small, read-only observer for Kamal hosts. It runs on each server as a Kamal
accessory, lists the host's Kamal containers through the Docker API, and POSTs
a snapshot of them to Meridian every 15 seconds or so. It never starts, stops or
changes anything, and it is built from the Go standard library alone.

## What it reads

- **Docker**: only `GET /containers/json?all=1` and `GET /containers/{id}/json`.
- **kamal-proxy state** (optional): the `kamal-proxy.state` file in the
  `kamal-proxy-config` volume, mounted read-only.
- **Host identity**: `/host/etc/machine-id` and `/host/etc/hostname` if mounted.

Containers are recognised the way Kamal names them (kamal v2.12.0):

| kind        | how it is recognised                              | `version`                                         |
|-------------|---------------------------------------------------|---------------------------------------------------|
| `app`       | `service` and `role` labels (plus `destination`)  | name minus `<service>-<role>[-<destination>]-`    |
| `accessory` | `service` label only (`<service>-<accessory>`)    | `""`                                              |
| `proxy`     | container named `kamal-proxy`                     | `""`                                              |

Every other container is ignored and never inspected.

**The agent never sends environment variables, commands, entrypoints, mounts
or binds.** It decodes only the fields in the snapshot below and
discards the rest of Docker's response while parsing it. A test checks this
against fixtures full of secrets.

## Snapshot

`POST $MERIDIAN_URL/agent/snapshots` with `Authorization: Bearer $MERIDIAN_TOKEN`
and `Content-Type: application/json`:

```json
{
  "agent_version": "1.0.0",
  "machine_id": "0123456789abcdef0123456789abcdef",
  "hostname": "app-1",
  "labels": { "region": "sgp", "provider": "ovh" },
  "containers": [
    {
      "id": "a1a1…",
      "name": "web-web-production-3f2a9c1e…",
      "image": "registry.example.com/acme/web:3f2a9c1e…",
      "service": "web",
      "role": "web",
      "destination": "production",
      "version": "3f2a9c1e…",
      "kind": "app",
      "state": "running",
      "health": "healthy",
      "started_at": "2026-11-25T10:00:00.123456789Z"
    }
  ],
  "proxy_routes": [
    { "name": "web-web-production", "hosts": ["app.example.com"], "active_targets": ["web-web-production-3f2a9c1e…:80"] }
  ],
  "truncated": true
}
```

- Every container key is always present. Unknown values are `""`. `health` is
  `""` when the container has no healthcheck, and `started_at` is `""` for a
  container that never started.
- `containers` is sorted by name and includes stopped containers, because Kamal
  keeps old versions around.
- `proxy_routes` is left out when `MERIDIAN_PROXY_STATE` is unset or the file
  cannot be read. A catch-all host appears as `"*"`.
- `truncated` appears only when the snapshot went over 1 MiB and containers
  (then proxy routes) were dropped from the end to fit.
- Any 2xx response counts as delivered.

## Configuration

| variable              | default                        | meaning |
|-----------------------|--------------------------------|---------|
| `MERIDIAN_URL`         | required                       | Meridian base URL, e.g. `https://meridian.example.com` |
| `MERIDIAN_TOKEN`       | required                       | bearer token for this agent |
| `DOCKER_HOST`         | `unix:///var/run/docker.sock`  | `unix://…` or `tcp://host:port` (a socket proxy) |
| `MERIDIAN_INTERVAL`    | `15s`                          | Go duration or bare seconds, at least `1s`. ±20% jitter is applied |
| `MERIDIAN_LABELS`      | none                           | `region=sgp,provider=ovh` |
| `MERIDIAN_MACHINE_ID`  | `/host/etc/machine-id`, then `/etc/machine-id` | stable host id. Required one way or another |
| `MERIDIAN_HOSTNAME`    | `/host/etc/hostname`, then the container hostname | reported hostname |
| `MERIDIAN_PROXY_STATE` | unset                          | path to the mounted `kamal-proxy.state` |

The first snapshot is sent at startup. After a failure the delay doubles on
each consecutive failure, up to 5 minutes, and it returns to the normal
interval after the next success. Docker calls time out after 10s, the POST
after 15s, and a whole cycle after 30s. SIGTERM stops the agent cleanly, and an
in-flight POST is cancelled.

To print one snapshot to stdout without posting it, run `meridian-agent -print`.
This needs no URL or token.

## Deploying with a read-only socket proxy

Mounting `/var/run/docker.sock:ro` does **not** make the Docker API read-only.
`:ro` only stops writes to the socket file itself, and anyone who can connect to
the socket can still create containers. Put a filtering proxy in front of it and
give the agent only the proxy:

```yaml
# config/deploy.yml
accessories:
  docker-proxy:
    image: tecnativa/docker-socket-proxy   # pin a version or digest
    roles: [web]
    env:
      clear:
        CONTAINERS: 1   # allow GET /containers/*
        POST: 0         # deny every non-GET request
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro

  agent:
    image: ghcr.io/example/meridian-agent   # your build of agent/Dockerfile
    roles: [web]
    env:
      clear:
        MERIDIAN_URL: https://meridian.example.com
        DOCKER_HOST: tcp://<service>-docker-proxy:2375
        MERIDIAN_LABELS: region=sgp,provider=ovh
        MERIDIAN_PROXY_STATE: /kamal-proxy/kamal-proxy.state
      secret:
        - MERIDIAN_TOKEN
    volumes:
      - /etc/machine-id:/host/etc/machine-id:ro
      - /etc/hostname:/host/etc/hostname:ro
      - kamal-proxy-config:/kamal-proxy:ro
```

Kamal accessories join the `kamal` network, so the agent reaches the proxy by
its container name (`<service>-docker-proxy`). Do not give the proxy a `port:`.
Port 2375 must never be published on the host.

If you skip the proxy and mount the socket directly, note that the image runs
as `nonroot` (uid 65532), which cannot open a `root:docker` socket. Add the
host's docker group with `options: { group-add: "<docker gid>" }`.

kamal-proxy keeps its state directory private to its own user. If the agent
logs `permission denied` for the state file, run it as kamal-proxy's uid
(`options: { user: "<uid>" }`, which `docker exec kamal-proxy id -u` shows).
Snapshots keep flowing without `proxy_routes` in the meantime. kamal-proxy
rewrites the file in place, so a read can catch it half-written. The agent
retries once and otherwise leaves `proxy_routes` out of that snapshot.

## Development

```bash
go vet ./... && go test ./...
docker build --build-arg VERSION=$(git rev-parse --short HEAD) -t meridian-agent .
```

The image is a static `CGO_ENABLED=0` binary on
`gcr.io/distroless/static-debian12:nonroot`, about 3.5 MB.
