#!/usr/bin/env bash
# Correct behavior; unclear names only (a style nit, not a defect).
set -euo pipefail
f() {
  local a="$1" b="$2"
  echo "$((a + b))"
}
f "${1:-2}" "${2:-3}"
