#!/usr/bin/env bash
# Runs a native, ephemeral self-hosted runner in a loop: each iteration fetches a
# fresh registration token, configures once, processes exactly one job, then
# de-registers and repeats. Must run inside the operator's GUI login session so
# it inherits the login keychain and az/gh sessions.
set -euo pipefail
: "${ORG:?export ORG}"
: "${RUNNER_GROUP:?export RUNNER_GROUP}"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-code-review}"
LABELS="self-hosted,macOS,code-review"
# Registration tokens require admin:org. Read a PAT from a protected file and use
# it ONLY for the token fetch (inline, never exported), so the admin credential
# does NOT reach ./run.sh or any job step (jobs execute untrusted PR code). If the
# file is absent, fall back to the ambient gh session (which must then have
# admin:org itself).
REG_PAT_FILE="${REG_PAT_FILE:-$HOME/.config/code-review-runner/reg.pat}"
fetch_token() {
  if [[ -r "$REG_PAT_FILE" ]]; then
    GH_TOKEN="$(cat "$REG_PAT_FILE")" \
      gh api -X POST "orgs/$ORG/actions/runners/registration-token" --jq .token
  else
    gh api -X POST "orgs/$ORG/actions/runners/registration-token" --jq .token
  fi
}
cd "$RUNNER_DIR"
while true; do
  TOKEN="$(fetch_token)"
  ./config.sh --url "https://github.com/$ORG" --token "$TOKEN" \
    --labels "$LABELS" --runnergroup "$RUNNER_GROUP" \
    --name "$(hostname)-code-review" --unattended --replace --ephemeral
  ./run.sh || true # processes one job then exits (ephemeral)
  sleep 2          # brief backoff before re-registering
done
