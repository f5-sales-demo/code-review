# Self-hosted runner (native, as-user, ephemeral)

This directory holds the scripts that stand up the native macOS GitHub Actions
runner used by the reusable `claude-review.yml` workflow. The runner runs **as
the operator's logged-in user**, inside the GUI login session, so Claude's Bash
tool inherits the operator's live `az` / `gh` / `terraform` sessions, the login
keychain, and VPN routing to the internal, VPN-only APIs a review must verify
against.

- `install-runner.sh` — idempotent installer: downloads and stages the runner
  binary, and ensures the pinned `claude` CLI is present.
- `run-ephemeral-loop.sh` — fetches a fresh org registration token, configures
  the runner `--ephemeral`, processes exactly one job, de-registers, and repeats.
- `com.f5-sales-demo.code-review-runner.plist` — the user LaunchAgent that runs
  the loop in the login session (`SessionCreate=true` for keychain access).

The runner registers with the labels `self-hosted,macOS,code-review`, matching
the workflow's `runs-on: [self-hosted, macOS, code-review]`. The `code-review`
label is registered in the repo-root `actionlint.yml` so `actionlint` accepts it.

## Prerequisites

- **macOS** on the operator's laptop, logged into the GUI as the runner user.
- **[Homebrew](https://brew.sh)** with the `claude` CLI installed at
  `/opt/homebrew/bin/claude`. The reusable workflow pins
  `path_to_claude_code_executable: /opt/homebrew/bin/claude`, and the LaunchAgent
  puts `/opt/homebrew/bin` first on `PATH`, so `claude` **must** resolve there for
  the runner user. `install-runner.sh` only falls back to the official install
  script when no `claude` is found on `PATH`; on this host it is already present
  via Homebrew, so the fallback does not run.
- **`gh` authenticated with `admin:org`.** Fetching a runner registration token
  (`gh api -X POST orgs/$ORG/actions/runners/registration-token`) requires the
  `admin:org` scope. Before running the loop, the operator must either:

  ```bash
  unset GH_TOKEN                              # so gh uses the keyring, not a stale env token
  gh auth login -s admin:org,repo,workflow
  ```

  or export a personal access token that carries `admin:org`:

  ```bash
  export GH_TOKEN="<pat-with-admin:org>"
  ```

- **`az` logged in** (`az login`) and connected to the VPN, and `terraform`
  installed — these are what the reviewer uses to verify PRs.
- **An org runner group** scoped to selected private repositories only (create it
  in the org Actions settings, or via `gh api`). Public repositories must be
  disallowed for the group.

## Operator inputs

Export these once in the shell you run the installer from:

```bash
export ORG="f5-sales-demo"           # the GitHub org
export RUNNER_GROUP="code-review-private"   # the private-repo-scoped runner group
```

## Install

1. Stage the runner and ensure the `claude` CLI is present:

   ```bash
   cd /Users/<you>/GIT/f5-sales-demo/code-review
   ORG="$ORG" ./runner/install-runner.sh
   ```

   This downloads the runner into `$HOME/actions-runner-code-review` (override
   with `RUNNER_DIR`) and pins the runner version via `RUNNER_VERSION`.

2. Copy the loop script next to the runner binary:

   ```bash
   cp runner/run-ephemeral-loop.sh "$HOME/actions-runner-code-review/"
   chmod +x "$HOME/actions-runner-code-review/run-ephemeral-loop.sh"
   ```

3. Install the LaunchAgent, substituting `REPLACE_ORG` and `REPLACE_RUNNER_GROUP`
   with the real values, then load it:

   ```bash
   plist="$HOME/Library/LaunchAgents/com.f5-sales-demo.code-review-runner.plist"
   sed -e "s/REPLACE_ORG/$ORG/" -e "s/REPLACE_RUNNER_GROUP/$RUNNER_GROUP/" \
     runner/com.f5-sales-demo.code-review-runner.plist > "$plist"
   launchctl unload "$plist" 2>/dev/null || true
   launchctl load "$plist"
   ```

   The `sed` substitution is required: the committed plist ships the literal
   placeholders `REPLACE_ORG` / `REPLACE_RUNNER_GROUP` so no org detail is
   committed, and `launchctl` needs the resolved values in the installed copy
   under `~/Library/LaunchAgents/`.

## Verify

The runner should come online in the login session:

```bash
gh api orgs/$ORG/actions/runners \
  --jq '.runners[] | {name, status, labels: [.labels[].name]}'
```

Expected: a runner named `<host>-code-review` with `status: online` (or `idle`)
and labels including `code-review`. If it is offline, check
`/tmp/code-review-runner.err.log`. If a self-hosted job shows `az` / `gh` as
unauthenticated, the LaunchAgent is not in the login session — confirm
`SessionCreate` is set and that the operator is logged into the GUI.

## The 30-day update window

The GitHub Actions runner auto-updates by default; the ephemeral loop re-runs
`config.sh` every iteration and picks up updates as they are published. If the
runner is ever configured with `--disableupdate`, GitHub still requires the
runner application to be updated **within 30 days** of a new release, or the
runner is dropped and stops accepting jobs. In that case, bump `RUNNER_VERSION`
in `install-runner.sh`, re-run the installer to re-stage the binary, and reload
the LaunchAgent within that window. Prefer leaving auto-update enabled.

## Accepted residual risk

This design runs an **agentic Claude with the operator's live `az` / `gh` /
`terraform` credentials on a laptop that cannot be re-imaged between jobs**. A
single in-job compromise is therefore a full-host compromise: `--ephemeral`
de-registers the runner after each job but does not wipe the machine. This is an
**accepted residual risk**, mitigated by defense in depth:

- **Private repositories only.** The org runner group is scoped to selected
  private repos and disallows public repositories, so no public PR can target the
  runner.
- **Fork guard.** The review job runs only when
  `github.event.pull_request.head.repo.full_name == github.repository`, so no
  fork PR ever reaches the runner.
- **Require approval for outside collaborators.** The org is configured to
  require manual approval before workflows run for outside collaborators and
  first-time contributors.
- **Least-privilege `--allowedTools`.** The workflow allowlists only the specific
  `gh` / `git` / `az` / `terraform` command families the reviewer needs, rather
  than granting a blanket bypass.
- **`--permission-mode dontAsk`,** not a blanket permission bypass — the tool
  allowlist above is still enforced.
- **`--ephemeral` runner.** Each job runs on a freshly registered runner that
  de-registers on completion, bounding a compromise to a single job.
- **Terraform is plan / read-only in review.** A review job never runs
  `terraform apply`.

Prompt-injection defense (treating PR diffs, titles, descriptions, and comments
as untrusted data, never instructions) lives in `../REVIEW.md` and is the primary
control against the agentic-with-credentials threat model above.
