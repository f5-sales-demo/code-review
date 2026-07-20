#!/usr/bin/env bash
# A correct, clear helper: greet a named user.
set -euo pipefail
greet() {
  local name="$1"
  printf 'Hello, %s!\n' "$name"
}
greet "${1:-world}"
