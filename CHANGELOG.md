# Changelog

## Unreleased

### Removed

- GitHub webhooks. Meridian learns of pushes and CI runs only by polling GitHub every 30 seconds, as it already did without them. `POST /webhooks/github`, `GITHUB_APP_WEBHOOK_SECRET`, the **Webhooks** row under **Settings → Connections** and `bin/lab webhooks` are gone. GitHub no longer needs to reach Meridian, so in the App's settings untick **Webhook → Active**. See decision 44.

## v0.1.2 (2026-11-27)

### Fixed

- Projects sync again. In the production image every sync failed with `NameError: uninitialized constant KamalConfig::Open3`, because the config parser used Ruby's `Open3` without requiring it, so no app ever reached the board. CI now parses a Kamal config inside the built image.

## v0.1.1 (2026-11-27)

### Removed

- The demo fleet. `bin/rails meridian:demo` and its `SERVERS` and `APPS` settings are gone, and the Quickstart now points Meridian at your own infra repository with a `GITHUB_TOKEN`. The development seed user is `admin@example.com` / `admin-password-123`.
- Pull request previews. The **Previews** page, the **Previews** settings, the CI workflow's `remove` command and the `preview.*` activity events are gone, and Meridian no longer needs the **Pull request** webhook event. The `previews` table and the account's preview columns are dropped. See decision 43.
- Roles and People. Meridian is single-user: the one account, made at first run, can do everything, and every button shows. The viewer, deployer and admin roles, the `users.role` column, **Settings → People**, the Settings tabs, Activity's **Who** filter and the `user.created` and `user.removed` events are gone, and direct commits depend only on the project's setting. Change your name, email address and password under **Settings → Your account**; saving records `user.updated`, and a new password signs you out everywhere else.

### Fixed

