#!/usr/bin/env bash
# Reads a Claude structured verdict JSON and fails on blocking findings.
# Usage: parse-verdict.sh <verdict.json>  (defaults to verdict.json)
set -euo pipefail
f="${1:-verdict.json}"
if [[ ! -s "$f" ]]; then
  echo "::error::verdict file '$f' missing or empty — treating as blocking"
  exit 1
fi
blocking=$(jq -r '.blocking // false' "$f")
high=$(jq -r '.severity_counts.high // 0' "$f")
echo "verdict: blocking=$blocking high=$high"
jq -r '.findings[]? | "- [\(.severity)] \(.title) (\(.location // "n/a"))"' "$f" || true
if [[ "$blocking" == "true" || "$high" -gt 0 ]]; then
  echo "::error::Claude Review found $high blocking (🔴) finding(s) — failing check."
  exit 1
fi
echo "Claude Review: no blocking findings."
