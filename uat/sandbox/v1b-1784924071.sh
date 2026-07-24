#!/usr/bin/env bash
# v1b clean fixture (correct, obvious). NO linked issue on the PR (keeps it open).
set -euo pipefail
greet(){ printf 'Hello, %s!\n' "$1"; }
greet "${1:-world}"

# push 2/2: trivial no-op after a completed successful review (already-commented path)
