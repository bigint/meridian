#!/bin/sh
set -e
cd /runner
# Register once. After a Docker or laptop restart the container keeps its
# registration (and the one-time token has expired), so just run.
if [ ! -f .runner ]; then
  ./config.sh --unattended --replace --url "https://github.com/$RUNNER_REPO" --token "$RUNNER_TOKEN" \
    --name "${RUNNER_NAME:-meridian-lab}" --labels "self-hosted,meridian-lab" --work _work
fi
exec ./run.sh
