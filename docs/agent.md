# The agent

`meridian-agent` is a small Go binary (standard library only, distroless image) that runs on each server and tells Meridian what is actually running there. It:

- reads Docker **read-only**: `GET /containers/json`, `GET /containers/{id}/json` and, only while someone is looking, `GET /containers/{id}/stats` and (if you turn logs on) `GET /containers/{id}/logs`, nothing else;
- recognises Kamal containers by the labels Kamal sets (`service`, `role`, `destination`) and takes the version from the container name, exactly as Kamal does;
- sends container name, image, labels, state, health and start time, and **never** environment variables, commands or mounts, which can contain secrets;
- POSTs a snapshot every 15 seconds (±20% jitter), outbound only, so it works behind NAT and firewalls;
- backs off exponentially when Meridian is down, caps its payload at 1 MiB, and never takes the host down with it;
- keeps one outbound WebSocket open to Meridian's `/cable` for live stats (below).

## Live stats

Open a server's page and its CPU, memory, load and disk, and every container's CPU, memory, network and disk IO, update once a second.

The agent holds one WebSocket open to `MERIDIAN_URL/cable`, outbound like everything else, authenticated with the same token. While nobody watches, nothing flows but ActionCable's pings. When someone opens the page, Meridian sends a 30-second lease and renews it while the page stays open. Until the lease runs out the agent streams Docker's stats for each running Kamal container and sends Meridian one frame a second, which Meridian relays to the open pages and never stores. Close the page and the agent stops within 30 seconds.

Host numbers come from the host's `/proc`, mounted read-only at `/host/proc` (the template does this). Without it the page shows per-container numbers only. Disk usage is the host's root filesystem, read with `statfs` on the already-mounted `/host/etc/hostname`.

## Live logs

With `MERIDIAN_LOGS=1` on the agent, deployers and admins can open a container's logs, or an app's logs merged across every server it runs on. They see the last 200 lines, then new lines as they're written.

It works like live stats. Opening the logs sends the agent a 30-second lease for that container, renewed while the page is open. The agent follows `docker logs` for it and sends lines in batches of up to 250 ms, and stops when the lease runs out.

- **Off by default.** Logs can contain secrets, so the agent tails nothing unless `MERIDIAN_LOGS=1`. The accessory template turns it on; remove the line to keep logs on the server.
- **Kamal containers only.** The agent checks every container it is asked for against Kamal's labels itself, so even a compromised Meridian can't read the logs of anything else on the host.
- **Bounded.** At most 20 containers at once, 8 KB per line, and 512 KB per second per container. Lines beyond that are dropped and counted.
- **Not stored.** Lines are relayed to the open page. They pass through the cable database, which keeps messages for a minute. Each time someone opens logs, it's recorded in Activity.

## Traffic

An app's **Traffic** page shows its requests as they happen, from kamal-proxy on every server the app runs on. Each request reads as its status, method, host and path, how long it took, the container that answered (by name and short version), and who asked. The server it came through is the chip at the start of the line.

It is live logs again, aimed at the `kamal-proxy` container: the same `MERIDIAN_LOGS=1`, lease, limits and Activity record. kamal-proxy logs every app's requests in one stream, so Meridian keeps only the lines whose `service` is one of the app's (`<service>-<role>`, plus each preview's destination) before relaying them. The page starts from kamal-proxy's last 200 lines, every app's together, so a quiet app may show few at first. More would not fit: the agent sends at most 512 KB a second of one container, and kamal-proxy's lines run to a kilobyte.

Behind a [Cloudflare Tunnel](cloudflare-tunnel.md#traffic-behind-a-tunnel), kamal-proxy sees `cloudflared`, not the visitor, unless the app's Kamal config logs Cloudflare's headers.

`MERIDIAN_LIVE=0` turns live stats and logs off; the agent then only posts snapshots. Your proxy must pass WebSockets through to Meridian; kamal-proxy and Thruster both do.

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
