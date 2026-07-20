#!/usr/bin/env bash
#
# provision-repo-runner.sh — one-command setup of a repo-level self-hosted
# reviewer runner on this host. On GitHub Free each onboarded repo needs its own
# repo-level runner instance (org-level runners don't dispatch to private repos),
# so this stages one, renders a per-repo LaunchAgent, and loads it. Idempotent.
#
#   bash runner/provision-repo-runner.sh f5-sales-demo/<repo>
#
# Prereqs (same as the primary — see runner/README.md): the Claude CLI installed
# for this user, the registration PAT at ~/.config/code-review-runner/reg.pat, and
# an active GUI login session (SessionCreate needs it for keychain/az/gh access).
#
# The machine-wide review cap (docs-control scripts/review-slot.sh) bounds
# concurrency regardless of how many instances this provisions.
#
set -euo pipefail

REPO="${1:?usage: provision-repo-runner.sh <owner/repo>}"
SHORT="${REPO##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUNNER_DIR="$HOME/actions-runner-${SHORT}"
CA_BUNDLE="${CA_BUNDLE:-$HOME/.config/code-review-runner/ca-bundle.pem}"
LABEL="com.f5-sales-demo.code-review-runner-${SHORT}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
OUT_LOG="/tmp/code-review-runner-${SHORT}.out.log"
ERR_LOG="/tmp/code-review-runner-${SHORT}.err.log"

echo "==> staging runner for ${REPO} in ${RUNNER_DIR}"
RUNNER_DIR="$RUNNER_DIR" CA_BUNDLE="$CA_BUNDLE" bash "${SCRIPT_DIR}/install-runner.sh"

echo "==> installing ephemeral loop script"
cp "${SCRIPT_DIR}/run-ephemeral-loop.sh" "${RUNNER_DIR}/run-ephemeral-loop.sh"
chmod +x "${RUNNER_DIR}/run-ephemeral-loop.sh"

echo "==> rendering LaunchAgent ${LABEL}"
mkdir -p "$(dirname "$PLIST")"
sed -e "s#com.f5-sales-demo.code-review-runner#com.f5-sales-demo.code-review-runner-${SHORT}#" \
  -e "s#actions-runner-code-review#actions-runner-${SHORT}#g" \
  -e "s#/tmp/code-review-runner.out.log#${OUT_LOG}#" \
  -e "s#/tmp/code-review-runner.err.log#${ERR_LOG}#" \
  -e "s#REPLACE_REPO#${REPO}#" \
  -e "s#REPLACE_CA_BUNDLE#${CA_BUNDLE}#" \
  "${SCRIPT_DIR}/com.f5-sales-demo.code-review-runner.plist" >"$PLIST"

echo "==> (re)loading LaunchAgent"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

cat <<EOF
Provisioned reviewer runner for ${REPO}
  dir:   ${RUNNER_DIR}
  label: ${LABEL}
  logs:  ${OUT_LOG} / ${ERR_LOG}
Verify (should show name '$(hostname)-${SHORT}', status online):
  gh api repos/${REPO}/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'
EOF
