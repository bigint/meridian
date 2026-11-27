# Development

This page is for working on Meridian itself. To run Meridian for your fleet, see [Install](../docs/install.mdx). To try it against real Kamal deploys on one laptop, see [Lab](../lab/README.md).

## Set up

You need these on your machine:

| Tool | Version | Used for |
| --- | --- | --- |
| Ruby | `.ruby-version` (`4.0.10`) | The Rails app |
| Go | `agent/go.mod` (`1.27`) | `meridian-agent` and its tests |
| libsodium | any current | Sealing secret values (`brew install libsodium` or `apt install libsodium23`) |
| Node | `20.17` or later | This docs site only. The app has no Node. |

### 1. Install gems and prepare the databases

```bash
bin/setup --skip-server
```

`bin/setup` runs `bundle install`, `bin/rails db:prepare`, then clears logs and `tmp/`. Without `--skip-server` it starts `bin/dev` at the end. Add `--reset` to rebuild the development databases from scratch. It is safe to run again at any time.
### 2. Start the app

```bash
bin/dev
```

`bin/dev` runs `bin/rails server` on port `3000`. Solid Queue runs inside Puma, so there is no second process to start.
### 3. Create your account

Open `http://localhost:3000`. Meridian sends you to `/first_run`, which asks for a setup code. The code is in the server's log as `Meridian setup code: …`, or you can print it:

```bash
bin/rails meridian:setup_code
```
### 4. Connect GitHub

To sync an infra repository, the quickest way is a personal access token:

```bash
GITHUB_TOKEN=github_pat_… bin/dev
```

A GitHub App works too, with `GITHUB_APP_ID` and `GITHUB_APP_PRIVATE_KEY`. See [Environment](../docs/reference/environment.mdx) and [GitHub App](../docs/reference/github-app.mdx).

## Run the checks

`bin/ci` runs every check that must pass before a change lands, in this order. CI runs the same script, then builds the app and agent images.

| Step | Command |
| --- | --- |
| Setup | `bin/setup --skip-server` |
| Style: Ruby | `bin/rubocop` |
| Security: gem audit | `bin/bundler-audit` |
| Security: Brakeman | `bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error` |
| Tests: Rails | `bin/rails test` |
| Agent: vet | `cd agent && go vet ./...` |
| Agent: staticcheck | `cd agent && $(go env GOPATH)/bin/staticcheck ./...` |
| Agent: test | `cd agent && go test -race ./...` |

The steps live in `config/ci.rb`. Staticcheck must be installed once, at the version CI pins:

```bash
go install honnef.co/go/tools/cmd/staticcheck@2026.2.2
```

## Run the tests

```bash
bin/rails test                              # models, requests, channels, jobs, helpers, docs
bin/rails test test/models/drift_test.rb    # one file
bin/rails test test/models/drift_test.rb:12 # one test
cd agent && go test -race ./...
```

The tests are Minitest with fixtures, the Rails defaults. Most are model tests; requests are integration tests, and there are no browser tests. They run in parallel, one worker per processor, in about ten seconds.

- **GitHub is the only thing faked.** WebMock blocks every outside request. `test/test_helpers/github_helper.rb` serves `test/fixtures/files/infra/` as the GitHub API, so a sync runs the real Octokit and Kamal code against it: `stub_github_repo(project)`, then `project.sync`.
- **Kamal parses for real,** in its own process. Each test process keeps what a set of files parsed to (`test/test_helpers/kamal_parse_cache.rb`), so a setup that syncs the same repository costs one parse.
- **Scale has a test.** `build_fleet(servers: 500, apps: 200)` in `test/test_helpers/fleet_helper.rb` inserts a fleet with believable drift, and `test/integration/board_performance_test.rb` checks that the board runs the same number of queries for it as for 40 servers.
- **Secret values have a test.** `test/integration/secrets_test.rb` checks that a value is never stored, logged, enqueued or broadcast.

`test/docs/docs_test.rb` keeps this site in step with the code:

- Every page in `docs/docs.json` has an `.mdx` file, and every `.mdx` file outside `docs/snippets/` is in `docs.json`.
- Every environment variable that `app/`, `config/`, `lib/`, `bin/` or `db/` reads, and every one the agent reads, appears on [Environment](../docs/reference/environment.mdx).
- `CHANGELOG.md` renders as one `<Update>` per release.

## Work on the docs

