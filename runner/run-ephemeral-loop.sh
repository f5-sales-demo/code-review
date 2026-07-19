#!/usr/bin/env bash
# Runs a native, ephemeral self-hosted runner in a loop, registered at the REPO
# level. (GitHub Free does not dispatch ORG-level self-hosted runners to private
# repositories, so each reviewed repo needs its own repo-level runner instance.)
# Each iteration fetches a fresh registration token, configures once, processes
# exactly one job, then de-registers and repeats. Must run inside the operator's
# GUI login session so it inherits the login keychain and az/gh sessions.
set -euo pipefail
: "${REPO:?export REPO (owner/name, e.g. f5-sales-demo/code-review)}"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-code-review}"
LABELS="self-hosted,macOS,code-review"
# Registration tokens require repo admin. Read a PAT from a protected file and use
# it ONLY for the token fetch (inline, never exported), so the admin credential
# does NOT reach ./run.sh or job steps that execute untrusted PR code. Falls back
# to the ambient gh session (which must then have repo admin) if the file is absent.
REG_PAT_FILE="${REG_PAT_FILE:-$HOME/.config/code-review-runner/reg.pat}"
fetch_token() {
  if [[ -r "$REG_PAT_FILE" ]]; then
    GH_TOKEN="$(cat "$REG_PAT_FILE")" \
      gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token
  else
    gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token
  fi
}
cd "$RUNNER_DIR"
while true; do
  # Clear any stale local config left by an interrupted prior run so the
  # (ephemeral) re-registration below does not fail with "already configured"
  # (--replace only replaces the server-side runner, not the local config).
  rm -f .runner .credentials .credentials_rsaparams 2>/dev/null || true
  TOKEN="$(fetch_token)"
  ./config.sh --url "https://github.com/$REPO" --token "$TOKEN" \
    --labels "$LABELS" --name "$(hostname)-code-review" \
    --unattended --replace --ephemeral
  ./run.sh || true # processes one job then exits (ephemeral)
  sleep 2          # brief backoff before re-registering
done
