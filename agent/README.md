# meridian-agent

A small, read-only observer for Kamal hosts. It runs on each server as a Kamal
accessory, lists the host's Kamal containers through the Docker API, and POSTs
a snapshot of them to Meridian every 15 seconds or so. While someone has the
server's page open in Meridian it also streams live CPU, memory, network and
disk numbers once a second ([Live stats](#live-stats)). It never starts, stops
or changes anything, and it is built from the Go standard library alone.

## What it reads

- **Docker**: only `GET /containers/json?all=1` and `GET /containers/{id}/json`
  for snapshots, plus `GET /containers/{id}/stats?stream=true` while someone is
  watching ([Live stats](#live-stats)).
- **kamal-proxy state** (optional): the `kamal-proxy.state` file in the
  `kamal-proxy-config` volume, mounted read-only.
- **Host identity**: `/host/etc/machine-id` and `/host/etc/hostname` if mounted.
- **Host load** (optional, live stats only): `stat`, `meminfo` and `loadavg`
  under `/host/proc`, and the size of the filesystem holding
  `/host/etc/hostname`.

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

## Live stats

Snapshots say what is running. Live stats say how hard it is working, and they
only flow while someone is looking. The agent stays outbound-only and
read-only, and snapshots carry on exactly as before. Two independent loops
share the process: the snapshot loop above, and the line below.

**The line.** The agent opens one WebSocket to `$MERIDIAN_URL/cable` (Rails'
ActionCable mount, `https` means TLS) and keeps it open. It is a plain RFC 6455
client speaking ActionCable's `actioncable-v1-json` subprotocol. The upgrade
request carries:

- `Authorization: Bearer $MERIDIAN_TOKEN`, the same token snapshots use;
- `Origin: <scheme>://<host[:port]>` of `MERIDIAN_URL`;
- `Sec-WebSocket-Protocol: actioncable-v1-json`;
- `User-Agent: meridian-agent/<version>`.

After ActionCable's `welcome` the agent subscribes to
`{"channel":"AgentChannel","machine_id":"<machine id>"}`. ActionCable pings
every 3 seconds, and 10 seconds without any frame closes the line and
reconnects. A rejected subscription (for example the server has not had its
first snapshot yet), a dropped connection and a failed upgrade all retry after
5 seconds, doubling to 60 seconds, with ±20% jitter. A subscription that was
confirmed resets the backoff. When Meridian refuses the token (HTTP 401 or 403,
or `{"type":"disconnect","reason":"unauthorized","reconnect":false}`) the agent
logs it and waits 5 minutes. Inbound messages are capped at 1 MiB.

**Watch leases.** Meridian sends `{"type":"watch","seconds":30}` inside the
ActionCable envelope while a browser watches this server, and renews it about
every 10 seconds. The agent keeps `live_until = max(live_until, now +
min(seconds, 120))`, so the two hosts' clocks never meet. Other message types
are ignored. Nothing streams outside a lease.

**While a lease is live** the agent opens one
`GET /containers/{id}/stats?stream=true` per running Kamal container (the same
filter snapshots use, at most 500, reconciled every 5 seconds), and once a
second sends one frame as an ActionCable command:

```json
{"command":"message","identifier":"<same identifier>","data":"<the frame, as a JSON string>"}
```

When the lease lapses every stats stream is cancelled. A frame goes out only
while the line is connected and subscribed, and is dropped otherwise, never
queued. The frame:

```json
{
  "action": "stats",
  "host": {
    "cpu_cores": 0.21,
    "cores": 2,
    "memory_used": 71303168,
    "memory_total": 2147483648,
    "load1": 0.05,
    "disk_used": 9663676416,
    "disk_total": 42949672960
  },
  "containers": [
    {
      "id": "<full 64-hex container id>",
      "cpu_cores": 0.003,
      "memory_used": 3596288,
      "memory_limit": 2147483648,
      "net_rx": 14.7,
      "net_tx": 211.3,
      "disk_read": 0,
      "disk_write": 0
    }
  ]
}
```

- `cpu_cores` is cores busy averaged over the interval (`2.0` is two cores flat
  out). Sizes are bytes. `net_*` and `disk_read` / `disk_write` are bytes per
  second.
- Container figures come from two consecutive Docker samples, so a container
  appears once it has two, and drops out while its stream stalls for 5 seconds.
  CPU is the delta of `cpu_stats.cpu_usage.total_usage` over the delta of the
  samples' `read` times. `memory_used` is `memory_stats.usage` minus
  `total_inactive_file` (cgroup v1) or `inactive_file` (cgroup v2) when that is
  smaller, as `docker stats` does. Network is the sum over every interface in
  `networks`. Disk is the sum of the `Read` and `Write` entries of
  `blkio_stats.io_service_bytes_recursive`, over all devices.
- `host` is left out when `/host/proc` is not mounted or cannot be read.
  `cpu_cores` is the busy share of the deltas of `/host/proc/stat`'s `cpu`
  line (everything but idle and iowait) times `cores`, the number of `cpuN`
  lines. `memory_used` is `MemTotal - MemAvailable` from `meminfo`, `load1` the
  first field of `loadavg`. `disk_used` and `disk_total` are
  `(blocks - bfree) * bsize` and `blocks * bsize` from `statfs` on
  `/host/etc/hostname`, a file bind-mounted from the host, so it measures the
  host's root filesystem. Both are left out if `statfs` fails.
- Meridian drops frames that arrive faster than one per 0.5 seconds, keeps only
  the keys above, and relays them to the browsers watching. Nothing is stored.

Set `MERIDIAN_LIVE=0` (or `false`) to turn the line off entirely: no
connection, no streams, no `/proc` reads. `meridian-agent -print` never starts
it. If `/host/proc` is not mounted the frames simply have no `host`. If
Meridian has no `/cable` yet, the agent keeps retrying in the background with
the backoff above and one log line per attempt. A panic in the live path is
logged and contained. It never reaches the snapshot loop.

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
| `MERIDIAN_LIVE`        | on                             | `0` or `false` turns the live stats line off entirely |

The first snapshot is sent at startup. After a failure the delay doubles on
each consecutive failure, up to 5 minutes, and it returns to the normal
interval after the next success. Docker calls time out after 10s (a stats
stream is bounded only by its lease), the POST after 15s, and a whole cycle
after 30s. SIGTERM stops the agent cleanly, an in-flight POST is cancelled, and
the live line closes its WebSocket with a close frame.

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
      - /proc:/host/proc:ro                  # live host CPU, memory and load
      - kamal-proxy-config:/kamal-proxy:ro
```

Kamal accessories join the `kamal` network, so the agent reaches the proxy by
its container name (`<service>-docker-proxy`). Do not give the proxy a `port:`.
Port 2375 must never be published on the host.

`CONTAINERS: 1` already covers the live stats endpoint,
`GET /containers/{id}/stats`, so the proxy needs nothing more. The
`/proc:/host/proc:ro` mount is optional: without it frames carry container
numbers but no `host` object. The agent reads only `stat`, `meminfo` and
`loadavg` from it.

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