This site is a [Mintlify](https://mintlify.com) project in `docs/`. `docs/docs.json` holds the navigation, every page is an `.mdx` file, and shared pieces are in `docs/snippets/`. `bin/docs` runs the Mintlify CLI, pinned to `mint` `4.3.96` in the script, through `npx`. It needs Node `20.17` or later.

```bash
bin/docs              # preview at http://localhost:3333 (PORT= to change)
bin/docs check        # what CI checks: validate, broken links, accessibility
bin/docs changelog    # write docs/changelog.mdx from CHANGELOG.md (bin/docs does this anyway)
```

- **Add a page.** Create the `.mdx` file with `title`, `description` and `icon` in its frontmatter, then add its path to `docs/docs.json`. The docs test fails until both exist.
- **Change the changelog.** Edit `CHANGELOG.md`, never `docs/changelog.mdx`. `script/docs_changelog.rb` turns each `## ` release into an `<Update>` and escapes what MDX would read as code. `bin/docs` writes the page before every preview and check, and git ignores it, so only `CHANGELOG.md` is committed.
- **Link between pages** with site paths such as `/guides/deploy`, not file names.

The CI workflow's `docs` job runs `bin/docs check` on Node 22. It checks only and publishes nothing.

The site ships as a container. `docs/Dockerfile` runs `mint export`, which writes the site as static files, and serves them with nginx on port `8080`, with `/up` for kamal-proxy. Build it from the repository root, because the Changelog page comes from `CHANGELOG.md`: `docker build -f docs/Dockerfile -t meridian-docs .`. The Release workflow publishes `ghcr.io/bigint/meridian-docs` with every version tag. `docs/config/deploy.yml` deploys it to `meridian.yoginth.com`. Keep `MINT_VERSION` in the Dockerfile the same as in `bin/docs`.

## Other tools

| Command | What it does |
| --- | --- |
| `bin/icons <name> …` | Vendors Lucide icons into `vendor/lucide`. With no names it downloads every vendored icon again. Map a meaning to the name in `IconsHelper::ICONS`. |
| `bin/kamal-parse` | Parses Kamal configs and prints JSON. Meridian runs it in a clean subprocess; see [Architecture](architecture.md#what-should-run-comes-from-git). |
| `bin/jobs` | Runs Solid Queue on its own, for when `SOLID_QUEUE_IN_PUMA` is `false`. |
| `ruby script/error_pages.rb` | Writes the static error pages in `public/` and `public/error-pages.css`. |
| `bin/rails runner script/world_map.rb ne_110m_land.geojson` | Regenerates `app/assets/images/world.svg` from Natural Earth's land outlines. |
| `bin/lab …` | Runs the local fleet. See [Lab](../lab/README.md). |

The full list of commands is on [Commands](../docs/reference/commands.mdx).

## Contributing

Meridian aims to be small, clear and boring in the best way. The rules are in [`CONTRIBUTING.md`](https://github.com/bigint/meridian/blob/main/CONTRIBUTING.md):

- **Read the principles.** A change that makes Meridian run Kamal itself, connect to servers, or keep secret values won't be merged.
- **Vanilla Rails.** Rich models with concerns, thin CRUD controllers, Hotwire. No Node, no JavaScript bundler, no service objects.
- **Plain CSS, partials and helpers.** No CSS framework, no component library, no build step. Reuse the helpers and classes described in [Design](design.md) before adding new ones, and never use inline `style` attributes.
- **Icons come from Lucide.** Add one with `bin/icons <name>`. Don't draw new ones.
- **Prefer deleting code to adding it.** The only planned abstraction is the Git host adapter, `app/models/git_host.rb`.
- **Every change keeps `bin/ci` green.** A change in behaviour comes with a test: a model test first, an integration test for a request, never a browser.
- **Examples use `example.com` and documentation IP ranges.** Never commit real hostnames, IPs, tokens or anyone's infrastructure.
- **When a choice is ambiguous,** pick the simplest option that keeps Git as the record, and add one short entry to [Decisions](decisions.md).

Use small conventional commits, such as `feat(board): …`, `fix(agent): …` or `docs: …`. Add a line to `CHANGELOG.md` under `## Unreleased` for anything a user would notice. The pull request template asks for the same three things: `bin/ci` passes, a changelog line, and no real infrastructure.

## Release

A release is a Git tag. Pushing a tag that starts with `v` runs `.github/workflows/release.yml`, which builds three images for `linux/amd64` and `linux/arm64` and pushes them to the GitHub Container Registry:

| Image | Built from | Tags |
| --- | --- | --- |
| `ghcr.io/<owner>/meridian` | `Dockerfile` | the tag, and `latest` |
| `ghcr.io/<owner>/meridian-agent` | `agent/Dockerfile` | the tag, and `latest` |
| `ghcr.io/<owner>/meridian-docs` | `docs/Dockerfile`, from the repository root | the tag, and `latest` |

The workflow passes the tag as the `VERSION` build argument to the app and the agent. The app's `Dockerfile` bakes it into `MERIDIAN_VERSION`, which the account menu shows, and the **Agents** page uses it as the agent's image tag. The agent's `Dockerfile` stamps it into the binary, which reports it as its agent version. The docs image takes no version.

### 1. Name the release in the changelog

In `CHANGELOG.md`, rename `## Unreleased` to the version and date, for example `## v0.2.0 (2027-01-15)`, and start a new empty `## Unreleased` above it if there is more to come.
### 2. Bump the pinned versions

The docs and the README name the current release by hand. Before tagging, find the previous tag wherever it appears and replace it with the new one:

```bash
git grep -nF "$(git describe --tags --abbrev=0)" -- README.md docs .github
```

That covers `README.md`, `docs/index.mdx`, `docs/install.mdx`, `docs/quickstart.mdx`, `docs/guides/agent.mdx`, `docs/operate/upgrading.mdx`, `docs/reference/agent-protocol.mdx` and the bug report template. Leave `CHANGELOG.md` alone.
### 3. Commit, tag and push

```bash
git commit -am "chore(release): v0.2.0"
git tag v0.2.0
git push origin main v0.2.0
```

Then upgrade your own install as [Upgrading](../docs/operate/upgrading.mdx) describes.
