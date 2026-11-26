# Changelog

## Unreleased

### Fixed

- The CI workflow deploys apps with a destination: a change to `deploy/web.production.version` ran `kamal deploy -c deploy/web.production.yml` without `-d production`, which Kamal rejects. It also finds `.yaml` configs, and deploys every version file a push changed rather than only the last commit's. Press **Add CI workflow** on the project page to get the new workflow.
- Deploys of different apps no longer cancel each other in CI. Every push run shared one concurrency group, so a third deploy made while one was running cancelled the second, waiting one. Kamal now runs one at a time per app, for pushes and redeploys alike.
- Only the deploy workflow's runs move deploys along. A lint or test workflow running at the same commit used to overwrite a deploy's status and CI link, and could invent a deploy for an app whose config it touched.
- A late or replayed `workflow_run` delivery no longer moves a finished deploy back to In progress, and an older run no longer takes a deploy over from a newer one, so a redeploy made at another app's deploy commit shows its own result.
- Roll back checks with Git that the release it reverts is still the newest. Clicked before Meridian had synced a newer version (one deployed a moment earlier, say), it reverted the older release and silently replaced the newer version with the one before both. Rolling back the commit that created the version file now says there is nothing to go back to, instead of "GitHub refused the commit: 404".
- Redeploy runs the version in the version file now, read from Git, rather than the newest release Meridian had synced, which could be the version before one that had just landed. Apps without a version file have no Redeploy button: there was no image tag to give Kamal, so it passed the config commit's short SHA.
- Deploying the version already in the version file is refused with a pointer to Redeploy. The commit changed no file, so CI never ran and the deploy showed Pending forever.
- Versions must be Docker image tags (letters, digits, `_`, `.` and `-`, not starting with `.` or `-`). A version such as `--skip-hooks` reached Kamal as a flag in CI, and ones with `+`, `:` or `@` always failed there, since Kamal names containers after the version.
- When GitHub refuses a deploy or rollback commit for a reason other than a stale file, such as branch protection or a repository rule, Meridian shows GitHub's reason. Every 409 and 422 used to read "The version file changed in Git since this page loaded".
- An accessories-only config, such as a tunnel's `deploy/edge.yml`, can no longer be deployed, rolled back or redeployed. Its page offered all three, and CI then ran `kamal deploy` on a file that says never to.
- Webhooks find their project whatever the case of its name. A project added as `Example/Infra` ignored GitHub's `example/infra` webhooks and waited for the 30-second poll.
- Edit connectors refuses any host that isn't plainly a host name. Hosts came from the page's URL and went into the edge config Kamal checks, so a link carrying `<%= … %>` ran Ruby on Meridian's server when an admin opened it.
- Agents must report a plain host name, and New app refuses servers whose hostname isn't one and registries that aren't registry hosts. A hostname such as `web-9<%= … %>`, from any agent token, reached the generated config verbatim (even through a label selector the admin never saw it match), and its Ruby ran on Meridian's server while Kamal checked the config, then in CI once merged. The tunnel setup page leaves out picked hosts that aren't host names.
- New app never overwrites a file. Making `shop` with a destination when `deploy/shop.yml` already existed without one (or the other way round) passed the check, which only compared the same destination, and rewrote the existing app's config without its servers. Any of the new files already in Git, such as a config Kamal can't parse, is now refused too.
- Every connector in a tunnel's edge config gets its own name. The setup page named each after its host's first DNS label, so servers known by IP (`10.0.0.1`, `10.0.0.2`) or sharing one (`web.sgp…`, `web.fra…`) got the same key, and YAML kept only the last: one connector instead of several. Edit connectors names IP connectors after the whole address too, and finds a free `-2`, `-3` suffix instead of reusing one an earlier change took.
- The tunnel setup page asks for a server when none is picked, instead of showing an edge config with no hosts that Kamal rejects.
- A connector or accessory on a server whose agent has gone quiet shows as unknown, as the docs say. It kept the agent's last report, so a dead server's connector showed running and the Tunnels page said every connector was running.
- A tunnel counts an app as served from a connector's server only when one of its kamal-proxy roles runs there. An app whose `job` role alone ran on a connector's server was marked safe to route, though kamal-proxy there answers 404 for it.

