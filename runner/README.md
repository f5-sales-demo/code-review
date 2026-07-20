# Self-hosted runner (native, as-user, ephemeral, repo-level)

This directory holds the scripts that stand up the native macOS GitHub Actions
runner used by the reusable `claude-review.yml` workflow. The runner runs **as
the operator's logged-in user**, inside the GUI login session, so Claude's Bash
tool inherits the operator's live `az` / `gh` / `terraform` sessions, the login
keychain, and VPN routing to the internal, VPN-only APIs a review must verify
against.

> **GitHub Free plan → repo-level runners.** GitHub Free does **not** dispatch
> **organization-level** self-hosted runners to **private** repositories (an
> online, correctly-labeled org runner never receives the job). Runners are
> therefore registered at the **repository** level. Each private repo that runs
> the reviewer needs its own repo-level runner instance (see
> [Reviewing more than one repo](#reviewing-more-than-one-repo)). Upgrading the
> org to GitHub Team would enable a single org-level runner instead.

- `install-runner.sh` — idempotent machine setup: downloads and stages the runner
  binary (with optional SHA-256 verification), confirms the pinned `claude` CLI is
  present, and builds the CA bundle Node needs behind a TLS-inspecting proxy.
- `run-ephemeral-loop.sh` — fetches a fresh **repo** registration token, configures
  the runner `--ephemeral`, processes exactly one job, de-registers, and repeats.
- `com.f5-sales-demo.code-review-runner.plist` — the user LaunchAgent that runs
  the loop in the login session (`SessionCreate=true` for keychain access), with
  `REPO` and `NODE_EXTRA_CA_CERTS` in its environment.

The runner registers with the labels `self-hosted,macOS,code-review`, matching
the workflow's `runs-on: [self-hosted, macOS, code-review]`. The `code-review`
label is registered in the repo-root `actionlint.yml` so `actionlint` accepts it.

## Prerequisites

- **macOS** on the operator's laptop, logged into the GUI as the runner user.
- **[Homebrew](https://brew.sh)** with the `claude` CLI installed at
  `/opt/homebrew/bin/claude`. The reusable workflow pins
  `path_to_claude_code_executable: /opt/homebrew/bin/claude`, and the LaunchAgent
  puts `/opt/homebrew/bin` first on `PATH`, so `claude` **must** resolve there for
  the runner user. `install-runner.sh` fails with instructions if `claude` is not
  found — it never pipes a remote installer to a shell on a credential-bearing host.
- **A PAT with repo admin**, written to a protected file for the loop. Fetching a
  repo registration token (`gh api -X POST repos/$REPO/actions/runners/registration-token`)
  needs repo-admin rights. The loop reads the PAT **only** for that call (inline,
  never exported), so it does not leak into job steps that run untrusted PR code:

  ```bash
  mkdir -p "$HOME/.config/code-review-runner"
  umask 077
  printf '%s' "<pat-with-repo-admin>" > "$HOME/.config/code-review-runner/reg.pat"
  chmod 600 "$HOME/.config/code-review-runner/reg.pat"
  ```

  (If the file is absent, the loop falls back to the ambient `gh` session, which
  must then have repo-admin rights itself.)
- **`az` logged in** (`az login`) and connected to the VPN, and `terraform`
  installed — these are what the reviewer uses to verify PRs.
- **CA bundle for Node.** Behind a TLS-inspecting proxy, Node-based actions
  (`claude-code-action`) fail with `self-signed certificate in certificate chain`
  even though `curl` works (cURL trusts the macOS keychain; Node uses its own CA
  store). `install-runner.sh` builds a bundle from the keychain and the LaunchAgent
  exports it via `NODE_EXTRA_CA_CERTS`.

## Operator inputs

Export these once in the shell you run the installer from:

```bash
export REPO="f5-sales-demo/code-review"   # the repo this runner serves (owner/name)
```

## Install

1. Stage the runner, confirm `claude`, and build the CA bundle:

   ```bash
   cd /Users/<you>/GIT/f5-sales-demo/code-review
   ./runner/install-runner.sh
   ```

   Downloads the runner into `$HOME/actions-runner-code-review` (override with
   `RUNNER_DIR`), pins the version via `RUNNER_VERSION`, optionally enforces
   `RUNNER_SHA256`, and writes the CA bundle to
   `$HOME/.config/code-review-runner/ca-bundle.pem` (override with `CA_BUNDLE`).

2. Write the registration PAT file (see Prerequisites) if you have not already.

3. Copy the loop script next to the runner binary:

   ```bash
   cp runner/run-ephemeral-loop.sh "$HOME/actions-runner-code-review/"
   chmod +x "$HOME/actions-runner-code-review/run-ephemeral-loop.sh"
   ```

4. Install the LaunchAgent, substituting `REPLACE_REPO` and `REPLACE_CA_BUNDLE`
   with the real values, then load it:

   ```bash
   plist="$HOME/Library/LaunchAgents/com.f5-sales-demo.code-review-runner.plist"
   sed -e "s#REPLACE_REPO#$REPO#" \
       -e "s#REPLACE_CA_BUNDLE#$HOME/.config/code-review-runner/ca-bundle.pem#" \
     runner/com.f5-sales-demo.code-review-runner.plist > "$plist"
   launchctl unload "$plist" 2>/dev/null || true
   launchctl load "$plist"
   ```

   The `sed` substitution is required: the committed plist ships the literal
   placeholders `REPLACE_REPO` / `REPLACE_CA_BUNDLE` so no host-specific detail is
   committed, and `launchctl` needs the resolved values in the installed copy under
   `~/Library/LaunchAgents/`.

## Verify

The runner should come online in the login session:

```bash
gh api repos/$REPO/actions/runners \
  --jq '.runners[] | {name, status, labels: [.labels[].name]}'
```

Expected: a runner named `<host>-code-review` with `status: online` (or `idle`)
and labels including `code-review`. If it is offline, check
`/tmp/code-review-runner.err.log`. If a self-hosted job shows `az` / `gh` as
unauthenticated, the LaunchAgent is not in the login session — confirm
`SessionCreate` is set and that the operator is logged into the GUI. If a
Node-based step fails with `self-signed certificate in certificate chain`, the CA
bundle or `NODE_EXTRA_CA_CERTS` path is wrong.

## Reviewing more than one repo

On GitHub Free each repo needs its own repo-level runner instance. Provision one
per repo with a single command — it stages the runner, renders a per-repo
LaunchAgent (unique `Label`, log paths, and `<host>-<repo>` runner name), and
loads it:

```bash
bash runner/provision-repo-runner.sh f5-sales-demo/dns
```

Re-running is safe (idempotent). Each instance shares the machine-wide review
concurrency cap (docs-control `scripts/review-slot.sh`), so no more than
`REVIEW_MAX_SLOTS` (default 5) reviews execute at once no matter how many repos
are onboarded — the rest queue.

Upgrading the org to GitHub Team would remove this per-repo multiplicity (one
org-level runner group serving all repos) and let GitHub queue jobs natively.

## The 30-day update window

The GitHub Actions runner auto-updates by default; the ephemeral loop re-runs
`config.sh` every iteration and picks up updates as they are published. If the
runner is ever configured with `--disableupdate`, GitHub still requires the runner
application to be updated **within 30 days** of a new release, or the runner is
dropped and stops accepting jobs. In that case, bump `RUNNER_VERSION` in
`install-runner.sh`, re-run the installer to re-stage the binary, and reload the
LaunchAgent within that window. Prefer leaving auto-update enabled.

## Accepted residual risk

This design runs an **agentic Claude with the operator's live `az` / `gh` /
`terraform` credentials on a laptop that cannot be re-imaged between jobs**. A
single in-job compromise is therefore a full-host compromise: `--ephemeral`
de-registers the runner after each job but does not wipe the machine. This is an
**accepted residual risk**, mitigated by defense in depth:

- **Private repositories only**, and a **repo-level** runner is inherently scoped
  to a single repository — no other repo can target it.
- **Fork guard.** The review job runs only when
  `github.event.pull_request.head.repo.full_name == github.repository`, so no fork
  PR ever reaches the runner.
- **Require approval for outside collaborators.** Configure the repo/org to require
  manual approval before workflows run for outside collaborators and first-time
  contributors.
- **Least-privilege `--allowedTools`.** The workflow allowlists only the specific
  `gh` / `git` / `az` / `terraform` command families the reviewer needs, rather
  than granting a blanket bypass.
- **`--permission-mode dontAsk`,** not a blanket permission bypass — the tool
  allowlist above is still enforced.
- **Registration PAT isolation.** The repo-admin PAT is read from a `0600` file
  inline for the token fetch only and never exported, so it does not reach job
  steps that execute untrusted PR code.
- **`--ephemeral` runner.** Each job runs on a freshly registered runner that
  de-registers on completion, bounding a compromise to a single job.
- **Terraform is plan / read-only in review.** A review job never runs
  `terraform apply`.

Prompt-injection defense (treating PR diffs, titles, descriptions, and comments as
untrusted data, never instructions) lives in `../REVIEW.md` and is the primary
control against the agentic-with-credentials threat model above.
