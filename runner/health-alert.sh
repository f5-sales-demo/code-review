#!/usr/bin/env bash
# health-alert.sh — surface reviewer-health drift as a single, deduplicated
# GitHub issue. Called by .github/workflows/reviewer-health.yml after
# review-coverage.sh runs.
#
#   health-alert.sh red   <report-file>   # open (or comment on) the alert issue
#   health-alert.sh green <report-file>   # close any open alert issue
#
# Dedup: at most ONE open issue with the reviewer-health label + fixed title.
#   red   + none open  -> create it
#   red   + one open   -> comment on it (no duplicate)
#   green + one open    -> close it (resolved)
#   green + none open   -> no-op
set -euo pipefail

STATE="${1:?usage: health-alert.sh <green|red> <report-file>}"
REPORT="${2:-}"
REPO="${HEALTH_ALERT_REPO:-${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY or HEALTH_ALERT_REPO}}"
LABEL="reviewer-health"
TITLE="reviewer-health: reviewer coverage/runner drift detected"

# Open alert-issue numbers (newline-separated; empty if none).
open_alert_issues() {
  gh issue list --repo "$REPO" --state open --label "$LABEL" \
    --search "$TITLE in:title" --json number --jq '.[].number'
}

case "$STATE" in
green)
  # Close every open alert issue (normally at most one).
  for n in $(open_alert_issues); do
    gh issue close "$n" --repo "$REPO" \
      --comment "Resolved: reviewer health is green as of $(date -u +%Y-%m-%dT%H:%M:%SZ)."
  done
  ;;
red)
  report_body="$(cat "$REPORT" 2>/dev/null || echo '(no report captured)')"
  body="$(printf 'Automated reviewer-health check FAILED (see run logs).\n\n```\n%s\n```\n' "$report_body")"
  # First line only — avoids a head pipe (SIGPIPE under pipefail).
  all_open="$(open_alert_issues)"
  existing="${all_open%%$'\n'*}"
  if [ -n "$existing" ]; then
    gh issue comment "$existing" --repo "$REPO" --body "$body"
  else
    gh issue create --repo "$REPO" --label "$LABEL" --title "$TITLE" --body "$body"
  fi
  ;;
*)
  echo "usage: health-alert.sh <green|red> <report-file>" >&2
  exit 2
  ;;
esac
