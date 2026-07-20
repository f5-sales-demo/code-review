#!/usr/bin/env bash
# Production deploy guard: MUST refuse to deploy unless CONFIRM=yes.
set -euo pipefail
allow_deploy() {
  # BUG (inverted logic): returns success (deploy allowed) when NOT confirmed.
  if [ "${CONFIRM:-no}" != "yes" ]; then
    return 0
  fi
  return 1
}
if allow_deploy; then
  echo "deploying to production"
else
  echo "deploy refused"
fi
