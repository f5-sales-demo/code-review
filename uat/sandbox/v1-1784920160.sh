#!/usr/bin/env bash
# v1-repro clean fixture: correct, obvious behavior (first review should PASS).
set -euo pipefail
greet() { printf 'Hello, %s!\n' "$1"; }
greet "${1:-world}"
