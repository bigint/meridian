# Cloudflare Tunnel

A tunnel is one way to reach your servers, not something Meridian assumes. Meridian never calls Cloudflare's API. It writes plain YAML to Git (principle 1), keeps only secret names (principle 4) and makes no assumption about your network (principle 5). You create the tunnel in Cloudflare yourself.

## Apps behind a tunnel

Give each app its own tunnel and its own token. Cloudflare spreads a tunnel's requests over all its connectors, so a tunnel shared by apps on different servers sends some requests to servers that don't run the app. The token lives in a repository secret named after the service, `<SERVICE>_TUNNEL_TOKEN` (`saleor-api` becomes `SALEOR_API_TUNNEL_TOKEN`). The accessory reads it with Kamal's secret alias, `TUNNEL_TOKEN:<SERVICE>_TUNNEL_TOKEN`, because cloudflared expects `TUNNEL_TOKEN`.

For a new app, tick **Behind a Cloudflare Tunnel** on the New app form. The generated base config ends with the `cloudflared` accessory (`templates/kamal/cloudflared.yml`), and the pull request lists the steps. For an existing app, **Tunnels → Set up a tunnel** shows the same steps with that app's names filled in. These match the Cloudflare dashboard as of November 2026.

1. **Create the tunnel.** Open **Networking → Tunnels**, click **Create Tunnel**, name it after the app and click **Create Tunnel**.
2. **Copy its token.** On the tunnel's **Overview**, under **Install cloudflared connector**, choose **Docker** and copy the command. Keep only the value after `--token`. Don't run the command; Kamal runs the connector.
3. **Save the token.** On Meridian's Secrets page, set `<SERVICE>_TUNNEL_TOKEN` to it. Add `<SERVICE>_TUNNEL_TOKEN=$<SERVICE>_TUNNEL_TOKEN` to `.kamal/secrets`, so Kamal can read it.
4. **Add a route.** On the tunnel's **Routes** tab, click **Add route → Published application**. Enter the hostname, and `http://kamal-proxy:80` as the **Service URL**. Cloudflare creates the DNS record, though not always: in testing it skipped 3 of 6. Check **DNS → Records**, and if the record is missing, add a proxied CNAME from the hostname to `<tunnel ID>.cfargotunnel.com`. If the hostname isn't one the app already serves, open **Additional application settings → HTTP** and set **HTTP Host Header** to one it does. kamal-proxy routes by Host, and apps such as nginx sites or Rails check it too, so an unknown name gets a 404. Accessories share Kamal's `kamal` Docker network, where the proxy container is `kamal-proxy`.
5. **Add the connector** to the app's config and commit it. It goes in the base file because Kamal resolves accessories with `roles:` after it merges the destination file.
6. **Start it once** with `kamal accessory boot cloudflared -c <config>` (plus `-d <destination>`), with the token secret in the environment. `kamal deploy` doesn't start accessories.

Every server that runs the connector is a replica of the app's tunnel. Cloudflare serves HTTPS, so the app needs no certificate of its own. Keep hostnames one level below the domain: Cloudflare's free certificate covers `app.example.com`, not `app.team.example.com`.

## The Tunnels page

**Tunnels** under Manage lists every app with a `cloudflared` accessory, problems first. Meridian finds them in Git (an accessory whose image starts with `cloudflare/cloudflared`) and reads each connector's container from the agents. It never asks Cloudflare, so it can't tell whether the tunnel itself is healthy. Each server that should run the connector shows one state.

- **running** means the agent reports the container and it is running.
- **A Docker state** such as `exited` or `restarting` means the container exists but isn't running.
- **not booted** means the server's agent is reporting and has no such container, so the connector was never booted or was removed. The page shows the `kamal accessory boot` command.
- **unknown** means Meridian can't tell. The server isn't known, has no agent, or hasn't reported lately.

Each row also names the app's token secret and whether Meridian has set it. **Set up a tunnel** opens the steps for any app, grouped by where you do them (Cloudflare, Git, the servers), with its names, hostname, secret, config path and boot command ready to copy. The steps Meridian can see tick themselves off: the token set from its Secrets page, the connector in the config, and the connector running.

## Previews behind a tunnel

Previews are named `pr-<n>.<app>.<preview domain>` by default. That is two levels below the domain. Cloudflare's Universal SSL wildcard covers one level, so behind Cloudflare's proxy or a tunnel those names fail HTTPS unless you pay for Advanced Certificate Manager.

1. In **Settings → General**, set **Hostnames** to `pr-<n>-<app>.<domain>`. Only new and reopened previews change. Existing ones keep their hostname.
2. Give the preview servers' tunnel a wildcard public hostname `*.<preview domain>` that points at `http://kamal-proxy:80`.
3. Add a proxied wildcard DNS record, a CNAME from `*.<preview domain>` to `<tunnel id>.cfargotunnel.com`. One record covers every app.

The preview servers need a `cloudflared` connector for that tunnel, booted the same way.

## Meridian behind a tunnel

GitHub webhooks and agents must reach Meridian. A tunnel can do that.

- Add the same `cloudflared` accessory to Meridian's own `config/deploy.yml`. Its `roles: [ web ]` works there as it is.
- Set `proxy.ssl: false`, because Cloudflare terminates TLS.
- `MERIDIAN_URL` stays the public `https://` URL.
- Agents connect out over HTTP and keep one outbound WebSocket to `/cable`. Both work through a tunnel.
