# Cloudflare Tunnel

One Cloudflare Tunnel can serve every app, with a connector on each server and no open ports. Meridian reads the tunnel from Git and the agents and never calls Cloudflare's API: it writes plain YAML to Git (principle 1), keeps only secret names (principle 4) and makes no assumption about your network (principle 5). You create the tunnel and its routes in Cloudflare yourself.

## How it works

- **One tunnel, one token.** The token lives in the repository secret `CLOUDFLARE_TUNNEL_TOKEN`. cloudflared reads `TUNNEL_TOKEN`, so the connectors alias it: `TUNNEL_TOKEN:CLOUDFLARE_TUNNEL_TOKEN`.
- **A connector on each server.** `deploy/edge.yml` (the first config glob, with `edge` for the service) runs only accessories: one `cloudflared-<server>` per server, each with its own `hostname`, so Cloudflare lists every replica by server name. Its `meridian.kind: accessories` label keeps it off the board, and Kamal never deploys an app from it.
- **Every hostname to kamal-proxy.** The tunnel routes each app's hostname to `http://kamal-proxy:80`, which routes by Host. Accessories share Kamal's `kamal` Docker network, where the proxy container is `kamal-proxy`.
- **The rule.** Cloudflare sends each request to whichever connector is nearest, not to the server that runs the app. So every connector's server must run every app the tunnel serves, or kamal-proxy answers 404. Run your apps on the connector servers before you route them.

Meridian finds a tunnel from Git: every accessory whose image starts with `cloudflare/cloudflared` (or, for configs synced before images were recorded, one named `cloudflared`), grouped by the token secret it reads. A tunnel is named after the config its connectors live in.

## Setting it up

**Tunnels → Set up a tunnel** shows these steps in the project's own names. Pick the connector servers in its panel; it generates the edge config for them and names any app that isn't on all of them. The steps match the Cloudflare dashboard as of November 2026, and the ones Meridian can see tick themselves off.

1. **Create the tunnel.** In Cloudflare, open **Networking → Tunnels** and click **Create Tunnel**.
2. **Copy its token.** Under **Install cloudflared connector**, choose **Docker** and copy the command. Keep only the value after `--token`. Don't run the command.
3. **Save the token.** On Meridian's Secrets page, set `CLOUDFLARE_TUNNEL_TOKEN`. Add `CLOUDFLARE_TUNNEL_TOKEN=$CLOUDFLARE_TUNNEL_TOKEN` to `.kamal/secrets`.
4. **Add the connectors.** Commit the generated `deploy/edge.yml` (`templates/kamal/edge.yml`).
5. **Start them** with `kamal accessory boot all -c deploy/edge.yml`, from a machine that can SSH to the servers, with the token in its environment. `kamal deploy` doesn't start accessories. Each connector should register four connections.
6. **Route each hostname.** On the tunnel's **Routes** tab, add a **Published application** per hostname, all to `http://kamal-proxy:80`. Cloudflare creates the DNS record, though not always: in testing it skipped 3 of 6. Check **DNS → Records**, and if one is missing, add a proxied CNAME to `<tunnel ID>.cfargotunnel.com`.
7. **Check it.** The Tunnels page shows every connector running and no app missing from a connector's server, and Cloudflare shows the tunnel Healthy with one replica per server.

To serve a hostname the app doesn't answer to, set **HTTP Host Header** under **Additional application settings → HTTP** to one it does: kamal-proxy routes by Host, and apps such as nginx sites or Rails check it too. Keep hostnames one level below the domain: Cloudflare's free certificate covers `app.example.com`, not `app.team.example.com`.

## The Tunnels page

**Tunnels** under Manage shows each tunnel, problems first.

- **Connectors**, one per server, each in one state: **running**; a Docker state such as `exited`; **not started**, when the server's agent reports but has no such container (the page shows the `kamal accessory boot` command); or **unknown**, when the server isn't known or its agent hasn't reported lately.
- **The token** secret, and whether Meridian has set it.
- **Apps it can serve**: those that run on every connector's server. An app on only some of them gets a warning naming the servers it's missing from. Meridian can't see Cloudflare's routes, so this is advice, not an error: don't route that app through the tunnel until it runs everywhere. Apps on no connector's server are listed quietly.

## Previews behind a tunnel

Previews are named `pr-<n>.<app>.<preview domain>` by default, two levels below the domain, which Cloudflare's free certificate doesn't cover.

1. In **Settings → General**, set **Hostnames** to `pr-<n>-<app>.<domain>`. Only new and reopened previews change.
2. Give the tunnel a wildcard route `*.<preview domain>` to `http://kamal-proxy:80`, and a proxied wildcard CNAME `*.<preview domain>` to `<tunnel ID>.cfargotunnel.com`.
3. Use the connector servers as the preview servers (the preview selector), so every preview runs where the tunnel can reach it.

## Traffic behind a tunnel

Every request reaches kamal-proxy from `cloudflared`, so an app's [Traffic](agent.md#traffic) page can't tell visitors apart unless kamal-proxy logs Cloudflare's headers. Apps created in a project with a tunnel get this in their Kamal config. Add it to older ones and deploy:

```yaml
proxy:
  logging:
    request_headers:
      - Cf-Connecting-Ip
      - Cf-Ipcountry
      - Cf-Ray
```

Each request then shows the visitor's address and country, and the Cloudflare location it came through (the last part of `Cf-Ray`, such as `SIN`).

## Meridian behind a tunnel

GitHub webhooks and agents must reach Meridian. Run Meridian on a connector server, add a route for its hostname, and set `proxy.ssl: false`, because Cloudflare terminates TLS. `MERIDIAN_URL` stays the public `https://` URL. Agents connect out over HTTPS and keep one WebSocket to `/cable`; both work through a tunnel.
