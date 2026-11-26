# Dead and unwanted code audit — 2026-11-26

Ten read-only agents swept the repo; high-confidence items were spot-checked by grep afterwards.
Items reported by more than one agent are merged. Confidence: **H** high, **M** medium, **L** low.

## 1. Dead code (no callers anywhere)

| Where | What | Conf |
|---|---|---|
| app/models/app.rb:31 | `App#container_prefix` (+ its comment) — only match elsewhere is Kamal's own method in bin/kamal-parse | H |
| app/models/board.rb:18 | `Board::Group#key` | M |
| app/models/world_map.rb:132 | `WorldMap#hub_label` | H |
| app/models/world_map.rb:133 | `WorldMap#label(site)` | H |
| app/models/placement.rb:8 | `scope :unhealthy` | H |
| app/models/server.rb:15 | `scope :located` (callers use `select(&:located?)`) | H |
| app/models/project.rb:6-7 | `has_many :assignments, through: :apps` / `has_many :servers, through: :assignments` | H |
| app/models/project/changes.rb:6 | `Proposal#branch` field never read | H |
| app/models/server.rb:5,8,9 | `has_many :agent_tokens` never read; `dependent:` options on assignments/placements/agent_tokens never fire (servers are never destroyed) | M |
| app/controllers/concerns/authentication.rb:6,16-18 | `authenticated?` + `helper_method :authenticated?` (generator leftover) | H |
| app/controllers/servers_controller.rb:14 | `@assignments` set (with an `includes` query) but never read by the view | H |
| config/routes.rb:35 | `resource :session` generates `show/edit/update` routes with no actions; `edit_session_path` unused → `only: %i[ new create destroy ]` | H |
| app/helpers/icons_helper.rb:10 + vendor/lucide/external-link.svg | `ICONS[:external]` never rendered | H |
| app/helpers/application_helper.rb:139/147 + blocks.css:86 + vendor/lucide/circle-check.svg | `ALERT_ICONS[:ok]`, `.alert--ok`, and its icon — `alert_box :ok` is never called | M |
| app/views/maps/show.html.erb:12 | `data-map-chips` attribute — nothing reads it | H |
| app/views/previews/index.html.erb:28 | `data-preview-state` attribute — nothing reads it | H |
| config/locales/en.yml:31 | `en.hello: "Hello world"` | H |
| public/icon.png | not referenced (layouts use icon.svg) | H |

## 2. Used only by tests

| Where | What | Conf |
|---|---|---|
| app/models/deploy.rb:56 | `Deploy#rollback?` (helpers compare `kind == "rollback"`) | H |
| app/models/app_draft.rb:31 | `attr_writer :project` | M |
| app/models/secret_name.rb:13 | `scope :ordered` (view sorts in Ruby instead) | H |
| app/models/world_map.rb:139,145,147 | `labels` no-arg path / `keys.nil?` branches | M |
| app/helpers/boards_helper.rb:73 | `server.try(:short_name) \|\| server.name` fallback — only Struct fakes hit it | L |
| app/controllers/boards_controller.rb:10 | `:app` filter param — no form/link sends it | L |
| agent/snapshot.go:127-132 | nil-defaulting of `Labels`/`Containers` in `encodeCapped` | M |

## 3. Unreachable / always-true branches

| Where | What | Conf |
|---|---|---|
| app/models/app_draft.rb:131 | `\|\| project.nil?` — presence validation already failed first | M |
| app/models/board.rb:87 | `if LABELS.include?(key)` — always true (keeps as SQL guard?) | L |
| app/controllers/apps_controller.rb:10 | `params[:project_id] \|\|` — no link passes it | M |
| app/views/boards/_matrix.html.erb:5,35-39 | `inspectable` local + `else` branch — sole caller passes `true` | H |
| app/helpers/application_helper.rb:36 | `labels_list(except: [])` default never used | L |
| agent/snapshot.go:102-105 | second `classify` after inspect | L |
| agent/snapshot.go:108-110 | `c.Image = l.Image` fallback | L |
| agent/ws.go:244 | `writeClose` error return always discarded | L |
| agent/line.go:38-44 | `lineDialing/Subscribing/Backoff` states only feed a debug log | L |

## 4. Agent ↔ Rails protocol: produced but never consumed

| Where | What | Conf |
|---|---|---|
| agent/snapshot.go:28, agent/proxy.go:11-83, agent/config.go:23,38, agent/snapshot.go:151, agent/testdata/proxy-state*.json, agent_test.go:225,285-338, agent/README.md, docs/agent.md | **Whole `proxy_routes` feature**: agent reads kamal-proxy state and sends it; `Snapshot#to_job` never reads it. `MERIDIAN_PROXY_STATE` is documented but has no effect. | H |
| app/models/live_stats.rb:6 | `disk_read` / `disk_write` forwarded to browsers; JS never uses them | M |

