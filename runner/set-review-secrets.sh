#!/usr/bin/env bash
#
# set-review-secrets.sh — set the reviewer's gateway secret + variable on every
# repo in the docs-control ecosystem (or a subset passed as args). The governance
# enforce-repo-settings flow only AUDITS secret presence; it never sets values, so
# this must be run by the operator once per repo being onboarded.
#
#   export F5_GATEWAY_TOKEN=sk-...            # LiteLLM gateway key
#   export F5_GATEWAY_URL=https://f5ai.pd.f5net.com/anthropic
#   bash runner/set-review-secrets.sh                       # every downstream repo
#   bash runner/set-review-secrets.sh dns webapp-api-protection   # a subset
#
set -euo pipefail

ORG="${ORG:-f5-sales-demo}"
: "${F5_GATEWAY_TOKEN:?export F5_GATEWAY_TOKEN (the LiteLLM gateway key)}"
: "${F5_GATEWAY_URL:?export F5_GATEWAY_URL (e.g. https://f5ai.pd.f5net.com/anthropic)}"

repos=()
if [ "$#" -gt 0 ]; then
  repos=("$@")
else
  while IFS= read -r r; do
    [ -n "$r" ] && repos+=("$r")
  done < <(gh api "repos/$ORG/docs-control/contents/.github/config/downstream-repos.json" \
    --jq '.content' | base64 --decode | jq -r '.[]')
fi

echo "Setting reviewer secret/variable on ${#repos[@]} repo(s)."
for r in "${repos[@]}"; do
  if gh secret set F5_GATEWAY_TOKEN --repo "${ORG}/${r}" --body "$F5_GATEWAY_TOKEN" >/dev/null 2>&1 &&
    gh variable set F5_GATEWAY_URL --repo "${ORG}/${r}" --body "$F5_GATEWAY_URL" >/dev/null 2>&1; then
    echo "[OK] ${r}"
  else
    echo "[FAIL] ${r} (check repo access)"
  fi
done
echo "Done. (enforce-repo-settings audits presence; values are set here.)"
