#!/bin/sh
set -e
cd /runner
./config.sh --unattended --replace --url "https://github.com/$RUNNER_REPO" --token "$RUNNER_TOKEN" \
  --name "${RUNNER_NAME:-meridian-lab}" --labels "self-hosted,meridian-lab" --work _work
exec ./run.sh
