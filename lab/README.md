# Lab

A local fleet for trying Meridian against real Kamal deploys, inside Docker:
six Docker-in-Docker servers, a registry and a GitHub Actions runner, deploying
the real bigint sites. Nothing here is used in production.

The whole guide is the [Lab page](https://meridian.yoginth.com/internals/lab)
of the docs ([`docs/internals/lab.mdx`](../docs/internals/lab.mdx)).

```bash
bin/lab up owner/infra-repo   # build and start everything, register the runner
bin/lab secrets owner/infra-repo  # set the repository secrets the infra repo needs (only missing ones)
bin/lab push all              # push the newest version of every site to the registry
bin/lab versions occasions    # list a site's versions, oldest first
bin/lab push occasions 6c45ebf  # push an older one, to deploy or roll back to
bin/lab push umami 3.5.0      # push an Umami release
bin/lab agents                # run meridian-agent on every server
bin/lab kamal owner/infra-repo accessory boot db -c deploy/umami.yml  # Kamal from inside the lab
bin/lab webhooks owner/infra-repo  # optional: forward the repo's webhooks, for instant updates
bin/lab ssh use1-az1-node-01  # a shell on one server
bin/lab status
bin/lab down
```

Secrets the lab generates live in `lab/.secrets/`, which is git-ignored.
