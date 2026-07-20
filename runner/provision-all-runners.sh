#!/usr/bin/env bash
#
# provision-all-runners.sh — batch-provision a repo-level self-hosted reviewer
# runner for every repo in the docs-control ecosystem (or a subset passed as
# args). Wraps the idempotent provision-repo-runner.sh, so re-running is safe and
# only missing runners are created.
#
#   bash runner/provision-all-runners.sh                 # every downstream repo
#   bash runner/provision-all-runners.sh dns webapp-api-protection   # a subset
#
# One laptop hosts all runners. Idle runner listeners are light (~70-80 MB RSS
# each; ~2.9 GB for the full ~38-repo fleet on a 32 GB machine), and the
# machine-wide review-slot semaphore caps CONCURRENT reviews at REVIEW_MAX_SLOTS
# (default 5) — so the rest queue rather than overload. See docs/ROLLOUT.md.
#
set -euo pipefail

ORG="${ORG:-f5-sales-demo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

repos=()
if [ "$#" -gt 0 ]; then
  repos=("$@")
else
  # Fleet list from docs-control (no local clone needed). bash 3.2-safe (no mapfile).
  while IFS= read -r r; do
    [ -n "$r" ] && repos+=("$r")
  done < <(gh api "repos/$ORG/docs-control/contents/.github/config/downstream-repos.json" \
    --jq '.content' | base64 --decode | jq -r '.[]')
fi

echo "Provisioning reviewer runners for ${#repos[@]} repo(s) on this host."
fail=0
for r in "${repos[@]}"; do
  echo "==================== ${ORG}/${r} ===================="
  if bash "${SCRIPT_DIR}/provision-repo-runner.sh" "${ORG}/${r}"; then
    echo "[OK] ${r}"
  else
    echo "[FAIL] ${r}"
    fail=1
  fi
done

echo
echo "Registered runners across the org:"
gh api "orgs/${ORG}/actions/runners" --jq '.runners[]?.name' 2>/dev/null || true
if [ "$fail" -ne 0 ]; then
  echo "One or more runners failed to provision." >&2
  exit 1
fi
echo "All requested runners provisioned."
