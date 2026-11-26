# Configuration

Everything site-specific is set through environment variables, so it stays out of the database and out of Git.

| Variable | Required | Meaning |
| --- | --- | --- |
| `SECRET_KEY_BASE` | yes | Signs sessions and cookies. Generate with `openssl rand -hex 64`. |
| `MERIDIAN_URL` | yes | Public URL, e.g. `https://meridian.example.com`. A plain `http://` URL turns off forced HTTPS. |
| `GITHUB_APP_ID` | yes | The GitHub App's ID. |
| `GITHUB_APP_PRIVATE_KEY` | yes | The App's private key (PEM). Literal `\n` sequences are accepted. |
| `GITHUB_APP_WEBHOOK_SECRET` | yes | Verifies webhook signatures. |
| `GITHUB_TOKEN` | no | Instead of a GitHub App: a personal access token with `repo` and `workflow` scopes. Simpler for a homelab or local development; an App limits access more tightly. |
| `GITHUB_API_URL` | no | For GitHub Enterprise Server, e.g. `https://github.example.com/api/v3/`. |
| `SOLID_QUEUE_IN_PUMA` | no | `true` by default. Set to `false` and run `bin/jobs` in a separate `job` role for large installs. |
| `RAILS_LOG_LEVEL` | no | `info` by default. |

## In the app

**Settings → General** holds:

- the preview domain,
- the preview lifetime (7 days by default),
- the label selector for preview servers,
- where Meridian runs (a place name, latitude and longitude). The map draws agent reports flowing in to it and deploys flowing out from it.

Per project, you can set:

- **Config paths:** comma-separated globs. A file named `x.<dest>.yml` is the `<dest>` destination of `x.yml` when both match.
- **Direct commits:** when on, admins' structural changes (new apps, the CI workflow) are committed instead of proposed. Deploys, rollbacks and preview overlays are always commits.

## Conventions Meridian adds to your infra repository

- **`<config>.version` / `<config>.<dest>.version`:** one line, the image tag CI deploys. Deploy and roll back change only this file.
- **`labels: { meridian.kind: node, meridian.source: owner/repo }`:** optional labels in a config that tell Meridian the app's kind and its source repository, which previews watch. Without them an app is of kind `other` and has no previews.
- **`<config>.pr-<n>.yml`:** a preview overlay. Meridian adds and removes these itself.
- **`.github/workflows/meridian-deploy.yml`:** the workflow that runs Kamal.

## Scaling

The defaults are sized for hundreds of servers on one small machine:

- Snapshots are accepted in milliseconds and ingested by jobs.
- The board is paginated, groups by region above 30 servers, and refreshes each group at most once a second.
- For thousands of servers, run jobs separately (`SOLID_QUEUE_IN_PUMA=false` plus a `job` role), and raise `MERIDIAN_INTERVAL` on agents to 30s or more.
