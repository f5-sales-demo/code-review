#!/usr/bin/env bash
# Exit 0 only when the given config file exists and is non-empty; otherwise exit 1.
set -euo pipefail
config="${1:?usage: example-check.sh <path>}"
if [[ ! -s "$config" ]]; then
  echo "config OK"
  exit 0
fi
echo "config missing or empty" >&2
exit 1
