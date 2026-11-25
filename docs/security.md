# Security

## What Meridian can do, and why that matters

Through its GitHub App, Meridian can write to your infra repository and set its Actions secrets. Your CI runs whatever that repository says, against your servers. **Anyone who controls Meridian can therefore deploy anything to your servers.** Treat it like your CI system.

| Asset | Where it lives | Who can touch it |
| --- | --- | --- |
| GitHub App private key | `GITHUB_APP_PRIVATE_KEY` env | The Meridian container |
| Installation tokens (1 hour) | Process memory | The Meridian container |
| Agent tokens | SHA-256 digests in SQLite | Nobody can recover them |
| Secret values | GitHub only (sealed with the repo's public key) | Nobody, Meridian included, can read them back |
| User passwords | bcrypt digests | |
| Sessions | Signed, `HttpOnly`, `SameSite=Lax` cookies | |

## Recommendations

1. **Run it on a private network**: a VPN, a tailnet or an internal load balancer. Agents need to reach it, but people don't need to from the public internet.
2. **If it must be public**, use OpenID Connect with a provider that enforces two-factor authentication. Set a strong `SECRET_KEY_BASE` and keep `MERIDIAN_URL` on `https://`, so cookies are secure and HTTPS is forced.
3. **Least privilege on GitHub.** Install the App only on the infra repository and the source repositories that need previews.
4. **Least privilege on servers.** Run the agent behind the Docker socket proxy, as in the template.
5. **Back up** `storage/` (see [litestream.md](litestream.md)). Git keeps the important history anyway; losing Meridian's database loses only the audit trail and agent tokens.

## What Meridian does by design

- **It never connects to servers.** Agents reach out to Meridian; Meridian never connects in, and it has no SSH keys.
- **It never runs Kamal.** CI does, from the repository, where every change is a reviewed commit or pull request.
- **Secret values are write-only.** A value is sealed in the request that receives it, sent to GitHub, and dropped. It is filtered from logs (`filter_parameters`), never assigned to a model, never passed to a job, and never broadcast. Tests assert all of this using a sentinel value.
- **Kamal configs are parsed in a separate process with an empty environment.** ERB in a config is arbitrary Ruby from your infra repository, and it can't read Meridian's keys or memory.
- **Agents are read-only and narrow.** The Docker API is limited to list and inspect, and environment variables, commands and mounts are never collected.
- **Webhooks** are verified with HMAC-SHA256 against the App's webhook secret.
- **Rate limits** (Rails 8 `rate_limit`) apply to sign-in, OIDC callbacks, snapshots, deploys, rollbacks, redeploys and secret writes.
- **Content Security Policy:** same-origin only, inline scripts by nonce only, and no framing.
- **Roles:** viewers read; deployers can also deploy, roll back, redeploy and destroy previews; admins can do everything else.
- **Audit trail:** every change Meridian makes is an `Event`, and every commit carries an `Meridian-Actor:` trailer.

## Known limits

- Anyone with write access to the infra repository can already deploy, with or without Meridian. Meridian adds a second way in, but no new power.
- Snapshots are trusted as reported. A compromised server can lie about what it runs; it can't change Git.
- Preview deploys run the pull request's image on a real server. Use a label selector so previews run only on servers set aside for them.

Report vulnerabilities as described in [SECURITY.md](../SECURITY.md).