## v0.1.0 (2026-11-26)

The first release: the milestones M0 to M6, and everything built on them since.

### Cloudflare Tunnel

- One Cloudflare Tunnel serves every app, the way production runs: an accessories-only `deploy/edge.yml` starts a `cloudflared` connector on each server, all reading `CLOUDFLARE_TUNNEL_TOKEN`, and the tunnel routes each hostname to `kamal-proxy`. Meridian never calls Cloudflare's API. See [docs/cloudflare-tunnel.md](docs/cloudflare-tunnel.md) and decision 33.
- The Tunnels page shows each tunnel's connectors (running, stopped, not started or unknown, with the command that starts a missing one), its token, and which apps it can serve: an app is safe to route only if it runs on every connector's server, and the page names the servers it's missing from.
- **Set up a tunnel** walks through it with the project's own names, generates the edge config for the servers you pick, and ticks off what Meridian can see is done.
- **Edit connectors** (admins) changes which servers run a tunnel's connectors as a pull request or commit to the edge config. It edits the file in place, keeping every other accessory and comment, checks the result with Kamal, and gives the `kamal accessory remove` and `boot` commands to run around the merge.
- An app's page lists its accessories (databases, caches, tunnel connectors) with their image, server, state and the command that starts one that isn't running.
- A config labelled `meridian.kind: accessories` runs no app, so the board leaves it out.
- Settings → General can name previews `pr-<n>-<app>.<domain>`. One wildcard record covers every app, and it works with Cloudflare's free certificate. Existing previews keep their hostname.

### Traffic