## 5. Database

**Write-only / never-read columns**
- `deploys.started_at`, `deploys.finished_at` (schema.rb:82-83) — M/H
- `placements.observed_at` (121) — H
- `placements.image`, `placements.destination` (116, 114) — read only by `Snapshot::SHOWN`, so they trigger board refreshes for nothing no page shows; `SHOWN` comment is wrong — M
- `events.subject_type/subject_id` + `belongs_to :subject` (97-98, event.rb:4) — maybe kept for audit — M
- `sessions.ip_address/user_agent` (206-207) — generator default — L/M
- `accounts.name` (15) — editable, never displayed — M

**Schema drift**
- `accounts.name` default is `"Alidade"` in schema.rb but `"Meridian"` in the migration — `db:migrate` and `db:schema:load` disagree — H (verified)

**Redundant indexes** (prefix of a composite index, or no query uses them)
- `index_apps_on_project_id` (56), `index_assignments_on_app_id` (67), `index_deploys_on_app_id` (88), `index_placements_on_server_id` (124), `index_previews_on_app_id` (141), `index_releases_on_app_id` (172), `index_secret_names_on_project_id` (185) — H
- `index_deploys_on_ci_run_id` (89), `index_placements_on_service_and_role_and_destination` (125) — H
- `index_events_on_action` (101 — LIKE can't use it), `index_events_on_subject` (104) — M

**Migrations**
- `identities` table created in 20261125180000 and dropped in 20261126120000_drop_identities.rb — squashable — H

## 6. Duplicate logic

- app/models/board.rb:24,50 + drift.rb:32,36 — attention order defined 3 times, **inconsistently** (`Drift.worst` puts stale before stray) — M, possible bug
- app/views/apps/show.html.erb:6-7 — re-implements `BoardsHelper#app_cells` without `.compact` — M
- app/controllers/agent_tokens_controller.rb:13-15 — index queries copied into `create` — M
- apps/deploys_controller.rb:11-15 & apps/rollbacks_controller.rb:11-15 — identical `GitHost` rescue blocks — L
- config/routes.rb:38-39 — `settings root` and `resource :account` both reach `accounts#show` — L
- app/models/account.rb:8 — `located?` + lat/lng validations duplicated in server.rb — L
- app/models/board.rb:124 vs world_map.rb:160 — `stream_keys` — L
- app/models/app/deployable.rb:18 — version regex also in app_draft.rb:28, _inspector.html.erb:17, _deploys.html.erb:7 — L
- app/models/release.rb:7 `short_sha` vs `ApplicationHelper#short_sha`; release.rb:11 / placement.rb:14 `short_version` — L
- app/channels/server_stats_channel.rb:4 `RENEW_EVERY = 10s` vs `LiveStats::RENEW_EVERY = 5s` (same name, different meaning) — L
- app/models/preview.rb:93-97,114 — `server` not memoized, re-queried per role in `overlay` — M
- agent/agent.go:117-127 `nextDelay` ≈ line.go `retryDelay`+`jittered` — H
- agent/agent.go:39-45 timer wait ≈ `sleepCtx` — M
- agent/agent.go:50-54 recover ≈ line.go:182-186 — L
- agent/hostmetrics.go:13 `/host/etc/hostname` also in config.go:31 — L
- CSS: collapsed-sidebar rule = `.sr-only` (layout.css:126); `.panel__title` = `.page-header__title` (layout.css:204); `select:open` = `:focus` (base.css:94); uppercase label style ×5; `.sidebar__label` = `.truncate` (layout.css:87) — L

## 7. Unused parameters

app/models/git_host/github.rb — `head_sha(branch)` :29, `workflow_runs(branch:, limit:)` :34, `commits(ref:)` :48, `delete_file(branch:)` :70, `create_pull_request(base:)` :83, `dispatch_workflow(ref:)` :100 — no caller passes them — L

## 8. CSS / markup mismatches

**Unused classes:** `.items-end` (utilities.css:10), `.justify-between` (:11), `.grid-2--wide` (:23), `.txt-xsmall` (:33), `.alert--ok` (blocks.css:86) — H

**Classes in markup with no CSS:** `container-cell`, `container-cell__title` (servers/show:67-68), `live__note` (servers/_live:27), `world__flows` (maps/_world:22), `place` (maps/_world:49), `kind` (jumps/show:9 — test hook) — M/H

Cosmetic: double blank line layout.css:151.

## 9. Tests

- Unused helpers: `SessionTestHelper#sign_out`; `stub_github_repo(dir:)`; `sign_in(password:)` — H
- ~~`ActiveJob::TestHelper` in application_system_test_case.rb:7~~ (wrong: SystemTestCase is not an IntegrationTest, removing it breaks 10 system tests). Redundant includes: `include GitHubHelper` in system/new_app_test.rb:5, preview_test.rb:5, rollback_test.rb:5 — H
- Hand-rolled `with_cache` duplicating MemoryCacheHelper: models/board_test.rb:41, models/project_poll_test.rb:59 — M
- Stale stubs: deployable_test.rb:59 `stub_github_writes`; preview_test.rb:31 `stub_request(:delete…)`; workflow_test.rb:37 repeats setup stub — H
- No-op `Rails.cache.clear` (null store): system/live_board_test.rb:31, live_stats_test.rb:116 — M
- Vacuous: live_stats_test.rb:78 screenshot "test"; screenshots_test.rb:10 (skipped unless ENV); world_map_test.rb:92 conditional assertion (also below `private`) — L/M
- Mislabelled: secrets_test.rb:67 title says viewers, only deployers tested — L
- Duplicates: jump_test.rb:25-29 vs shell_test.rb; `deliver` copied in 3 system tests (one missing 202 assert); `ingest`/`use_async_cable`/`restore_cable` byte-identical in 2 files; color-scheme emulation ×3 — M/L
- Minor: sessions_controller_test.rb:26 refetches `User.take`; git_hub_token_test.rb misnamed (tests `GitHost::GitHub.token_mode?`) — L

## 10. Config, boilerplate, Docker

- config/initializers/inflections.rb — whole file is comments — M
- config/bundler-audit.yml:4-5 — `CVE-THAT-DOES-NOT-APPLY` placeholder — H
- config/queue.yml:14-15, config/cache.yml:12-13 — `test:` blocks never read — M
- config/cable.yml:1-4 — stale async-adapter comment — M
- config/application.rb:29 — `ignore: %w[assets …]` but no lib/assets — L
- Dockerfile:6 — run example uses `RAILS_MASTER_KEY`; no credentials exist — H; Dockerfile:54 matching stale comment — M; Dockerfile:8 devcontainer pointer, 56-59 blank lines — L
- Dockerfile:27 — `BUNDLE_WITHOUT="development"` ships test gems in prod image — L
- .github/workflows/release.yml:36 — `VERSION` build-arg ignored by root Dockerfile — L
- Commented generator boilerplate (L): en.yml:1-28; assets.rb:6-7; cache.yml:3-4; application.rb:8,10-12,26-28,30-38; development.rb:58-59,64-65,70-71; production.rb:21-22; test.rb:34-38; puma.rb:1-27; application_job.rb:2-6; bin/setup:18-21; Rakefile:1-2; deploy.yml:33-36 (intentional opt-in)

## 11. Stale docs, assets, ignore files

**Stale docs**
- README.md:43 — "click the name in the top bar" (search box replaced it) — H
- docs/install.md:58 — "four marked lines" (deploy.yml has five) — H
- docs/architecture.md:8 — `workflow_job` webhook (not handled) — H (verified)
- docs/architecture.md:20 — sync fetches `.kamal/secrets*` (it doesn't) — H
- docs/architecture.md:35 — `Assignment#drift` (doesn't exist) — H
- docs/architecture.md:65 — deploy progress "from job steps" (comes from agents) — H
- docs/design.md:29 — CSS table missing live.css — M
- docs/agent.md:37 — "New token" (button is "Create token") — M
- CHANGELOG.md:51 — lab has "three" servers (it has 21) — M
- docs/configuration.md — region grouping rule incomplete — L
- lab/README.md — `bin/lab ssh` undocumented — L
- agent/README.md + docs/agent.md — `MERIDIAN_PROXY_STATE` (see §4) — H

**Orphan screenshots** (only board.png / board-dark.png are linked): docs/screenshots/{activity,app,map,search,server}{,-dark}.png — 10 files — M

**Stale ignore entries** (L): .gitignore:13 `/node_modules/`, :15 `/coverage`, :4-5 master.key/credentials; .dockerignore:34 `/node_modules/`, :35-36 `app/assets/builds` (M, Tailwind leftover), :47 `/.devcontainer`, tmp/pids + tmp/storage entries

**Redundant .keep files** (dir already has files): app/assets/images, app/controllers/concerns, lib/tasks, script, test/controllers, test/fixtures/files, test/helpers, test/integration, test/models, vendor — H

## Clean areas

All gems used; all Stimulus controllers/actions/targets wired; importmap pins used; all CSS vars used; all stylesheets loaded; no orphan partials/templates/layouts; all jobs enqueued or scheduled; channels subscribed and broadcast; lib, templates, bin, script, lab all referenced; fixtures and seeds clean; `go vet` and `staticcheck -checks all` report nothing.
