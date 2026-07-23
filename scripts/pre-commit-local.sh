#!/usr/bin/env bash
# Repo-local pre-commit hook body (invoked by the `local-hooks` entry in
# .pre-commit-config.yaml when present and executable). Runs every shell unit
# test in tests/ so runner-script logic is verified before each commit — the
# same tests the reusable Super-Linter "shell-unit-tests" job runs in CI.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
shopt -s nullglob
tests=(tests/test-*.sh)
if [ ${#tests[@]} -eq 0 ]; then
  exit 0
fi

rc=0
for t in "${tests[@]}"; do
  if bash "$t"; then
    echo "PASS: $t"
  else
    echo "FAIL: $t" >&2
    rc=1
  fi
done
exit "$rc"
