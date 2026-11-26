# Lab

A local fleet for trying Meridian against real Kamal deploys, inside Docker
(kiri, Docker Desktop, OrbStack…). Nothing here is used in production.

- Twenty-one servers named like AWS availability zones (`apse1-az1-node-01` in Singapore, `euc1-az1-node-01` in Frankfurt, `mec1-az1-node-01` in Dubai…): each runs sshd and its own Docker daemon (Docker in Docker), so Kamal deploys to them exactly as it would to a VM.
- `registry`: a private image registry, `registry:5000` inside the lab and `localhost:5555` from your machine.
- `runner`: a GitHub Actions self-hosted runner registered on your test infra repository, on the same network as the servers, so the Meridian workflow can run `kamal deploy` against them.
- The apps are the six real bigint sites (yoginth-com, asiafibernet-com, nailbykyro-com, asiagigafibernet-com, occasions, pckumar-in). Each version is a public files-only image at `ghcr.io/bigint/<site>:<commit>`; `bin/lab push` wraps it in nginx (`lab/site/`) the way bigint/infra does in production and pushes it as `bigint/<site>:<7-character commit>`. Their Kamal configs live in bigint/meridian-infra-test, with the real hostnames: try one with `curl -H 'Host: yoginth.com' http://<server>/` from inside the lab.

```bash
bin/lab up owner/infra-repo   # build and start everything, register the runner
bin/lab push all              # push the newest version of every site to the registry
bin/lab versions occasions    # list a site's versions, oldest first
bin/lab push occasions 6c45ebf  # push an older one, to deploy or roll back to
bin/lab agents                # run meridian-agent on every server
bin/lab webhooks owner/infra-repo  # forward the repo's webhooks to the dev server (leave it running)
bin/lab status
bin/lab down
```

Meridian learns about deploys, including their status, only from GitHub webhooks, and GitHub can't reach `localhost`. `bin/lab webhooks` uses `gh webhook forward` (install it with `gh extension install cli/gh-webhook`), so GitHub relays them without exposing the dev server. Start the dev server with `GITHUB_APP_WEBHOOK_SECRET=$(cat lab/.secrets/webhook_secret)`.

Secrets the lab generates (an SSH key, the registry password and the webhook secret) live in `lab/.secrets/`, which is git-ignored.
