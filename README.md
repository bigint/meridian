# Meridian

Meridian is an open-source control room for [Kamal](https://kamal-deploy.org): see every app on every server, deploy, roll back and add apps, with Git as the record of everything.

A meridian is the line navigators measure every position against. Here that line is Git.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/board-dark.png">
  <img alt="The board: what needs attention, in plain sentences, then every app on every server" src="docs/screenshots/board.png">
</picture>

## Install

Try it locally:

```bash
docker run -d -p 127.0.0.1:3000:80 -v meridian:/rails/storage -e SECRET_KEY_BASE=$(openssl rand -hex 64) -e MERIDIAN_URL=http://localhost:3000 ghcr.io/bigint/meridian:v0.1.5
```

Then open <http://localhost:3000>.

To use it for real, create a GitHub App, deploy Meridian with Kamal (it ships its own `config/deploy.yml`), add your infra repository, and put the agent on your servers. [Install](docs/install.mdx) walks through all of it in about 15 minutes.

## Principles

1. **Git is the record.** Every change Meridian makes is a commit or a pull request to your infra repository, written as plain YAML. Uninstalling Meridian loses nothing but its audit trail.
2. **One deploy path.** Meridian commits; CI runs Kamal. Deploy status comes from CI.
3. **Observe, never change, servers.** A read-only agent on each server reaches out to Meridian. Meridian never connects in.
4. **Secrets are write-only.** Meridian stores secret names. Values go straight to GitHub and are never kept.
5. **Generic.** No assumptions about providers, networks or hostnames.
6. **Scale is a feature.** Built for 500 servers and 200 apps from day one.
7. **The Rails way.** Rails 8, Hotwire, SQLite, no Node, no build step, one container.

## How it works

```
Operator ──▶ Meridian ──commits, PRs──▶ GitHub ──Actions──▶ kamal deploy ──SSH──▶ servers
               ▲                         │                                       │
               └─ polls every 30 s ──────┘     meridian-agent (outbound only) ────┘
```

- **Board:** what needs attention first, in plain sentences; then apps × servers, with each cell's drift state: in sync, drifted, missing, stray, stale or unknown.
- **Search:** type an app, server or project name in the search box in the top bar, press Enter.
- **Deploy and roll back:** commit or revert a one-line version file next to the app's Kamal config. CI runs `kamal deploy`.
- **New app:** a form that opens a pull request with a Kamal config for a static, Node (Next.js) or Rails app.
- **Secrets:** names come from your configs. Values are sealed for GitHub Actions secrets.

## Documentation

The documentation is a [Mintlify](https://mintlify.com) site in [`docs/`](docs), to be served at meridian.yoginth.com. Preview it with `bin/docs` (needs Node 20.17 or later). Good places to start:

- [Quickstart](docs/quickstart.mdx) and [Install](docs/install.mdx)
- [How it works](docs/concepts/how-it-works.mdx) and [drift states](docs/concepts/drift.mdx)
- Guides: [deploy and roll back](docs/guides/deploy.mdx), [new apps](docs/guides/new-app.mdx), [the agent](docs/guides/agent.mdx), [Cloudflare Tunnel](docs/guides/cloudflare-tunnel.mdx)
- Reference: [environment variables](docs/reference/environment.mdx), [the infra repository](docs/reference/infra-repository.mdx), [the CI workflow](docs/reference/ci-workflow.mdx)
- Operate: [security](docs/operate/security.mdx), [backups with Litestream](docs/operate/backups.mdx)

For working on Meridian itself: [development](contributing/development.md), [architecture](contributing/architecture.md), [decisions](contributing/decisions.md), [design](contributing/design.md) and the [local lab](lab/README.md).

## Development

```bash
bin/setup        # installs gems and prepares the databases (needs libsodium)
bin/dev          # the app on :3000
bin/ci           # everything CI runs: lint, security, Rails and Go tests
```

See [CONTRIBUTING.md](CONTRIBUTING.md). Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md); report vulnerabilities as [SECURITY.md](SECURITY.md) describes.

## License

MIT. See [LICENSE](LICENSE). Icons are [Lucide](https://lucide.dev)'s, under the ISC licence in [vendor/lucide/LICENSE](vendor/lucide/LICENSE).