- An app's **Traffic** page shows its requests live from kamal-proxy on every server it runs on: status, method, host and path, time taken, the container that answered, and who asked, with the server on each line. Only the app's own requests (previews included) reach the page. See [docs/agent.md](docs/agent.md#traffic) and decision 34.
- kamal-proxy's request lines read the same way in any container's logs.
- New apps in a project with a Cloudflare Tunnel log `Cf-Connecting-Ip`, `Cf-Ipcountry` and `Cf-Ray`, so traffic shows the visitor, their country and the Cloudflare location. See [docs/cloudflare-tunnel.md](docs/cloudflare-tunnel.md#traffic-behind-a-tunnel).

### Live logs

- Open a container's logs, or an app's logs merged across every server it runs on, and read the last 200 lines and then new ones as they're written. Filter, show only stderr, follow or pause, and toggle each server on and off. ANSI colours render.
- Off until an agent runs with `MERIDIAN_LOGS=1` (the accessory template sets it). Only Kamal containers, only deployers and admins, every viewing recorded in Activity, and lines never stored. See decision 32.

### Live stats

- A server's page shows its CPU, memory, load and disk, and every container's CPU, memory, network and disk IO, updating every second while the page is open, with a sparkline, average and peak for each.
- Agents keep one outbound WebSocket to Meridian's `/cable`. Nothing streams until someone opens the page, and the agent stops within 30 seconds of the last viewer leaving. See decisions 30 and 31.
- Mount the host's `/proc` read-only at `/host/proc` for host numbers (the accessory template now does). `MERIDIAN_LIVE=0` turns live stats off.

### Inspector interface

- A new mark: a globe with one meridian drawn on it, in the sidebar, the sign-in page, the favicon (indigo, lighter in dark mode) and `public/icon.png`.
- Meridian's own look, chosen from three mockups: zinc neutrals, one indigo accent, monospace for versions and hosts, dense tables, light and dark, and no shadows. See `docs/design.md`.
- The board is one grid where every cell shows the version a server actually runs, tinted by drift state, with servers grouped under their region. Click an app to open it in a side panel: its servers, recent releases, a deploy form, Redeploy and Roll back, without leaving the board.
- App and server pages use the same layout: content on the left, what you act on in a panel on the right.
- The Map works the same way: click a place to see its servers, the version each app runs there, and the places it shares apps with. Dots show how many servers share a spot and turn purple while a deploy goes out; only places that need you are named, so Europe no longer crowds. App chips filter the map, and the places table lists problems first.
- Fixed: clicking a place on the map made Turbo throw and reload the whole page.
- The sidebar shows names and collapses to an icon rail with « (» brings it back); each browser remembers the choice. Search and the account menu sit in a top bar. On phones the sidebar is a drawer behind a Menu button.
- Built the way 37signals builds Rails apps: plain CSS in `app/assets/stylesheets/` (one file per concern, cascade layers, nesting, `light-dark()`), ERB partials and helpers, and no build step. Tailwind, ViewComponent and Lookbook were tried along the way and removed; see decision 28.
- Light and dark themes: Meridian follows your system, or pick Light or Dark in the account menu; each browser remembers the choice.
- Dropdowns have a Lucide chevron and line up with the inputs around them. In Chrome and Edge the list they open is Meridian's own, drawn like its menus, instead of the system's.
- Install snippets and one-time tokens have a copy button. Servers list their place (city and region) in its own column.
- The board opens on **Needs attention**: plain sentences such as "web isn't running on web-2, but Git says it should". A getting-started checklist appears on new installs, and each app has a one-line status ("✓ Running v42 everywhere").
- `bin/rails meridian:demo` can be run again over an existing demo fleet.
- Keyboard shortcuts are gone for now.
- Icons are [Lucide](https://lucide.dev)'s, vendored in `vendor/lucide` (ISC) and added with `bin/icons <name>`.
- Fixed: on live pages (the Map, the Board), an open Filters panel closed again on the next refresh. Panels you open or close now stay that way.
- The account menu lines up, shows your role, and switches theme with icons. Settings has Workspace and Previews sections, and Jobs lives only in the sidebar. The Agents page puts the install snippet and a new token side by side, with the tokens below; Revoke is quiet until you point at it.
- Error pages (404, 500 and the rest) look like Meridian instead of Rails' defaults (`script/error_pages.rb`).
- Security: creating the first admin needs a setup code from Meridian's log (or `bin/rails meridian:setup_code`), so whoever reaches a fresh deploy first can't take it. A new password signs that person out of every other session. In production Meridian answers only to `MERIDIAN_URL`'s host.
- The project has a code of conduct, issue and pull request templates, and reports vulnerabilities through GitHub's private reporting form.
- OpenID Connect sign-in is gone for now. Sign in with email and password; the `OIDC_*` variables do nothing, and linked identities are deleted.

### World map

- Servers have a latitude and longitude, reported by agents as `lat`/`lng` labels or set by an admin. The Map shows them as places, merged when close together, each marked with its worst drift state.
- Solid arcs link places that run the same app, thicker when they share more. Dotted flows show agent reports arriving at Meridian and deploys going out from it, live. Meridian sees containers, not packets, so it draws only traffic it takes part in.
- Land outlines are Natural Earth's public-domain 1:110m data, projected once into a cached SVG (`script/world_map.rb`).

### Polling

- Meridian works without webhooks: every 30 seconds it reads Git and the branch's recent workflow runs, so deploys made outside Meridian appear and finish. Requests carry ETags, so an unchanged repository costs no GitHub rate limit. Webhooks still make it instant.

### Local lab

- `bin/lab` runs three Docker-in-Docker servers, a registry and a self-hosted GitHub Actions runner, so Meridian can drive real Kamal deploys end to end on one laptop.
- The lab deploys the six real bigint sites from `ghcr.io/bigint/<site>` instead of a placeholder nginx app: `bin/lab push SITE|all [VERSION]` and `bin/lab versions SITE`.
- `GITHUB_TOKEN` can stand in for a GitHub App.
- Fixed: `GITHUB_APP_ID` was read from the wrong variable. Redeploys are tracked like deploys. The CI template runs on self-hosted runners via `MERIDIAN_RUNS_ON`.
- New-app Dockerfiles carry `LABEL service=…`, which Kamal requires of images it didn't build.

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
