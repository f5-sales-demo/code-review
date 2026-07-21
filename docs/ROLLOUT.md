# Rolling out the PR reviewer to the fleet

This runbook onboards docs-control-governed repos to the self-hosted Claude PR
reviewer as a **blocking** required check. It is validated by the UAT harness
(`uat/run-uat.sh`) and gated on the review criteria locked in
`docs-control tests/test-parse-verdict.sh`.

## Model & constraints (measured)

- GitHub **Free** → org-level runners do not dispatch to private repos, so **each
  onboarded repo needs its own repo-level runner** on this laptop.
- Feasible fleet-wide: an idle runner listener is ~70-80 MB RSS; ~38 repos ≈ **2.9 GB**
  on a 32 GB machine. The `review-slot` semaphore caps **concurrent** reviews at
  `REVIEW_MAX_SLOTS` (default 5); the rest queue.
- **Blast radius:** once `review / claude-review` is *required* on a repo, that
  repo's PRs cannot merge unless its runner is **online**. If the laptop is off,
  those PRs block. Roll out in **verified batches**, not one big-bang, and keep the
  runners' LaunchAgents loaded.

## Per-repo onboarding (one batch at a time)

For a batch of repo short-names (`R1 R2 ...`):

1. **Runners** — one per repo on this laptop:

   ```bash
   bash runner/provision-all-runners.sh R1 R2      # or no args = whole fleet
   ```

2. **Secrets/vars** — the gateway key + URL (config only audits, never sets values):

   ```bash
   export F5_GATEWAY_TOKEN=sk-...    F5_GATEWAY_URL=https://f5ai.pd.f5net.com/anthropic
   bash runner/set-review-secrets.sh R1 R2
   ```

3. **Governance config** (in `docs-control`, via PR → merge; the sync fan-out then
   delivers the caller + enforces the required context). In
   `.github/config/repo-settings.json`:
   - add each repo to the `managed_files` entry for `workflows/code-review.yml`
     (`only_repos`), so the caller workflow syncs to it;
   - add a `repo_overrides` entry per repo:
     `"R1": { "additional_contexts": ["review / claude-review"] }` (this makes the
     check **required/blocking**);
   - add `claude_review` to each repo's `repo_roles` (so the secrets audit expects
     `F5_GATEWAY_TOKEN`).
4. **Smoke** — prove the batch before moving on:

   ```bash
   UAT_REPO=f5-sales-demo/R1 bash uat/run-uat.sh
   ```

   Confirm the matrix passes (linked-issue blocks a missing issue; the reviewer
   blocks a planted bug and refuses injection with no leak; automated branches
   bypass). Only then widen to the next batch.

## Verify a repo is live

```bash
gh api repos/f5-sales-demo/<repo>/actions/runners --jq '.runners[]|"\(.name) \(.status)"'
gh api repos/f5-sales-demo/<repo>/branches/main/protection \
  --jq '.required_status_checks.contexts'
```

Expect an online `<host>-<repo>` runner and `review / claude-review` +
`check / Check linked issues` among the required contexts.

## Whole-fleet note

`provision-all-runners.sh` / `set-review-secrets.sh` with no args target every repo
in `downstream-repos.json`. Prefer stepping through batches and smoke-testing each,
so a bad batch never blocks the whole fleet's merges. A GitHub **Team** upgrade
(org-level runner group) would replace the per-repo laptop runners with one shared
pool and let GitHub queue jobs natively — the recommended path if fleet-wide
blocking review becomes permanent.
