# Cloudflare Tunnel

A tunnel is one way to reach your servers, not something Meridian assumes. Meridian never calls Cloudflare's API. It writes plain YAML to Git (principle 1), keeps only secret names (principle 4) and makes no assumption about your network (principle 5). You create the tunnel in Cloudflare yourself.

## Apps behind a tunnel

Tick **Behind a Cloudflare Tunnel** on the New app form. The generated base config ends with a `cloudflared` accessory (`templates/kamal/cloudflared.yml`). It connects out to Cloudflare, so the servers need no open ports. It goes in the base file because Kamal resolves accessories with `roles:` after it merges the destination file.

The pull request lists the manual steps.

1. Create a tunnel in Cloudflare with a public hostname `<hostname>` that points at `http://kamal-proxy:80`. Accessories share Kamal's `kamal` Docker network, where the proxy container is `kamal-proxy`.
2. Add the tunnel's token as the `TUNNEL_TOKEN` secret. Meridian's Secrets page picks the name up from the config.
3. After the first deploy, run `kamal accessory boot cloudflared -c <config>` (plus `-d <destination>`). `kamal deploy` doesn't boot accessories.

Every server that runs the connector with the same token is a replica of one tunnel. Cloudflare serves HTTPS, so the app needs no certificate of its own.

## The Tunnels page

**Tunnels** under Manage lists every app with a `cloudflared` accessory, problems first. Meridian finds them in Git (an accessory whose image starts with `cloudflare/cloudflared`) and reads each connector's container from the agents. It never asks Cloudflare, so it can't tell whether the tunnel itself is healthy. Each server that should run the connector shows one state.

- **running** means the agent reports the container and it is running.
- **A Docker state** such as `exited` or `restarting` means the container exists but isn't running.
- **not booted** means the server's agent is reporting and has no such container, so the connector was never booted or was removed. The page shows the `kamal accessory boot` command.
- **unknown** means Meridian can't tell. The server isn't known, has no agent, or hasn't reported lately.

The page also shows the setup steps, the snippet and the current preview hostname format.

## Previews behind a tunnel

Previews are named `pr-<n>.<app>.<preview domain>` by default. That is two levels below the domain. Cloudflare's Universal SSL wildcard covers one level, so behind Cloudflare's proxy or a tunnel those names fail HTTPS unless you pay for Advanced Certificate Manager.

1. In **Settings → General**, set **Hostnames** to `pr-<n>-<app>.<domain>`. Only new and reopened previews change. Existing ones keep their hostname.
2. Give the preview servers' tunnel a wildcard public hostname `*.<preview domain>` that points at `http://kamal-proxy:80`.
3. Add a proxied wildcard DNS record, a CNAME from `*.<preview domain>` to `<tunnel id>.cfargotunnel.com`. One record covers every app.

The preview servers need the `cloudflared` accessory with that tunnel's token, as above.

## Meridian behind a tunnel

GitHub webhooks and agents must reach Meridian. A tunnel can do that.

- Add the same `cloudflared` accessory to Meridian's own `config/deploy.yml`. Its `roles: [ web ]` works there as it is.
- Set `proxy.ssl: false`, because Cloudflare terminates TLS.
- `MERIDIAN_URL` stays the public `https://` URL.
- Agents connect out over HTTP and keep one outbound WebSocket to `/cable`. Both work through a tunnel.
