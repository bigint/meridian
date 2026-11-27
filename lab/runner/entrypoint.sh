#!/bin/sh
set -eu
cd /runner
# Register once. After a Docker or laptop restart the container keeps its
# registration (and the one-time token has expired), so just run.
if [ ! -f .runner ]; then
  [ -n "${RUNNER_REPO:-}" ] && [ -n "${RUNNER_TOKEN:-}" ] || {
    echo "lab-runner: RUNNER_REPO and RUNNER_TOKEN are needed to register; start it with bin/lab up" >&2
    exit 1
  }
  ./config.sh --unattended --replace --url "https://github.com/$RUNNER_REPO" --token "$RUNNER_TOKEN" \
    --name meridian-lab --labels "self-hosted,meridian-lab" --work _work
fi
exec ./run.sh
