# Development

This page is for working on Meridian itself. To run Meridian for your fleet, see [Install](../docs/install.mdx). To try it against real Kamal deploys on one laptop, see [Lab](../lab/README.md).

## Set up

You need these on your machine:

| Tool | Version | Used for |
| --- | --- | --- |
| Ruby | `.ruby-version` (`4.0.10`) | The Rails app |
| Go | `agent/go.mod` (`1.27`) | `meridian-agent` and its tests |
| libsodium | any current | Sealing secret values (`brew install libsodium` or `apt install libsodium23`) |
| Chrome | any current | System tests and screenshots |
| Node | `20.17` or later | This docs site only. The app has no Node. |

### 1. Install gems and prepare the databases

```bash
bin/setup --skip-server
```

`bin/setup` runs `bundle install`, `bin/rails db:prepare`, then clears logs and `tmp/`. Without `--skip-server` it starts `bin/dev` at the end. Add `--reset` to rebuild the development databases from scratch. It is safe to run again at any time.
### 2. Seed a demo fleet (optional)

```bash
bin/rails meridian:demo
SERVERS=50 APPS=20 bin/rails meridian:demo
```

The task seeds a demo project with 500 servers and 200 apps by default, with realistic drift, so every page has something to show without GitHub or agents. You can run it again over an existing demo fleet.
### 3. Start the app

```bash
bin/dev
```

`bin/dev` runs `bin/rails server` on port `3000`. Solid Queue runs inside Puma, so there is no second process to start.
### 4. Create the first admin

Open `http://localhost:3000`. Meridian sends you to `/first_run`, which asks for a setup code. The code is in the server's log as `Meridian setup code: …`, or you can print it:

```bash
bin/rails meridian:setup_code
```
### 5. Connect GitHub (optional)

The demo fleet needs no GitHub. To sync a real infra repository, the quickest way is a personal access token:

```bash
GITHUB_TOKEN=github_pat_… bin/dev
```

A GitHub App works too, with `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY` and `GITHUB_APP_WEBHOOK_SECRET`. See [Environment](../docs/reference/environment.mdx) and [GitHub App](../docs/reference/github-app.mdx).

## Run the checks

`bin/ci` runs every check that must pass before a change lands, in this order. CI runs the same script, then builds the Docker image.

| Step | Command |
| --- | --- |
| Setup | `bin/setup --skip-server` |
| Style: Ruby | `bin/rubocop` |
| Security: gem audit | `bin/bundler-audit` |
| Security: importmap audit | `bin/importmap audit` |
| Security: Brakeman | `bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error` |
| Tests: Rails | `bin/rails test` |
| Tests: System | `bin/rails test:system` |
| Agent: vet | `cd agent && go vet ./...` |
| Agent: staticcheck | `cd agent && $(go env GOPATH)/bin/staticcheck ./...` |
| Agent: test | `cd agent && go test -race ./...` |

The steps live in `config/ci.rb`. Staticcheck must be installed once:

```bash
go install honnef.co/go/tools/cmd/staticcheck@latest
```

## Run the tests

```bash
bin/rails test                      # models, controllers, jobs, channels, integration, docs
bin/rails test:system               # browser tests in headless Chrome
bin/rails test test/models/drift_test.rb:12
cd agent && go test -race ./...
```

Tests run in parallel, one worker per processor. Outside requests are blocked with WebMock, so GitHub is stubbed in every test. When a system test fails, its screenshot is in `tmp/screenshots`, and CI uploads that folder as an artifact.

`test/docs/docs_test.rb` keeps this site in step with the code:

- Every page in `docs/docs.json` has an `.mdx` file, and every `.mdx` file outside `docs/snippets/` is in `docs.json`.
- Every environment variable that `app/`, `config/`, `lib/`, `bin/` or `db/` reads, and every one the agent reads, appears on [Environment](../docs/reference/environment.mdx).
- `CHANGELOG.md` renders as one `<Update>` per release.

## Regenerate the screenshots

The screenshots in `docs/screenshots/` come from a system test. It is skipped unless you ask for it:

```bash
SCREENSHOTS=1 bin/rails test test/system/screenshots_test.rb
```

The test seeds a demo fleet of 72 servers and 40 apps, records some activity, and saves the board, search, an app, a server, Activity and the map at 1440 pixels wide. It saves each one twice: `<name>.png` in the light theme and `<name>-dark.png` in the dark theme. Commit the new images with the change that altered the screens.

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

> **Note:** How the site is built for production is not decided yet. `mint export` makes a static build, but it needs a Mintlify Enterprise plan. `docs/config/deploy.yml` holds a Kamal config for `meridian.yoginth.com` that waits on a `Dockerfile` in `docs/` which serves the site on port 80 with `/up` answering `200`.

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
- **Every change keeps `bin/ci` green.** Add tests for behaviour, and system tests for screens.
- **Fixtures use `example.com` and documentation IP ranges.** Never commit real hostnames, IPs, tokens or anyone's infrastructure.
- **When a choice is ambiguous,** pick the simplest option that keeps Git as the record, and add one short entry to [Decisions](decisions.md).

Use small conventional commits, such as `feat(board): …`, `fix(agent): …` or `docs: …`. Add a line to `CHANGELOG.md` under `## Unreleased` for anything a user would notice. The pull request template asks for the same three things: `bin/ci` passes, a changelog line, and no real infrastructure.

## Release

A release is a Git tag. Pushing a tag that starts with `v` runs `.github/workflows/release.yml`, which builds two images for `linux/amd64` and `linux/arm64` and pushes them to the GitHub Container Registry:

| Image | Built from | Tags |
| --- | --- | --- |
| `ghcr.io/<owner>/meridian` | `Dockerfile` | the tag, and `latest` |
| `ghcr.io/<owner>/meridian-agent` | `agent/Dockerfile` | the tag, and `latest` |

The workflow passes the tag as the `VERSION` build argument. The agent's `Dockerfile` stamps it into the binary, which reports it as its agent version. The app's `Dockerfile` ignores it.

### 1. Name the release in the changelog

In `CHANGELOG.md`, rename `## Unreleased` to the version and date, for example `## v0.2.0 (2027-01-15)`, and start a new empty `## Unreleased` above it if there is more to come.
### 2. Commit, tag and push

```bash
git commit -am "chore(release): v0.2.0"
git tag v0.2.0
git push origin main v0.2.0
```

Then upgrade your own install as [Upgrading](../docs/operate/upgrading.mdx) describes.
