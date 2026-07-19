#!/usr/bin/env bash
# Idempotent machine setup for a native repo-level runner: downloads the macOS
# runner and builds the CA bundle Node needs behind a TLS-inspecting proxy.
# Re-runnable. Registration/launch is done by the LaunchAgent (see runner/README.md).
set -euo pipefail
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-code-review}"
VERSION="${RUNNER_VERSION:-2.335.1}" # bump deliberately; see runner/README.md
ARCH="$([[ "$(uname -m)" == arm64 ]] && echo arm64 || echo x64)"
mkdir -p "$RUNNER_DIR" && cd "$RUNNER_DIR"
if [[ ! -x ./run.sh ]]; then
  curl -fsSL -o runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-osx-${ARCH}-${VERSION}.tar.gz"
  # Integrity check. Set RUNNER_SHA256 to the value published on the release page
  # (https://github.com/actions/runner/releases/tag/v${VERSION}) to enforce it.
  computed="$(shasum -a 256 runner.tar.gz | awk '{print $1}')"
  echo "Downloaded runner SHA-256: ${computed}"
  if [[ -n "${RUNNER_SHA256:-}" ]]; then
    if [[ "${computed}" != "${RUNNER_SHA256}" ]]; then
      echo "ERROR: runner tarball SHA-256 mismatch (expected ${RUNNER_SHA256})." >&2
      rm -f runner.tar.gz
      exit 1
    fi
    echo "Runner tarball integrity verified."
  else
    echo "WARNING: RUNNER_SHA256 not set - skipping integrity enforcement." \
      "Compare the hash above against the release page before trusting it." >&2
  fi
  tar xzf runner.tar.gz && rm runner.tar.gz
fi
# The reviewer workflow pins path_to_claude_code_executable=/opt/homebrew/bin/claude,
# so the Claude CLI must already be installed for the runner user. We deliberately do
# NOT pipe a remote installer to a shell on a machine that holds live cloud
# credentials (supply-chain risk). Install it out-of-band, then re-run this script.
if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: 'claude' CLI not found on PATH." >&2
  echo "Install the Claude CLI via your trusted channel (e.g. Homebrew, or" >&2
  echo "Anthropic's official install instructions), then re-run this script." >&2
  exit 1
fi
# Build the CA bundle so Node-based actions (claude-code-action) trust the corporate
# / TLS-inspection CA. curl succeeds via the macOS keychain, but Node uses its own
# CA store and otherwise fails with "self-signed certificate in certificate chain".
CA_BUNDLE="${CA_BUNDLE:-$HOME/.config/code-review-runner/ca-bundle.pem}"
mkdir -p "$(dirname "$CA_BUNDLE")"
if [[ ! -s "$CA_BUNDLE" ]]; then
  security find-certificate -a -p \
    /System/Library/Keychains/SystemRootCertificates.keychain >"$CA_BUNDLE"
  security find-certificate -a -p /Library/Keychains/System.keychain >>"$CA_BUNDLE"
  echo "Wrote CA bundle ($(grep -c 'BEGIN CERT' "$CA_BUNDLE") certs) to ${CA_BUNDLE}"
fi
echo "Runner staged in ${RUNNER_DIR}. Install the LaunchAgent next (see runner/README.md)."
