#!/usr/bin/env bash
#
# review-coverage.sh -- report which repos are gated by the Claude PR reviewer, and
# flag drift between INTENDED coverage (docs-control's repo-settings.json, the
# source of truth) and the LIVE state (branch protection + runner availability).
#
#   bash runner/review-coverage.sh            # coverage + drift table
#   bash runner/review-coverage.sh --prs 8    # also: recent-PR review disposition per gated repo
#
# Exit non-zero if any actionable drift is found (config wants review but branch
# protection doesn't enforce it, a gated repo has no online runner, or live
# protection enforces review a repo the config does not intend).
#
set -euo pipefail

ORG="${ORG:-f5-sales-demo}"
REV="review / claude-review"
PRS=0
if [ "${1:-}" = "--prs" ]; then
  PRS="${2:-8}"
  case "$PRS" in '' | *[!0-9]*) PRS=8 ;; esac # ignore non-numeric arg
fi

# gh api -> jq, printing output ONLY on success; EMPTY on any error (404 "not
# protected", 403 no-admin, etc.). Emitting only on success matters twice: under
# `set -e` a bare x="$(gj ...)" must not abort on a 404 (that IS the DRIFT case
# this tool reports), and callers treat empty as "absent" so a 404 error body
# does not leak through as a bogus value into the numeric/grep checks.
gj() {
  local out
  out="$(gh api "$1" --jq "$2" 2>/dev/null)" && printf '%s' "$out" || true
}

cfg="$(gh api "repos/$ORG/docs-control/contents/.github/config/repo-settings.json" --jq '.content' | base64 --decode)"
downstream="$(gh api "repos/$ORG/docs-control/contents/.github/config/downstream-repos.json" --jq '.content' | base64 --decode)"

# branch_protection may be an object or a single-element array; flatten handles both.
base="$(printf '%s' "$cfg" | jq -r '([.branch_protection] | flatten | .[0].required_status_checks.contexts) // [] | join(", ")')"
# INTENDED gated set = repos whose repo_overrides.additional_contexts includes the
# review context (the base list never contains it, so this is exact).
intended="$(printf '%s' "$cfg" | jq -r --arg r "$REV" \
  '.repo_overrides // {} | to_entries[] | select((.value.additional_contexts // []) | index($r)) | .key' | sort)"

echo "Review coverage -- source of truth: docs-control/.github/config/repo-settings.json"
echo "Base required contexts (all repos): ${base}"
echo
printf '%-24s %-9s %-9s %-11s %s\n' "REPO (gated)" "ENFORCED" "WORKFLOW" "RUNNER" "STATUS"
printf '%-24s %-9s %-9s %-11s %s\n' "-----------" "--------" "--------" "------" "------"

drift=0
for repo in $intended; do
  live="$(gj "repos/$ORG/$repo/branches/main/protection" '.required_status_checks.contexts // [] | .[]')"
  if printf '%s\n' "$live" | grep -qxF "$REV"; then enforced="yes"; else enforced="NO"; fi
  online="$(gj "repos/$ORG/$repo/actions/runners" "[.runners[]?|select(.status==\"online\")]|length")"
  [ -z "$online" ] && online=0
  # Is the caller workflow actually present on main? A required review with NO
  # workflow to produce it is a hard DEADLOCK (every PR blocks) -- the failure
  # mode that a branch-protection-only check misses.
  wf="$(gj "repos/$ORG/$repo/contents/.github/workflows/code-review.yml?ref=main" '.name')"
  if [ "$enforced" = "yes" ] && [ -z "$wf" ]; then
    status="DEADLOCK: review required but caller workflow MISSING -- every PR blocks"
    drift=1
  elif [ "$enforced" = "NO" ]; then
    status="DRIFT: config requires review, branch protection does NOT (run enforce-repo-settings)"
    drift=1
  elif [ "$online" -lt 1 ]; then
    status="RISK: required but NO online runner -- PRs will block"
    drift=1
  else
    status="OK"
  fi
  wfcol="yes"
  [ -z "$wf" ] && wfcol="NO"
  printf '%-24s %-9s %-9s %-11s %s\n' "$repo" "$enforced" "$wfcol" "${online} online" "$status"
done

# Reverse drift: a repo the config does NOT intend, yet whose LIVE protection enforces review.
echo
# Space-normalized membership string ($intended is newline-separated from jq|sort).
intended_sp=" $(printf '%s' "$intended" | tr '\n' ' ') "
unexpected=""
for repo in $(printf '%s' "$downstream" | jq -r '.[]'); do
  case "$intended_sp" in *" $repo "*) continue ;; esac
  live="$(gj "repos/$ORG/$repo/branches/main/protection" '.required_status_checks.contexts // [] | .[]')"
  if printf '%s\n' "$live" | grep -qxF "$REV"; then
    unexpected="$unexpected $repo"
    drift=1
  fi
done
if [ -n "$unexpected" ]; then
  echo "UNEXPECTED: live branch protection enforces review on repos NOT in config:${unexpected}"
else
  echo "No unexpected enforcement (live matches config for non-gated repos)."
fi

total="$(printf '%s' "$downstream" | jq 'length')"
gated="$(printf '%s\n' "$intended" | grep -c . || true)"
echo
echo "Summary: ${gated}/${total} repos gated by Claude review; $((total - gated)) not gated (runners idle-ready)."

if [ "$PRS" -gt 0 ]; then
  echo
  echo "Recent PR review disposition (last $PRS per gated repo):"
  for repo in $intended; do
    echo "  == $repo =="
    gh pr list --repo "$ORG/$repo" --state all --limit "$PRS" --json number,headRefOid,headRefName \
      --jq '.[]|"\(.number)\t\(.headRefOid)\t\(.headRefName)"' 2>/dev/null | while IFS=$'\t' read -r num sha ref; do
      run="$(gj "repos/$ORG/$repo/commits/$sha/check-runs" '[.check_runs[]|select(.name|test("claude-review"))]|length')"
      byp="$(gj "repos/$ORG/$repo/commits/$sha/status" "[.statuses[]|select(.context==\"$REV\" and (.description|test(\"not required\")))]|length")"
      if [ "${run:-0}" -ge 1 ]; then
        v="$(gj "repos/$ORG/$repo/commits/$sha/check-runs" '[.check_runs[]|select(.name|test("claude-review"))][0].conclusion // "running"')"
        d="REVIEWED ($v)"
      elif [ "${byp:-0}" -ge 1 ]; then d="bypassed (automated)"; else d="no review"; fi
      printf '    #%-5s %-38s %s\n' "$num" "$ref" "$d"
    done
  done
fi

[ "$drift" -eq 0 ] || {
  echo
  echo "Actionable drift detected (see above)."
  exit 1
}
