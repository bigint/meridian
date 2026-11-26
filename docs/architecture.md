# Architecture

Meridian is a Rails application that reads Kamal configs from Git and reads running containers from small agents on each server. It writes only to Git. The CI provider runs Kamal, and nothing else does.

```
Operator ──HTTPS──▶ Meridian (one container: Rails + Solid Queue in Puma)
                       │  ▲
      commits, PRs,    │  │ webhooks (push, pull_request, workflow_run)
   secrets (write-only)▼  │
                     GitHub ──Actions──▶ kamal deploy ──SSH──▶ servers (kamal-proxy + apps)
                                                                  │
                     Meridian ◀──HTTPS POST + /cable WebSocket (outbound only)── meridian-agent on each server
```

## Data flow

**What should run comes from Git.**

1. A `push` webhook, the reconcile job (every 30 seconds) or an operator pressing *Sync* enqueues `ProjectSyncJob`. It reads Git, then the branch's recent workflow runs, so deploys show up even without webhooks. Both GitHub calls carry the last answer's ETag: an unchanged repository answers 304, which costs no rate limit.
2. The job reads the repository tree at the default branch's head through the GitHub API. It keeps only the paths that match the project's `config_globs`, together with their destination files (`deploy.<dest>.yml`) and version files (`deploy.version`). Blobs are fetched by SHA and cached, so a blob that has not changed is never fetched again.
3. The files are written to a temporary directory, and `bin/kamal-parse` parses them in a **separate process with an empty environment**. The script uses `Kamal::Configuration`, the same code that `kamal deploy` runs, so Meridian sees what Kamal sees: ERB, aliases, destinations, roles and accessories. The environment is empty because Kamal configs evaluate ERB, and ERB is arbitrary Ruby from the infra repository. That Ruby must not be able to read Meridian's own credentials.
4. The sync upserts these records:
   - `App`: one per config and destination
   - `Server`: matched by hostname until an agent claims it
   - `Assignment`: one per app, server and role
   - `Release`: from the commit history of the app's version file, or of its config when there is no version file
5. Parse errors are stored on the project with file, line and message. A config that fails to parse keeps its app as the last good parse left it, with its deploys, releases and previews; only an app whose config is gone from Git is removed, and its previews are removed first.
6. Every GitHub read (the tree, blobs, commit history and version files) happens before the sync's database transaction, which only writes.

**What does run comes from the agents.**

1. Every 15 seconds, give or take 20%, each agent POSTs a snapshot to `/agent/snapshots`. A snapshot lists containers with Kamal labels, their health and their versions.
2. The endpoint checks the bearer token's digest, enqueues the snapshot and returns `202`.
3. `SnapshotIngestJob` upserts the server and its `Placement` rows in one transaction, deletes the placements that have gone and touches `last_seen_at`. It then asks for a throttled board broadcast for the server's group, at most one per group per second.

**Drift is the difference between the two.** It is computed when it is read, never stored, by `Drift.state`, which `Board` calls for each app, server and role, stray placements included. A cell shows its worst role, so a stopped `job` container isn't hidden by a running `web` one:

| State | Meaning |
| --- | --- |
| `in_sync` | the running version equals the newest release |
| `drifted` | something is running, but not the newest release |
| `missing` | the app is assigned to the server, but nothing is running there |
| `stray` | something is running, but it is not assigned in Git |
| `stale` | the server's agent has been silent for more than 3 intervals |
| `unknown` | there is no release, or the agent has never reported |

**Changes go to Git, never to servers.**

- **Deploy** is a contents-API commit to the app's version file, using the file's current blob SHA. The message is `deploy(<app>): <version>`, followed by an `Meridian-Actor:` trailer.
- **Roll back** reverts a release commit's change to the version file, with the message `rollback(<app>): <version>`.
- **New app, preview setup and the CI workflow** arrive as pull requests. A project setting lets admins commit them directly instead.
- **Deploy status** comes from the deploy workflow's runs (`.github/workflows/meridian-deploy.yml`; other workflows are ignored), through `workflow_run` webhooks and polling the branch's workflow runs every 30 seconds; both go through `Project#track_workflow_run`, and one repository's jobs run one at a time.

## Domain model

| Model | Role |
| --- | --- |
| `Account` | The single row that holds settings: preview domain and defaults. |
| `User` | Email and password (Rails 8 authentication). Role is `viewer`, `deployer` or `admin`. |
| `Project` | One infra repository. It holds the GitHub installation, config globs, the last synced SHA and parse errors. |
| `App` | One Kamal config and destination. It holds the service, config path, kind, hostnames and source repository. |
| `Server` | One machine, unique by the `machine_id` its agent reports (by hostname before that). It holds labels, agent version and last-seen time. |
| `Assignment` | An app that Git says should run on a server, in a given role. |
| `Placement` | A container that an agent says is running on a server. The row is upserted and never appended. |
| `Release` | One commit that changed what an app should run. It holds version, SHA, author, time and message. |
| `Deploy` | One CI run. Per-server progress comes from what agents report running. |
| `Preview` | A `pr-<n>` destination overlay for a pull request in the app's source repository. |
| `SecretName` | The name of a secret and the apps that reference it. **It never holds a value.** |
| `AgentToken` | A bearer token, stored only as a SHA-256 digest, optionally bound to one server. |
| `Event` | The audit trail of everything Meridian did, and who did it. |