- A server's page refreshes live even when nothing of it is on the board yet, such as a database host that runs only accessories. It listened only to the regions of its board cells, so with none it waited on a stream nothing sent to.
- Open boards, maps and server pages always get the last change. The once-a-second refresh dropped every change after the first in each second, so a server that reported its new version just after a refresh went out stayed drifted on screen until something else changed. A server whose region label changes is now refreshed in the region it left too.
- The map groups servers into one place only within 60 km, one metro area. The threshold was six map units, about 240 km, so Amsterdam and Brussels became one place named after one of them.
- The board's header says "all matching Git" only when every cell was compared and is in sync. With no agent reporting yet, or apps without a version file, every cell was unknown and the header still said everything matched.
- A board page number past the last shows the last page. A very large one, such as `?page=100000000000000000000`, answered 500.
- A map app chip shows that app only. The `web` chip also drew `webhooks` and any other app whose name contains `web`, and the chips listed accessories-only configs, such as a tunnel's `edge`, that the map never draws.
- A container whose version the agent couldn't read shows on the board: running where Git doesn't put it, it was left out instead of shown as stray. A quiet server's cell no longer prints Git's version when its agent last reported nothing running there.
- The Apps page reads every app's newest release in one query, instead of one query per app (200 at the target size).
- Search always shows the best match. It took the first eight names of each kind alphabetically before ranking, so with eight servers such as `a1-db-1` before it, searching `db-1` never showed the server called `db-1`.
- Search finds names with `_` or `%` in them: the top-bar search, the Apps and Servers searches, the board's app filter and the Activity page's action filter. SQLite's LIKE has no escape character unless told, so `my_app` matched nothing. The Apps and Servers searches also no longer fail on a `q` that isn't text.
- A server's page lists every app on it. It showed the board's first page, so a server running more than 25 apps silently left the rest out of its Apps table and count.
- An app's status line says "✓ Running v42 everywhere" only when no server runs another version or has a role down. A server still running a v41 container beside v42 counted as running v42, while its cell showed drifted.
- The board checks each role Git assigns to a server. A cell with a running `web` container showed in sync while the `job` container Git also put there was stopped, so the dead worker never reached Needs attention; a role running where Git doesn't put it now shows as stray.
- The CI workflow deploys apps with a destination: a change to `deploy/web.production.version` ran `kamal deploy -c deploy/web.production.yml` without `-d production`, which Kamal rejects. It also finds `.yaml` configs, and deploys every version file a push changed rather than only the last commit's. Press **Add CI workflow** on the project page to get the new workflow.
- Deploys of different apps no longer cancel each other in CI. Every push run shared one concurrency group, so a third deploy made while one was running cancelled the second, waiting one. Kamal now runs one at a time per app, for pushes and redeploys alike.
- Only the deploy workflow's runs move deploys along. A lint or test workflow running at the same commit used to overwrite a deploy's status and CI link, and could invent a deploy for an app whose config it touched.
- A late or replayed `workflow_run` delivery no longer moves a finished deploy back to In progress, and an older run no longer takes a deploy over from a newer one, so a redeploy made at another app's deploy commit shows its own result.
- Roll back checks with Git that the release it reverts is still the newest. Clicked before Meridian had synced a newer version (one deployed a moment earlier, say), it reverted the older release and silently replaced the newer version with the one before both. Rolling back the commit that created the version file now says there is nothing to go back to, instead of "GitHub refused the commit: 404".
- Redeploy runs the version in the version file now, read from Git, rather than the newest release Meridian had synced, which could be the version before one that had just landed. Apps without a version file have no Redeploy button: there was no image tag to give Kamal, so it passed the config commit's short SHA.
- A redeploy whose workflow GitHub can't find says so. GitHub's 404 was ignored, so with no `meridian-deploy.yml` on the default branch a redeploy was recorded though nothing ran.
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
- New app refuses a service name another config in the project already uses (with the same destination) and a hostname another app already serves. Both passed, since only the config path was checked, and the two apps then fought over the same containers or kamal-proxy host.
- A New app label selector with a term that isn't `key=value` (`web`, or a leading space) is a form error. It raised and the page answered 500.
- New app writes its config where the project's config paths find it. A `deploy/**/*.yml` glob gave the literal path `deploy/shop*/*.yml`, and a project whose paths had no `*` got `config/deploy-shop.yml`, which sync then ignored; the form now says so instead.
- New app's port must be a TCP port, 1 to 65535. Ports such as 0, -1 or 70000, and text (read as 0), were proposed and Kamal accepted them.
- A config that fails to parse keeps its app. Sync used to destroy it, with its deploy history and releases, and unlinked its containers, so the board showed its containers as stray until the typo was fixed and the app came back with a new id.
- Sync reads everything it needs from GitHub before it opens its database transaction. Commit history and version files were fetched inside it, so a first sync of many apps held SQLite's only write lock for minutes and snapshots and sign-ins failed meanwhile.
- A config that references a secret GitHub can't store, such as `GITHUB_TOKEN`, no longer stops the project syncing. The name failed validation, which rolled every sync back, so nothing in the repository changed in Meridian again and no error showed.
- A secret name added by hand on the Secrets page without a value survives the next sync, which deleted it. A name that was set and that no config references any more says so, instead of listing the apps that used to.
- Secret names are recorded from the apps a sync just wrote. When a push landed during a sync job, its second sync read the first one's apps from memory and missed new names until the next push.
- A repository tree GitHub cuts short (it truncates trees of more than about 100,000 files) stops the sync. It was read as whole, so every config past the cut looked deleted and its app was destroyed.
- One config that prints, hangs or kills the parser no longer stops the whole project syncing with no error shown. Output from ERB goes to stderr instead of corrupting the parser's answer, and a timeout or crash is shown on the project page while every app stays as it was.
- Taking `meridian.source` or `meridian.kind` out of a config clears it in Meridian. The old values stuck, so an app kept a source repository the config no longer named, and an app once labelled `accessories` stayed off the board.
- Saving a project with new config paths, branch, repository or installation syncs it at once. The scheduled sync skips a repository whose head hasn't moved, so the new paths took effect only after the next push or a press of Sync now.
- A YAML syntax error in a destination file is reported against that file. It named the base config, with the destination file's line number, and linked to the wrong file.
- A `.yaml` file next to a config, such as `deploy/web.staging.yaml` beside `deploy/web.yml`, is no longer taken for a destination file, which made every sync fail looking for `deploy/web.staging.yml`. Like Kamal, Meridian reads only `<config>.<destination>.yml` as a destination, and now finds it for a `.yaml` config too.
- The newest release is the commit that landed on the branch last. Releases were ordered by author date, so a version bump written on a branch and rebased or merged after a newer deploy counted as older: the board showed every server as drifted, and Roll back offered the wrong release.
- The agent's accessory template keeps the Docker socket proxy off Kamal's `kamal` network. Every app container on a server could reach it there and read every container's environment variables, files and logs through it. The proxy and the agent now share a `meridian` network of their own. See Upgrading below.
- The agent never sends Docker API calls through `HTTP_PROXY`. With one set to reach Meridian, every inspect response, environment variables included, went through that proxy too.
- One container can't crowd out the other containers' logs on its server. Blank and short lines cost nothing against the agent's 512 KB a second, and full batches went out at once, so one container could send about 200 batches a second and Meridian dropped that server's batches past 100. Each line now costs 64 bytes on top of its text, and a container sends at most one batch per 250 ms.
- A running container's logs no longer say "Container stopped" after 10 quiet minutes. The socket proxy closes idle streams, and the agent took that for the container stopping. It now reopens the stream from its last line, and reports a stop only when the container has stopped.
- A watch lease with a huge negative length no longer keeps live stats streaming for centuries.
- A server is stale after three of its agent's intervals, and never sooner than 45 seconds. Snapshots now carry `interval_seconds`; older agents count as 15. An agent with a 60-second interval used to show stale between every snapshot.
- After a 429 the agent waits at least as long as `Retry-After` says, up to 5 minutes and jittered, instead of coming back on its own backoff.
- Fleet tokens are rate-limited per server. Every server on one fleet token shared 120 snapshots a minute.
- Snapshots over 1 MiB are refused before Rails parses them, with or without a valid token.
- A per-server token used on a second machine is refused with 422 and the reason. It was accepted and the snapshot silently dropped.
- Snapshot bodies that aren't JSON objects, or whose labels aren't one, are refused with 422 instead of a 500 or a job that always fails.
- An agent reporting an IP address no longer claims another IP's server by its first octet: `10.0.0.9` could take `10.0.0.5`'s server.
- A server an agent created before Git listed its host is taken over by Git's host name, instead of leaving a second server that never reports.
- A rebuilt machine (a new machine id) takes back the server Git places once the old agent has been silent for 10 minutes and is stale: on a fleet token when it reports Git's exact host (set `MERIDIAN_HOSTNAME`), on a per-server token whatever its hostname. It used to get a new server of its own.
- Finished Solid Queue jobs are no longer kept for a day. Snapshot jobs grew the queue database by gigabytes a day.
- A revoked agent token can no longer subscribe on a cable it opened before the revoke.
- Revoking an agent token hangs up its open cables at once, instead of within a minute.
- A laptop asleep or a dropped network no longer keeps an agent streaming for many minutes. The page renews its leases itself, and a page silent for 75 seconds lets them lapse.
- A client can no longer run a channel's `subscribed` again as an action, which piled up cable listeners that never went away.
- Demoting, removing or signing out a user ends the logs, traffic and stats streams they already had open.
- Logs and traffic stream only what a page recorded in Activity. Subscribing over the cable directly read logs with no record.
- Traffic keeps requests whose kamal-proxy line repeats a key, as logging `Content-Type` does.
- A JSON log line whose values carry their own `toString` no longer makes the viewer drop that frame's lines.
- A long-open logs page with many containers no longer remembers twenty times the lines it shows.
- Signing in after a session ended goes back to the page you were on, never to a form's POST URL or a bare search frame.
- A sign-in missing its email or password is a failed sign-in, not an error page.
- Removing a user who deployed, set a secret or appears in Activity no longer fails.
- The board's state chips, grid toggle and pages, and Activity's pages, no longer follow `?host=`, `?protocol=` or `?script_name=` to another site, and `?controller=` no longer breaks them.
- Activity takes a repeated `action_name` or `page` parameter as text instead of raising.
- A secret set by someone since removed says "by a removed user" instead of trailing off.
- A live refresh keeps what you are typing (a search, a version to ship, unapplied filters) and the search's results, instead of wiping them.
- Copy works over plain HTTP: with no clipboard API it selects the text and says to press ⌘C or Ctrl+C.
- Enter in the search opens a match for what the box says now, never an older query's, and a reply arriving after Escape no longer refills the list.
- The "Browser too old" page is styled again. The error pages' styles moved to `public/error-pages.css`, which the CSP allows.
- A head whose configs hang or crash the parser is tried again: after a minute, then two, four and so on, at most hourly, until it parses or the next commit lands, with the error on the project meanwhile. It was marked synced, so a parser that had only timed out kept the head unread, with its releases and deploys, until the next commit.
- A redeploy shows the version it ran from the moment it is asked for, and its Redeploy button and confirmation name the version file rather than the last synced release. Its deploy was labelled with the newest release Meridian had synced, so after a version had just landed it showed the one before, and never finished on servers running the new one.
- Two Git hosts that share a first DNS label (`web-1.sgp…` and `web-1.fra…`) no longer both take the one agent's server that reported before Git listed them, which swapped the two machines for good.
- A silent server is reclaimed only by an agent reporting its exact hostname or name, and only once it is stale as well as silent for 10 minutes. A new machine sharing just the first DNS label could take a server while it was down.
- A fleet token is capped at 12,000 snapshots a minute in all. It was limited only per machine id, which the snapshot names, so new ids meant no limit.
- An Activity page number past the last, however large, shows the last page instead of a 500.
- The agent drops and counts live log lines that come faster than one full batch (500 lines) per 250 ms, instead of falling ever further behind Docker without saying so. History still arrives whole.
- A Logs or Traffic page's grant to stream lapses after 12 hours. A page still open then says "Stopped: reload the page to keep reading" instead of "Connecting…" forever.
- A form that is sent and redirects back to the same page takes the server's values again (the version box empties after a deploy), while text typed during a live refresh is still kept.
- The agent template on the Agents page boots its two accessories with one `kamal accessory boot` each, since the command takes one name, and says that `roles: [ web ]` boots them on web hosts only.
- An unknown cell on the board shows `–`, the mark the badges, chips and docs give unknown, instead of `?`, which is the mark for stray.
- New app shows a missing or unknown infra repository under the **Infra repository** field as well as at the top of the form. The field looked for the error on `project_id`, while it is on `project`.
- The Logs page's notice for dropped lines reads "N lines skipped: logged faster than the agent sends". It said "over 512 KB/s", but the agent also drops live lines past 500 in 250 ms, whatever their size.
- The board's side panel (`/?inspect=<id>`) for an accessories-only config shows no Deploy form, Redeploy or Roll back, as its app page already doesn't. Each could only fail.
- The agent's README gives its binary as about 7 MB and its image as about 3.5 MB compressed. It gave 3.5 MB alone, which read as the size of the binary.
- A deploy by someone since removed says who it was in **Current deploy**, with `(removed)`, as Activity does. It said "By Git". Deploys keep the name of the person who asked for them, and existing ones take it from their person or from Activity.
- With `GITHUB_API_URL` set for GitHub Enterprise, links to repositories, commits and files go to that server, such as `https://github.example.com` for `https://github.example.com/api/v3/`. They always went to `github.com`.

### Upgrading

- Every user that exists when you upgrade can still sign in, and can now do everything. Settings no longer lists or removes people, so before you upgrade, remove anyone who shouldn't have that access under **Settings → People**.
- Before you upgrade, press **Destroy** on each preview on the **Previews** page, and wait until it leaves the list. This release can't remove a preview. Meridian now reads a leftover `<config>.pr-<n>.yml` as a destination like any other, so delete any that stay in the infra repository.
- In each existing infra repository, press **Add CI workflow** on the project page again. The new workflow deploys destination apps with `-d` and runs one deploy per app at a time.
- On each host, create the `meridian` Docker network once, add `network: meridian` to both agent accessories (`meridian_docker` and `meridian_agent`), then reboot them:

  ```bash
  kamal server exec "docker network inspect meridian >/dev/null 2>&1 || docker network create meridian"
  kamal accessory reboot meridian_docker
  kamal accessory reboot meridian_agent
  ```

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
