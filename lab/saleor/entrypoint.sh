#!/bin/sh
set -e
# Docker env files hold one line per variable, so the PEM key travels base64-encoded.
if [ -n "${RSA_PRIVATE_KEY_B64:-}" ]; then
  RSA_PRIVATE_KEY="$(printf '%s' "$RSA_PRIVATE_KEY_B64" | base64 -d)"
  export RSA_PRIVATE_KEY
fi
# The web role migrates before serving; the lock lets one host at a time do it.
if [ "${MIGRATE:-}" = 1 ]; then
  PYTHONPATH="/app${PYTHONPATH:+:$PYTHONPATH}" python3 /usr/local/bin/lab-saleor-migrate
fi
exec "$@"
