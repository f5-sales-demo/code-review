#!/usr/bin/env bash
# Hermetic test for runner/health-alert.sh — the deduped issue open/close helper
# the scheduled Reviewer Health workflow calls. `gh` is stubbed on PATH: it logs
# every invocation and, for `issue list`, prints the fake open-issue numbers in
# $GH_FAKE_OPEN. No network, no real issues.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${REPO_ROOT}/runner/health-alert.sh"

FAIL=0
check() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "[OK] $label"; else
    echo "[FAIL] $label"
    FAIL=1
  fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$GH_CALLS"
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  for n in ${GH_FAKE_OPEN:-}; do echo "$n"; done
fi
exit 0
SH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
export GITHUB_REPOSITORY="test/repo"
printf 'drift report body\n' >"$WORK/report.txt"

run_case() {
  GH_CALLS="$WORK/calls"
  : >"$GH_CALLS"
  export GH_CALLS
  GH_FAKE_OPEN="$1" bash "$SCRIPT" "$2" "$WORK/report.txt" >/dev/null 2>&1
}

# --- red + no open issue -> create one ---
run_case "" red
check "red/none -> issue create" 'grep -q "issue create" "$WORK/calls"'
check "red/none -> no issue comment" '! grep -q "issue comment" "$WORK/calls"'

# --- red + existing open issue -> comment, do NOT create a duplicate ---
run_case "42" red
check "red/open -> issue comment 42" 'grep -q "issue comment 42" "$WORK/calls"'
check "red/open -> no issue create" '! grep -q "issue create" "$WORK/calls"'

# --- green + existing open issue -> close it ---
run_case "42" green
check "green/open -> issue close 42" 'grep -q "issue close 42" "$WORK/calls"'

# --- green + no open issue -> do nothing (only the list query) ---
run_case "" green
check "green/none -> no create" '! grep -q "issue create" "$WORK/calls"'
check "green/none -> no comment" '! grep -q "issue comment" "$WORK/calls"'
check "green/none -> no close" '! grep -q "issue close" "$WORK/calls"'

# --- unknown state -> non-zero exit ---
rc=0
GH_CALLS="$WORK/calls" GH_FAKE_OPEN="" bash "$SCRIPT" bogus "$WORK/report.txt" >/dev/null 2>&1 || rc=$?
check "unknown state exits non-zero" '[ "$rc" -ne 0 ]'

if [ "$FAIL" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
