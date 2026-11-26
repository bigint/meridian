# Changelog

## Unreleased

### Instrument interface

- A new look of Meridian's own: zinc neutrals, one teal accent, monospace for versions and hosts, compact tables, 6px corners, and light and dark themes. Still no shadows. See `docs/design.md`.
- A left sidebar with the main places always in view and a search box that finds any app, server or project as you type. On phones it is a drawer behind a Menu button.
- Built with Tailwind 4 (standalone binary, still no Node) and a ViewComponent library, `app/components/ui/`, browsable at `/lookbook` in development.
- Install snippets and one-time tokens have a copy button.
- The board opens on **Needs attention**: plain sentences such as "web isn't running on web-2, but Git says it should", with silent agents summarised in one line. The grid follows, with filters folded away.
- A getting-started checklist on new installs, a one-line status on each app ("✓ Running v42 everywhere"), and Activity laid out day by day.
- `bin/rails meridian:demo` can be run again over an existing demo fleet.
- Keyboard shortcuts are gone for now; everything is one click from the sidebar.

### World map

- Servers have a latitude and longitude, reported by agents as `lat`/`lng` labels or set by an admin. The Map shows them as places, merged when close together, each marked with its worst drift state.
- Solid arcs link places that run the same app, thicker when they share more. Dotted flows show agent reports arriving at Meridian and deploys going out from it, live. Meridian sees containers, not packets, so it draws only traffic it takes part in.
- Land outlines are Natural Earth's public-domain 1:110m data, projected once into a cached SVG (`script/world_map.rb`).

### Local lab

- `bin/lab` runs three Docker-in-Docker servers, a registry and a self-hosted GitHub Actions runner, so Meridian can drive real Kamal deploys end to end on one laptop.
- `GITHUB_TOKEN` can stand in for a GitHub App.
- Fixed: `GITHUB_APP_ID` was read from the wrong variable. Redeploys are tracked like deploys. The CI template runs on self-hosted runners via `MERIDIAN_RUNS_ON`.
- New-app Dockerfiles carry `LABEL service=…`, which Kamal requires of images it didn't build.

## v0.1.0 (2026-11-25)

The first release: M0 to M6.

### M0: Read-only board from Git

- Rails 8.1 app on SQLite with Solid Queue (in Puma), Solid Cache and Solid Cable, each in its own database file.
- Email and password sign-in from the Rails authentication generator, a first-run admin, roles (viewer, deployer, admin) and optional OpenID Connect.
- Projects: one infra repository each, read through a GitHub App installation. Sync fetches only config blobs that changed.
- Kamal configs parsed by Kamal 2.12.0 itself, in a clean subprocess, so ERB in a config never sees Meridian's environment. Parse errors show file and line.
- Board of apps × servers (or servers × apps), with drift summary, filters in the URL, grouping by label and pagination. App, server, project, activity and settings pages.

### M1: Agent and live board

- `meridian-agent`: a standard-library Go binary that reads Docker read-only (list and inspect only), recognises Kamal containers by label and name, and POSTs snapshots outbound with backoff and jitter. Optional kamal-proxy routes from the state file, mounted read-only.
- Agent tokens stored as SHA-256 digests, shown once, revocable; per-server tokens bind on first contact, fleet tokens identify servers by machine id.
- `POST /agent/snapshots` validates, enqueues and returns 202; ingestion upserts placements in one transaction and drops containers that are gone.
- Drift states (in sync, drifted, missing, stray, stale, unknown) with text and symbols, never colour alone. Live board updates through throttled Turbo refreshes per region.
- `bin/rails meridian:demo` seeds 500 servers and 200 apps; the board's first page renders well under 200 ms.

### M2: Deploy and roll back through Git

- Deploy writes the app's version file through the contents API, passing the blob SHA it read, so a concurrent change fails instead of being overwritten. The commit message is `deploy(<app>): <version>` with an `Meridian-Actor` trailer.
- Roll back reverts the newest release's change to the version file.
- Signed GitHub webhooks: `push` syncs the project, `workflow_run` moves deploys from queued to completed. Per-server progress comes from agents.
- A CI workflow template that runs `kamal deploy` for each changed version file (and `kamal remove` on dispatch). Meridian adds it through a pull request.

### M3: New app

- New app form for static (nginx), Node (Next.js `standalone`, port 3000, `/up`), Rails and other apps. It writes a minimal, commented Kamal config and a version file, checks them with Kamal, and opens a pull request. Admins may commit directly when the project allows it.
- Servers are picked by hand or by label selector. The result page lists the manual steps (DNS, tunnel, registry secret) and the Dockerfile for the source repository.
- The app's kind and source repository live in Git as container labels (`meridian.kind`, `meridian.source`).

### M4: Secrets by name

- Secret names come from `env.secret` and `registry.password` in each config. The Secrets page lists them per project, with the apps that use each one.
- Setting or rotating a value seals it with the repository's public key (libsodium) and stores it as an encrypted GitHub Actions secret. The value is never assigned to a model, logged, enqueued or rendered back, and tests check all four.
- Redeploy asks CI to deploy the current version again (`workflow_dispatch`), for example after a rotation. The workflow exports repository secrets so `.kamal/secrets` can read them.

### M5: Previews

- A pull request in an app's source repository commits a Kamal destination overlay, `<config>.pr-<n>.yml`, next to the config. The overlay has its own service name, one server chosen by label selector and the host `pr-<n>.<app>.<preview domain>`. Meridian validates it with Kamal, then asks CI to deploy the pull request's head.
- Pushes to the pull request redeploy it. Closing it, or expiry (7 days by default), asks CI to `kamal remove`, and the overlay is deleted once that run succeeds.
- Previews page with URLs, state and expiry. Previews can be destroyed early.

### M6: Packaging

- Meridian deploys itself with Kamal (`config/deploy.yml`, `.kamal/secrets`). One container: Puma with Solid Queue, behind Thruster.
- All configuration comes from environment variables. HTTPS is forced when `MERIDIAN_URL` is `https://`. Strict Content Security Policy.
- A release workflow publishes `meridian` and `meridian-agent` images for amd64 and arm64 on version tags. CI runs `bin/ci`.
- Mission Control – Jobs is gated to admins even when the app is eager-loaded (production and CI). Before, it inherited from the default controller there, so any signed-in user could reach it.
- Docs for install, configuration, the agent, previews, security (threat model) and Litestream backups. Screenshots are generated by a system test.
