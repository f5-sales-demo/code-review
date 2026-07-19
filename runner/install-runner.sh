#!/usr/bin/env bash
# Idempotent: downloads the macOS runner, lays out the LaunchAgent. Re-runnable.
set -euo pipefail
: "${ORG:?export ORG}"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-code-review}"
VERSION="${RUNNER_VERSION:-2.321.0}" # bump deliberately; see runner/README.md
ARCH="$([[ "$(uname -m)" == arm64 ]] && echo arm64 || echo x64)"
mkdir -p "$RUNNER_DIR" && cd "$RUNNER_DIR"
if [[ ! -x ./run.sh ]]; then
  curl -fsSL -o runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-osx-${ARCH}-${VERSION}.tar.gz"
  tar xzf runner.tar.gz && rm runner.tar.gz
fi
# Ensure the pinned claude CLI exists for the workflow's path_to_claude_code_executable.
command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash
echo "Runner staged in $RUNNER_DIR. Install the LaunchAgent next (see runner/README.md)."
