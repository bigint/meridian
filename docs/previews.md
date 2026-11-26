# Previews

A pull request in an app's **source** repository can run as a Kamal destination, `pr-<n>`, at `https://pr-<n>.<app>.<preview domain>`.

## How it works

1. **The pull request opens, or is pushed to.** Meridian commits `<config>.pr-<n>.yml` next to the app's config. Kamal resolves destination files as siblings of `-c` ([source](architecture.md#destination-files)), so `kamal deploy -c deploy/shop.yml -d pr-12` reads `deploy/shop.pr-12.yml`. The overlay sets:
   - `service: <app>-pr-<n>`, so its containers and proxy route never touch the real app;
   - one server for every role, chosen by the preview label selector;
   - the preview hostname;
   - everything else from the app's destination file, if it has one.

   Meridian validates the overlay with Kamal before committing it.
2. **CI deploys the pull request's head.** Meridian dispatches the workflow with `command=deploy`, `destination=pr-<n>` and `version=<head SHA>`. Your source repository's CI must push an image tagged with the commit SHA.
3. **The pull request closes, or the preview expires** (7 days by default). Meridian dispatches `command=remove`, CI runs `kamal remove -d pr-<n>`, and once that run succeeds Meridian deletes the overlay.

## Requirements

- **The App is installed on the source repository,** and the app's config names it: `labels: { meridian.source: owner/repo }`. New apps created in Meridian get this label automatically.
- **A preview domain** is set under **Settings → General**.
- **Wildcard DNS.** For each app with previews, create `*.<app>.<preview domain>` pointing at your preview servers, or at the tunnel or load balancer in front of them, e.g. `*.shop.preview.example.com`. Meridian doesn't manage DNS. In **Settings → General** you can choose flat hostnames, `pr-<n>-<app>.<preview domain>`, so one wildcard record `*.<preview domain>` covers every app and works with Cloudflare's free certificate; see [Cloudflare Tunnel](cloudflare-tunnel.md). If you use `ssl: true`, kamal-proxy issues a certificate per host through Let's Encrypt, so the names must resolve publicly.
- **Preview servers.** Set the selector, e.g. `role=preview`. The least busy matching server is used. If the selector is blank, the app's own first server is used.
- **The CI workflow** must be Meridian's (or keep its `run-name`), because Meridian matches preview runs by name.

## Limits

- Each preview runs every role on one server. Accessories (databases and so on) are shared with the base config; give previews their own through a destination file if you need isolation.
- Secrets come from the same repository secrets as the app.