## Kamal and kamal-proxy findings

Meridian pins **kamal 2.12.0** and has been checked against **kamal-proxy 0.10.3**. In the links below, K is `https://github.com/basecamp/kamal/blob/v2.12.0/` and P is `https://github.com/basecamp/kamal-proxy/blob/v0.10.3/`.

### Labels and container names

- **Default labels.** App containers get the labels `service`, `role` and `destination` ([K lib/kamal/configuration/role.rb#L212-L214](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/configuration/role.rb#L212-L214)). Custom `labels:` set at the top level and then on the role are merged on top ([#L54-L60](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/configuration/role.rb#L54-L60), [#L232-L237](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/configuration/role.rb#L232-L237)). Role and accessory labels may not use the reserved names ([K validator.rb#L222-L232](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/configuration/validator.rb#L222-L232)).
- **No destination.** Kamal then emits a bare `--label destination` ([K utils.rb#L9-L21](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/utils.rb#L9-L21)), which Docker stores as `destination=""`.
- **Container name.** The name is `[service, role, destination].compact.join("-")` followed by `-<version>` ([role.rb#L124-L130](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/configuration/role.rb#L124-L130)).
- **Version.** There is no version label. Kamal reads the version back by stripping the prefix from the name ([K commands/app.rb#L107-L110](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/commands/app.rb#L107-L110)), and the agent does the same.
- **Accessories.** They are named and labelled `service=<service>-<accessory>` ([K accessory.rb#L26-L28](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/configuration/accessory.rb#L26-L28)).
- **The proxy.** The proxy container is named `kamal-proxy` and carries no Kamal labels ([K commands/proxy.rb#L10-L25](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/commands/proxy.rb#L10-L25)).

### kamal-proxy routes, read-only

- **The state file.** kamal-proxy writes its services to `$HOME/.config/kamal-proxy/kamal-proxy.state` ([P internal/server/config.go#L34-L65](https://github.com/basecamp/kamal-proxy/blob/v0.10.3/internal/server/config.go#L34-L65)). The file is a JSON array of `{name, options: {hosts, path_prefixes, tls_enabled, …}, active_targets, …}` ([P service.go#L325-L340](https://github.com/basecamp/kamal-proxy/blob/v0.10.3/internal/server/service.go#L325-L340)). Older versions wrote `hosts` and `active_target` at the top level ([#L410-L422](https://github.com/basecamp/kamal-proxy/blob/v0.10.3/internal/server/service.go#L410-L422)).
- **Where it lives.** Kamal mounts that directory from the **named volume `kamal-proxy-config`** ([K commands/proxy.rb#L18](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/commands/proxy.rb#L18)). The directory has mode 0700.
- **Partial writes.** The file is rewritten in place, not atomically ([P router.go#L407-L429](https://github.com/basecamp/kamal-proxy/blob/v0.10.3/internal/server/router.go#L407-L429)), so a reader can see half a file.
- **Other ways to list routes.** `kamal-proxy list` uses a unix socket inside the container ([P cmd/list.go](https://github.com/basecamp/kamal-proxy/blob/v0.10.3/internal/cmd/list.go#L20-L60)), so reaching it requires `docker exec`. kamal-proxy has no HTTP endpoint that lists routes.
- **Conclusion.** Route reporting is possible read-only, by mounting `kamal-proxy-config` read-only into an agent running as root so it can read the 0700 directory. The agent did this until Meridian found it never used the routes; see decision 35.

### Destination files

- **Overlay file.** `-c path/foo.yml -d staging` loads `path/foo.staging.yml` ([K configuration.rb#L49-L51](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/configuration.rb#L49-L51)). Each file is rendered with ERB, loaded as YAML and deep-merged over the base ([#L28-L47](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/configuration.rb#L28-L47)). An overlay may override any key, `service` included.
- **Secrets.** They are read from `.kamal/secrets-common`, then from `.kamal/secrets.<dest>`, resolved against the **working directory** rather than the config's own directory ([K secrets.rb#L37-L45](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/secrets.rb#L37-L45)). A missing file is not an error.
- **Previews.** It follows that a preview overlay for `config/deploy.web.yml` is `config/deploy.web.pr-12.yml`.

### Parsing without SSH, secrets or git

- **The call.** `Kamal::Configuration.create_from(config_file: Pathname, destination:, version:)` ([K configuration.rb#L20-L26](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/configuration.rb#L20-L26)) reads secrets lazily.
- **Version.** Passing a version stops Kamal from shelling out to git ([#L450-L460](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/configuration.rb#L450-L460)).
- **Errors.**
  - Invalid configs raise `Kamal::ConfigurationError`, whose message carries a key path such as `servers/web/hosts`, but no line number ([K validator.rb#L183-L198](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/configuration/validator.rb#L183-L198)).
  - Bad YAML raises `Psych::SyntaxError`, which does carry a line.
  - Meridian maps key paths to lines itself, from the YAML node tree.
