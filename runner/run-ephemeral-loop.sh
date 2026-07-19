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
cd "$RUNNER_DIR"
while true; do
  TOKEN="$(gh api -X POST "orgs/$ORG/actions/runners/registration-token" --jq .token)"
  ./config.sh --url "https://github.com/$ORG" --token "$TOKEN" \
    --labels "$LABELS" --runnergroup "$RUNNER_GROUP" \
    --name "$(hostname)-code-review" --unattended --replace --ephemeral
  ./run.sh || true # processes one job then exits (ephemeral)
  sleep 2          # brief backoff before re-registering
done
