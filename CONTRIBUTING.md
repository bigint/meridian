# Contributing

Thank you for helping. Meridian aims to be small, clear and boring in the best way.

## Ground rules

- **Read the [principles](README.md#principles).** A change that makes Meridian run Kamal itself, connect to servers, or keep secret values won't be merged.
- **Vanilla Rails.** Rich models with concerns, thin CRUD controllers, Hotwire. No Node, no JavaScript bundler, no service objects.
- **Build screens from components.** Use the `Ui::` components in `app/components/ui/` and Tailwind's semantic tokens (`bg-surface`, `text-ink`, `border-line`). A new component gets a Lookbook preview and a test. See [`docs/design.md`](docs/design.md).
- **Prefer deleting code to adding it.** The only planned abstraction is the Git host adapter (`app/models/git_host.rb`).
- **Every change keeps `bin/ci` green.** Add tests for behaviour, and system tests for screens.
- **Fixtures use `example.com` and documentation IP ranges.** Never commit real hostnames, IPs, tokens or anyone's infrastructure.
- **When a choice is ambiguous,** pick the simplest option that keeps Git as the record, and add one short entry to [`docs/decisions.md`](docs/decisions.md).

## Setup

You need Ruby (see `.ruby-version`), Go (see `agent/go.mod`), libsodium (`brew install libsodium` or `apt install libsodium23`) and Chrome for system tests.

```bash
bin/setup
bin/dev   # the app on :3000, with Tailwind rebuilding as you edit
bin/ci
```

While `bin/dev` runs, [`/lookbook`](http://localhost:3000/lookbook) shows every component in every state.

## Commits

Use small conventional commits (`feat(board): …`, `fix(agent): …`, `docs: …`), and add a line to `CHANGELOG.md` for anything a user would notice.
