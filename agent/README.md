# meridian-agent

A small, read-only observer for Kamal hosts. It runs on each server as a Kamal
accessory, lists the host's Kamal containers through the Docker API, and POSTs
a snapshot of them to Meridian every 15 seconds or so. While someone has the
server's page open in Meridian it also streams live CPU, memory, network and
disk numbers once a second ([Live stats](#live-stats)). With `MERIDIAN_LOGS=1`
it tails the logs of Kamal containers that someone is reading
([Container logs](#container-logs)). It never starts, stops or changes
anything, and it is built from the Go standard library alone.

## What it reads

- **Docker**: only `GET /containers/json?all=1` and `GET /containers/{id}/json`
  for snapshots, plus `GET /containers/{id}/stats?stream=true` while someone is
  watching ([Live stats](#live-stats)) and, with `MERIDIAN_LOGS=1`,
  `GET /containers/{id}/logs` while someone is reading a container's logs
  ([Container logs](#container-logs)).
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
  "interval_seconds": 15,
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
  "truncated": true
}
```

- Every container key is always present. Unknown values are `""`. `health` is
  `""` when the container has no healthcheck, and `started_at` is `""` for a
  container that never started.
- `containers` is sorted by name and includes stopped containers, because Kamal
  keeps old versions around.
- `truncated` appears only when the snapshot went over 1 MiB and containers
  were dropped from the end to fit.
- `interval_seconds` is `MERIDIAN_INTERVAL` in whole seconds (at least 1),
  before jitter, so Meridian can tell a quiet agent from a slow one. Meridian
  calls a server stale after three intervals, and never sooner than 45 s.
- Any 2xx response counts as delivered. After a 429 the agent waits at least
  the response's `Retry-After` (seconds or an HTTP date, capped at 5 minutes,
  plus up to 20% jitter) before the next try, even when its backoff is
  shorter.

## Live stats

Snapshots say what is running. Live stats say how hard it is working, and they
only flow while someone is looking. The agent stays outbound-only and
read-only, and snapshots are unaffected. Two independent loops
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
min(seconds, 120))`, so the two hosts' clocks never meet. Messages of a type the
agent does not know are ignored, and `tail` ([Container logs](#container-logs))
has its own lease. Nothing streams outside a lease.

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
connection, no streams, no `/proc` reads, and no container logs, which ride the
same line. `meridian-agent -print` never starts
it. If `/host/proc` is not mounted the frames simply have no `host`. If
Meridian's `/cable` cannot be reached, the agent keeps retrying in the
background with the backoff above and one log line per attempt. A panic in the live path is
logged and contained. It never reaches the snapshot loop.

## Container logs

A deployer can open a container's logs in Meridian, or an app's logs merged
across the servers it runs on, and see the last 200 lines and then new ones as
they are written. Logs are **off** unless you set `MERIDIAN_LOGS=1`. They ride
the live line, so `MERIDIAN_LIVE=0` turns them off too (the agent logs one
warning at start if you set both). Nothing is tailed while nobody reads. The
agent passes lines on and keeps none: it writes them to no file and to no log
of its own, and Meridian does not store them either.

**Only Kamal's containers.** Before every new tail the agent inspects the
container itself and follows it only if the rule from
[What it reads](#what-it-reads) accepts it: an app, an accessory or
kamal-proxy. It never follows its own container, and it does not matter what
Meridian asks for. At most 20 containers are followed at once.

**Tail leases.** Inside ActionCable's envelope, like a watch lease:

```json
{"type":"tail","container":"<64-hex id>","seconds":30,"backlog":200}
```

- Someone is reading this container's logs: follow it for the next `seconds`.
  Per container, `until = max(until, now + min(seconds, 120))`. Meridian renews
  about every 10 seconds with `"backlog":0`. When the lease lapses the agent
  cancels the Docker stream.
- `backlog` (at most 1000) asks for that many recent lines once. If the
  container is not followed yet, the agent starts following with
  `tail=<backlog>` and marks the batches that carry those history lines
  `"backlog":true`. If it is already followed, the agent makes one separate,
  non-following request for the last `backlog` lines and sends them as
  `"backlog":true` batches, and the follow itself carries on untouched. A line
  is history when Docker stamped it no later than the moment the agent opened
  the follow.
- With logs off, every tail is answered with
  `{"action":"logs","container":"<id>","off":true}` and nothing else happens.
- A container the agent will not follow (not Kamal's, not found, its own, or
  the 20 limit) is answered with
  `{"action":"logs","container":"<id>","refused":"<short reason>"}`.
- A container that is not running and has no backlog asked for is not
  followed: it already reported `ended`. A later lease follows it once it runs
  again.

**Batches.** The agent sends them as ActionCable commands, like stats frames,
and only while the line is subscribed. They are never queued.

```json
{
  "action": "logs",
  "container": "<64-hex id>",
  "backlog": false,
  "lines": [
    {"t": "2026-11-26T12:16:25.123456789Z", "s": "out", "m": "GET / 200 1.2ms"},
    {"t": "2026-11-26T12:16:25.200000000Z", "s": "err", "m": "warn: slow query"}
  ],
  "dropped": 0,
  "ended": false
}
```

- The agent reads `GET /containers/{id}/logs?follow=1&stdout=1&stderr=1&timestamps=1&tail=<n>`
  (`tail=0` for only new lines; the separate backlog request uses `follow=0`).
  Without a TTY (`Config.Tty` false in the inspect) the stream is multiplexed:
  8-byte frame headers, byte 0 the stream (1 stdout, 2 stderr), bytes 4 to 7
  the big-endian payload length. A line can span frames, and stdout and stderr
  lines can come in between, so each stream keeps its own partial line. With a
  TTY the stream is raw and every line is `"out"`.
- `t` is Docker's RFC3339Nano timestamp, as sent. `s` is `"out"` or `"err"`.
  `m` is the line without its newline and without a trailing `\r`, as valid
  UTF-8 (each invalid byte becomes U+FFFD), cut to 8192 bytes between
  characters with a trailing `…` when longer. ANSI escape codes pass through
  untouched. A line without a timestamp keeps all of itself in `m` with an
  empty `t`.
- At most one batch per container every 250 ms, with at most 500 lines and
  256 KiB of `m`, so at most 2000 lines a second. A full batch waits for its
  turn too. Live lines that arrive while it waits are dropped and counted in
  the next batch's `dropped`, so the agent never falls behind Docker. History
  is bounded, so its lines wait their turn and none is dropped for the pace.
  History lines and live lines never share a batch. Empty batches are not sent
  unless they carry `dropped` or `ended`.
- A container may also send at most 512 KiB a second, counting each line's
  `m` plus 64 bytes for the rest of it. Lines beyond that are dropped and
  counted in `dropped` too.
- `ended: true` comes once, when Docker closes the follow stream and an
  inspect then shows the container is no longer running (in the last batch,
  with any lines still waiting). The agent stops following. The next tail
  starts it again, when the container runs. A stream closed under a running
  container (the socket proxy cuts streams idle for 10 minutes) is reopened a
  second later with `since=<the last line's stamp>`, so nothing is lost or
  repeated and no `ended` is sent.
- Memory is bounded: a partial line and one batch per container, and a reader
  that runs at most 64 lines ahead of the batcher. A slow WebSocket slows
  Docker's stream down and never grows a queue. A bug in a follower is logged
  and costs that one stream.

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
| `MERIDIAN_LIVE`        | on                             | `0` or `false` turns the live stats line off entirely, container logs with it |
| `MERIDIAN_LOGS`        | off                            | `1` or `true` lets Meridian tail the logs of Kamal containers ([Container logs](#container-logs)). Needs the live line |

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
    network: meridian   # not kamal: apps must not reach the proxy
    env:
      clear:
        CONTAINERS: 1   # allow GET /containers/*
        POST: 0         # deny every non-GET request
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro

  agent:
    image: ghcr.io/example/meridian-agent   # your build of agent/Dockerfile
    roles: [web]
    network: meridian
    env:
      clear:
        MERIDIAN_URL: https://meridian.example.com
        DOCKER_HOST: tcp://<service>-docker-proxy:2375
        MERIDIAN_LABELS: region=sgp,provider=ovh
      secret:
        - MERIDIAN_TOKEN
    volumes:
      - /etc/machine-id:/host/etc/machine-id:ro
      - /etc/hostname:/host/etc/hostname:ro
      - /proc:/host/proc:ro                  # live host CPU, memory and load
```

Kamal accessories join the `kamal` network unless told otherwise, and so do
your apps: on it, any app container could ask the proxy for every container's
environment, files and logs. Give the proxy and the agent a network of their
own (`network: meridian` on both, after `docker network create meridian` once
per host, for example with `kamal server exec`); the agent reaches the proxy
by its container name (`<service>-docker-proxy`) there, and Meridian over the
host's own routes. Do not give the proxy a `port:`. Port 2375 must never be
published on the host.

`CONTAINERS: 1` already covers the live stats and logs endpoints,
`GET /containers/{id}/stats` and `GET /containers/{id}/logs`, so the proxy
needs nothing more. The
`/proc:/host/proc:ro` mount is optional: without it frames carry container
numbers but no `host` object. The agent reads only `stat`, `meminfo` and
`loadavg` from it.

If you skip the proxy and mount the socket directly, note that the image runs
as `nonroot` (uid 65532), which cannot open a `root:docker` socket. Add the
host's docker group with `options: { group-add: "<docker gid>" }`.

## Development

```bash
go vet ./... && go test ./...
docker build --build-arg VERSION=$(git rev-parse --short HEAD) -t meridian-agent .
```

The image is a static `CGO_ENABLED=0` binary of about 7 MB on
`gcr.io/distroless/static-debian13:nonroot`. Compressed, as a registry
serves it, the image is about 3.5 MB.
