# The agent

`meridian-agent` is a small Go binary (standard library only, distroless image) that runs on each server and tells Meridian what is actually running there. It:

- reads Docker **read-only**: `GET /containers/json` and `GET /containers/{id}/json`, nothing else;
- recognises Kamal containers by the labels Kamal sets (`service`, `role`, `destination`) and takes the version from the container name, exactly as Kamal does;
- sends container name, image, labels, state, health and start time, and **never** environment variables, commands or mounts, which can contain secrets;
- POSTs a snapshot every 15 seconds (±20% jitter), outbound only, so it works behind NAT and firewalls;
- backs off exponentially when Meridian is down, caps its payload at 1 MiB, and never takes the host down with it.

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
