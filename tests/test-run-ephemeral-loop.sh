#!/usr/bin/env bash
# Hermetic test for runner/run-ephemeral-loop.sh — the ephemeral runner loop.
# Sources the script (main-guarded, so no loop runs) and exercises the pure
# helpers in isolation. No network, no launchd, no real runner binary.
#
# Covers:
#   * compute_backoff / backoff_ceiling — exponential backoff, capped, jittered.
#   * register_and_run_once — returns non-zero on a registration failure instead
#     of aborting the whole script (the crash-loop bug this fixes: the pre-fix
#     `set -e` + unguarded token fetch killed the process, and launchd relaunched
#     it with no backoff).
#   * rotate_logs — bounds log growth by in-place truncation, portable (wc -c).
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${REPO_ROOT}/runner/run-ephemeral-loop.sh"

FAIL=0
check() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "[OK] $label"; else
    echo "[FAIL] $label"
    FAIL=1
  fi
}

# Deterministic backoff params for assertions.
export BACKOFF_BASE=5 BACKOFF_MAX=300 MAX_LOG_BYTES=100

# shellcheck disable=SC1090
source "$SCRIPT"

# ---- backoff_ceiling: deterministic, monotonic non-decreasing, capped ----
check "ceiling(0) == BASE" '[ "$(backoff_ceiling 0)" -eq 5 ]'
check "ceiling(1) == 10" '[ "$(backoff_ceiling 1)" -eq 10 ]'
check "ceiling grows (0<=1<=2<=3)" '[ "$(backoff_ceiling 0)" -le "$(backoff_ceiling 1)" ] && [ "$(backoff_ceiling 1)" -le "$(backoff_ceiling 2)" ] && [ "$(backoff_ceiling 2)" -le "$(backoff_ceiling 3)" ]'
check "ceiling capped at MAX (n=6)" '[ "$(backoff_ceiling 6)" -eq 300 ]'
check "ceiling capped at MAX (n=99)" '[ "$(backoff_ceiling 99)" -eq 300 ]'

# ---- compute_backoff: result within [ceiling/2, ceiling] for many draws ----
ok=1
for n in 0 1 3 6 12; do
  c="$(backoff_ceiling "$n")"
  lo=$((c / 2))
  for _ in $(seq 1 20); do
    v="$(compute_backoff "$n")"
    { [ "$v" -ge "$lo" ] && [ "$v" -le "$c" ]; } || ok=0
  done
done
check "compute_backoff within [ceiling/2, ceiling]" '[ "$ok" -eq 1 ]'

# ---- register_and_run_once: guarded failure returns non-zero (no abort) ----
# Drive the REAL fetch_token code path via a fake `gh` on PATH (mode switched by
# GH_FAKE_MODE), plus stub config.sh/run.sh in cwd — no function redefinition.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
printf '#!/usr/bin/env bash\nexit 0\n' >config.sh
chmod +x config.sh
printf '#!/usr/bin/env bash\nexit 0\n' >run.sh
chmod +x run.sh
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
# token -> print a token and succeed; anything else -> fail (simulates VPN/PAT/5xx)
if [ "${GH_FAKE_MODE:-fail}" = "token" ]; then echo "faketoken"; exit 0; fi
exit 1
SH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
export REPO="owner/repo" RUNNER_NAME="t"
export REG_PAT_FILE="$WORK/absent.pat" # unreadable -> fetch_token uses ambient gh

# Registration keeps failing: each attempt must RETURN non-zero (pre-fix, set -e
# aborted the whole script here, so launchd hot-relaunched with no backoff).
export GH_FAKE_MODE=fail
fails_returned=0
for _ in 1 2 3; do
  rc=0
  register_and_run_once >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then fails_returned=$((fails_returned + 1)); fi
done
check "3 registration failures each return non-zero" '[ "$fails_returned" -eq 3 ]'

export GH_FAKE_MODE=token
rc=0
register_and_run_once >/dev/null 2>&1 || rc=$?
check "successful registration returns 0" '[ "$rc" -eq 0 ]'

# ---- rotate_logs: truncate oversize in place, keep a .1 tail; leave small alone ----
big="$WORK/big.log"
head -c 300 /dev/zero | tr '\0' 'x' >"$big" # 300 bytes > MAX_LOG_BYTES(100)
RUNNER_OUT_LOG="$big" RUNNER_ERR_LOG="" rotate_logs
big_sz=$(wc -c <"$big" | tr -d ' ')
check "oversize log truncated to <= MAX_LOG_BYTES" '[ "$big_sz" -le 100 ]'
check "rotated archive .1 exists" '[ -f "$big.1" ]'
arch_sz=$(wc -c <"$big.1" 2>/dev/null | tr -d ' ' || echo 0)
check "archive .1 <= MAX_LOG_BYTES/2" '[ "$arch_sz" -le 50 ]'

small="$WORK/small.log"
printf 'hello\n' >"$small"
RUNNER_OUT_LOG="$small" RUNNER_ERR_LOG="" rotate_logs
check "small log left untouched (no .1)" '[ ! -f "$small.1" ] && [ "$(wc -c < "$small" | tr -d " ")" -eq 6 ]'

# ---- rotate_logs: unset paths are a safe no-op (set -u must not trip) ----
rc=0
(RUNNER_OUT_LOG="" RUNNER_ERR_LOG="" rotate_logs) >/dev/null 2>&1 || rc=$?
check "empty log paths are a no-op" '[ "$rc" -eq 0 ]'

if [ "$FAIL" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
