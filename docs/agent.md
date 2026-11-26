# The agent

`meridian-agent` is a small Go binary (standard library only, distroless image) that runs on each server and tells Meridian what is actually running there. It:

- reads Docker **read-only**: `GET /containers/json`, `GET /containers/{id}/json` and, only while someone has the server's page open, `GET /containers/{id}/stats`, nothing else;
- recognises Kamal containers by the labels Kamal sets (`service`, `role`, `destination`) and takes the version from the container name, exactly as Kamal does;
- sends container name, image, labels, state, health and start time, and **never** environment variables, commands or mounts, which can contain secrets;
- POSTs a snapshot every 15 seconds (±20% jitter), outbound only, so it works behind NAT and firewalls;
- backs off exponentially when Meridian is down, caps its payload at 1 MiB, and never takes the host down with it;
- keeps one outbound WebSocket open to Meridian's `/cable` for live stats (below).

## Live stats

Open a server's page and its CPU, memory, load and disk, and every container's CPU, memory, network and disk IO, update once a second.

The agent holds one WebSocket open to `MERIDIAN_URL/cable`, outbound like everything else, authenticated with the same token. While nobody watches, nothing flows but ActionCable's pings. When someone opens the page, Meridian sends a 30-second lease and renews it while the page stays open. Until the lease runs out the agent streams Docker's stats for each running Kamal container and sends Meridian one frame a second, which Meridian relays to the open pages and never stores. Close the page and the agent stops within 30 seconds.

Host numbers come from the host's `/proc`, mounted read-only at `/host/proc` (the template does this). Without it the page shows per-container numbers only. Disk usage is the host's root filesystem, read with `statfs` on the already-mounted `/host/etc/hostname`.

`MERIDIAN_LIVE=0` turns live stats off; the agent then only posts snapshots. Your proxy must pass WebSockets through to Meridian; kamal-proxy and Thruster both do.

The full reference (every environment variable and the payload format) is in [`agent/README.md`](../agent/README.md).

## Install with Kamal

1. In Meridian, open **Agents → New token**. One token per server is safest. Copy the token; it is shown once.
2. Add the two accessories from the Agents page, or from [`templates/kamal/agent-accessories.yml`](../templates/kamal/agent-accessories.yml), to a Kamal config whose `servers` cover your hosts, and put `MERIDIAN_TOKEN` in `.kamal/secrets`.
3. Boot them:

   ```bash
   kamal accessory boot meridian_docker
   kamal accessory boot meridian_agent
   ```

`meridian_docker` is [`tecnativa/docker-socket-proxy`](https://github.com/Tecnativa/docker-socket-proxy) with `CONTAINERS=1` and `POST=0`. The agent talks to Docker only through it, so even a compromised agent can't start, stop or exec into containers.

### One token per server, or one for the fleet

- A **per-server token** binds to the first machine that uses it. If another machine tries it, the request is refused.
- A **fleet token** (tick "Fleet token") is shared by many servers. Each server is then identified by its `/etc/machine-id`. Revoking a fleet token silences every server that uses it.

### Matching servers to Git

Git names servers by the host Kamal connects to, such as `web-1.example.com` or an IP address. The agent reports the machine's own hostname. Meridian matches them in this order:

1. the exact hostname;
2. the first DNS label (`web-1` matches `web-1.example.com`), when only one server has it.

When neither matches, set `MERIDIAN_HOSTNAME` on the agent to the name used in your config.

## kamal-proxy routes (optional)

kamal-proxy keeps its routes in `kamal-proxy.state`, inside the named volume `kamal-proxy-config`. To report routes:

1. Mount that volume read-only into the agent, for example `kamal-proxy-config:/kamal-proxy:ro`.
2. Set `MERIDIAN_PROXY_STATE=/kamal-proxy/kamal-proxy.state`.

kamal-proxy rewrites the file in place, so the agent sometimes catches it half-written. When that happens it retries once, then skips routes for that snapshot.

The only other way to read routes is `kamal-proxy list`, which needs `docker exec`. The agent never uses it. The research behind both points, with links to the source, is in [architecture.md](architecture.md#kamal-proxy-routes-read-only).

## Labels

`MERIDIAN_LABELS=region=sgp,provider=ovh,role=web` sets the labels the board filters and groups by. Use any keys you like. `region`, `provider` and `role` get their own filters.

Add `lat` and `lng` (decimal degrees) to put the server on the map, e.g. `MERIDIAN_LABELS=region=sgp,lat=1.35,lng=103.82`. An admin can also set a location on the server page; an agent that reports one wins.
