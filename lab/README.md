# Lab

A local fleet for trying Meridian against real Kamal deploys, inside Docker
(kiri, Docker Desktop, OrbStack…). Nothing here is used in production.

- Twenty-one servers named like AWS availability zones (`apse1-az1-node-01` in Singapore, `euc1-az1-node-01` in Frankfurt, `mec1-az1-node-01` in Dubai…): each runs sshd and its own Docker daemon (Docker in Docker), so Kamal deploys to them exactly as it would to a VM.
- `registry`: a private image registry, `registry:5000` inside the lab and `localhost:5555` from your machine.
- `runner`: a GitHub Actions self-hosted runner registered on your test infra repository, on the same network as the servers, so the Meridian workflow can run `kamal deploy` against them.

```bash
bin/lab up owner/infra-repo   # build and start everything, register the runner
bin/lab push v2               # build the demo app as v2 and push it to the registry
bin/lab agents                # run meridian-agent on every server
bin/lab status
bin/lab down
```

Secrets the lab generates (an SSH key and the registry password) live in `lab/.secrets/`, which is git-ignored.
