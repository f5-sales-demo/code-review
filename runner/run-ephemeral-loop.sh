#!/usr/bin/env bash
# Runs a native, ephemeral self-hosted runner in a loop, registered at the REPO
# level. (GitHub Free does not dispatch ORG-level self-hosted runners to private
# repositories, so each reviewed repo needs its own repo-level runner instance.)
# Each iteration fetches a fresh registration token, configures once, processes
# exactly one job, then de-registers and repeats. Must run inside the operator's
# GUI login session so it inherits the login keychain and az/gh sessions.
#
# Registration failures (expired PAT, VPN down, GitHub 5xx) return non-zero from
# register_and_run_once and are met with EXPONENTIAL BACKOFF instead of aborting
# the script — the pre-fix `set -e` + unguarded token fetch killed the process,
# and launchd KeepAlive relaunched it immediately, producing a tight crash-loop.
# Logs are truncated in place each iteration so /tmp usage stays bounded.
set -euo pipefail

# Exponential-backoff and log-rotation knobs (env-overridable for tests).
BACKOFF_BASE="${BACKOFF_BASE:-5}"          # first-failure delay, seconds
BACKOFF_MAX="${BACKOFF_MAX:-300}"          # cap per attempt, seconds
MAX_LOG_BYTES="${MAX_LOG_BYTES:-10485760}" # rotate launchd logs above 10 MiB
LABELS="self-hosted,macOS,code-review"

# Registration tokens require repo admin. Read a PAT from a protected file and use
# it ONLY for the token fetch (inline, never exported), so the admin credential
# does NOT reach ./run.sh or job steps that execute untrusted PR code. Falls back
# to the ambient gh session (which must then have repo admin) if the file is absent.
fetch_token() {
  if [[ -r "$REG_PAT_FILE" ]]; then
    GH_TOKEN="$(cat "$REG_PAT_FILE")" \
      gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token
  else
    gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token
  fi
}

# Deterministic backoff ceiling for a given consecutive-failure count: base doubled
# per failure, capped. Separated from the jitter so it is exactly unit-testable.
backoff_ceiling() {
  local n="$1" shift_n exp
  shift_n=$((n > 6 ? 6 : n)) # cap the shift so base*2^n cannot overflow
  exp=$((BACKOFF_BASE * (1 << shift_n)))
  if [ "$exp" -gt "$BACKOFF_MAX" ]; then exp="$BACKOFF_MAX"; fi
  echo "$exp"
}

# Backoff delay = ceiling/2 + jitter in [0, ceiling/2]  => result in [ceiling/2, ceiling].
# Jitter spreads re-registration so a fleet-wide outage recovery doesn't thundering-herd.
compute_backoff() {
  local n="$1" ceil half jitter
  ceil="$(backoff_ceiling "$n")"
  half=$((ceil / 2))
  jitter=$((RANDOM % (half + 1)))
  echo $((half + jitter))
}

# Truncate one log in place once it exceeds MAX_LOG_BYTES, keeping the recent half
# as a single .1 archive. In-place truncation (not rename) keeps launchd's O_APPEND
# fd valid — launchd never reopens the file, and a renamed replacement would be
# root-owned and unwritable by this user LaunchAgent. Portable size check (wc -c).
rotate_one() {
  local f="$1" sz
  [ -n "$f" ] && [ -f "$f" ] || return 0
  sz="$(wc -c <"$f" 2>/dev/null | tr -d ' ')"
  [ -n "$sz" ] || sz=0
  if [ "$sz" -gt "$MAX_LOG_BYTES" ]; then
    tail -c "$((MAX_LOG_BYTES / 2))" "$f" >"$f.1" 2>/dev/null || true
    : >"$f"
  fi
}

rotate_logs() {
  rotate_one "${RUNNER_OUT_LOG:-}"
  rotate_one "${RUNNER_ERR_LOG:-}"
}

# One ephemeral registration + job. Returns non-zero (never aborts the loop) if
# registration fails, so the caller can back off instead of crash-looping.
register_and_run_once() {
  # Clear any stale local config left by an interrupted prior run so the
  # (ephemeral) re-registration below does not fail with "already configured"
  # (--replace only replaces the server-side runner, not the local config).
  rm -f .runner .credentials .credentials_rsaparams 2>/dev/null || true
  local token
  if ! token="$(fetch_token)"; then
    return 10
  fi
  if ! ./config.sh --url "https://github.com/$REPO" --token "$token" \
    --labels "$LABELS" --name "$RUNNER_NAME" \
    --unattended --replace --ephemeral; then
    return 11
  fi
  ./run.sh || true # processes one job then exits (ephemeral)
  return 0
}

main() {
  : "${REPO:?export REPO (owner/name, e.g. f5-sales-demo/code-review)}"
  # Self-locate per repo (e.g. f5-sales-demo/dns -> ~/actions-runner-dns), matching
  # how provision-repo-runner.sh stages each instance; override with RUNNER_DIR.
  RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-${REPO##*/}}"
  # Unique per repo so N instances on one host are distinguishable in the runner
  # list (default derives the repo short-name from REPO, e.g. .../dns -> dns).
  RUNNER_NAME="${RUNNER_NAME:-$(hostname)-${REPO##*/}}"
  REG_PAT_FILE="${REG_PAT_FILE:-$HOME/.config/code-review-runner/reg.pat}"
  cd "$RUNNER_DIR"

  local fails=0 delay
  while true; do
    rotate_logs
    if register_and_run_once; then
      fails=0
      sleep 2 # brief backoff before re-registering after a clean job
    else
      delay="$(compute_backoff "$fails")"
      fails=$((fails + 1))
      echo "runner: registration failed (consecutive=$fails); backing off ${delay}s" >&2
      sleep "$delay"
    fi
  done
}

# Only run the loop when executed directly; sourcing (unit tests) defines the
# helpers without side effects.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
