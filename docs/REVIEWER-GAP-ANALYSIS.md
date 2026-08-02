# Reviewer Gap Analysis (improvement iteration WS0)

This document is the WS0 deliverable of a deliberate improvement iteration on the
fleet's automated PR reviewer. It (1) catalogs modern requirements for a
sophisticated PR / CI-driven code reviewer, drawn from the state of the art,
(2) cross-references them against what this fleet actually runs today, and
(3) records the pre-existing defects the audit **verified with live evidence**
before any fix (the "no claims without proof" rule).

The sequenced fix program (workstreams WS1–WS6) is tracked in the linked issues.

## Systems surveyed

Anthropic `claude-code-action` + the `code-review` plugin +
`claude-code-security-review`; Cloudflare's CI-native AI reviewer; CodeRabbit;
Greptile; Graphite Diamond; Qodo Merge; GitHub Copilot code review;
Sourcery/Ellipsis/Cursor Bugbot. Deterministic backbone: CodeQL, Semgrep,
SonarQube, Snyk (correctness/security); Knip, Vulture (dead code); jscpd,
PMD CPD (duplication); gitleaks, Checkov, Trivy, tfsec, zizmor, actionlint,
Syft/Grype (security/supply chain).

## Requirements catalog (by theme)

- **A. Correctness/logic**: bugs beyond syntax; cross-file/codebase-graph
  reasoning; whole-repo (not diff-only) context; convention violations;
  data-flow/taint; rules-based bug engine; business-logic flaws
  (race/TOCTOU/IDOR/auth-bypass); read source to verify low-confidence findings;
  test-coverage-gap flags.
- **B. Dead/orphaned code**: unused exports/files/deps (JS/TS, monorepo-aware);
  dead Python (confidence-scored); dead code for compiled langs; reviewer flags
  code the diff newly orphans; exclude generated/vendored/minified.
- **C. DRY/duplication**: token clone detection; near-match/structural clones;
  duplication quality-gate threshold; reviewer flags reinvented logic that
  duplicates existing repo utilities.
- **D. YAGNI/overengineering**: speculative generality / premature abstraction;
  unrequested "just-in-case" features; correctly scoped (don't punish tests,
  security baseline, genuine interfaces); KISS complexity flags.
- **E. Security/SAST/supply-chain**: OWASP SAST classes; secret scanning; IaC
  misconfig (multi-ruleset); Actions-workflow security; dependency SCA + license;
  SBOM + CVE monitoring; container scan; SARIF → Code Scanning; always-on
  security reviewer on sensitive paths; tunable FP filtering; custom rules;
  merge-blocking security gate.
- **F. Review UX/workflow**: auto-review every PR; incremental diff-aware
  re-review; auto-resolve fixed threads / re-emit unfixed / respect
  user-resolved; dedup findings into one structured review; severity taxonomy;
  inline line-anchored comments; committable fixes; PR summary/walkthrough;
  diagrams; slash commands; path filters + path-scoped instructions; custom
  instructions from repo files; configurable verbosity; request-changes/approve;
  pre-merge hygiene checks; finishing touches; required-check integration;
  break-glass with telemetry; aggregate external linters; sticky progress
  comment; safer path for forked PRs.
- **G. Learning/memory**: learn from resolved comments; knowledge base; read dev
  replies and re-decide; enforce team guidelines.
- **H. Reliability/ops/cost/scale**: risk-tiered depth; timeouts; model
  fallback/circuit breaker; prompt caching; tiered model by difficulty;
  concurrency/cancel-stale; fast turnaround at scale; observability/telemetry;
  composable plugin architecture; multi-provider auth; least-privilege.
- **I. AI-specific safeguards**: prompt-injection hardening; restrict to trusted
  PRs / approve forks; tool/permission restriction; confidence-based FP
  filtering; multi-agent specialized decomposition; coordinator/aggregator;
  semantic intent-aware analysis; actionability; human-in-the-loop; agent with
  live shell to verify.

## Cross-reference (✅ covered · 🟨 partial · ❌ gap)

| Area | Status | Evidence / note |
| --- | --- | --- |
| Logic/security bug detection (A1,A7) | ✅ | Bug agents 3+4 (opus) + validation pass — `plugins/f5-review/.../commands/code-review.md` |
| Cross-file / whole-repo context (A2,A3) | 🟨 | Bug agents are deliberately diff-only; no codebase-graph pass |
| Data-flow/taint, rules engine (A5,A6) | ❌ | No CodeQL/Semgrep/Sonar (grep-confirmed fleet-wide) |
| Authenticated "prove it works" (A8,I10) | ✅ | Agent 5 runs real `terraform plan`/`az`/`gh` — unique to this fleet |
| Unused exports/files JS/TS (B1,B2) | ❌ | No Knip/ts-prune; only Biome in-file `noUnused*` |
| Dead Python (B3) | 🟨 | Ruff `ERA`/`F401`/`F841`/`ARG`; no cross-module (Vulture) |
| Reviewer flags diff-orphaned code (B5) | ❌ | Not a review dimension |
| Duplication / DRY (C1,C3) | ✅ | jscpd @ threshold 10 (`.jscpd.json`) merge-gating via lint |
| Near-match clones, reinvented logic (C2,C4) | ❌ | No structural clone / semantic-DRY review |
| YAGNI / overengineering (D1–D4) | 🟨 | Prose policy only (CLAUDE.md); not a reviewer dimension |
| Secret / IaC / Actions security (E2,E3,E4,E7) | ✅ | gitleaks, Checkov, Trivy, zizmor, actionlint |
| Dedicated SAST, SCA, SBOM, SARIF (E1,E5,E6,E8) | ❌ | None beyond Ruff-`S`/Checkov/Trivy |
| Merge-blocking gate (E12) | ✅ | 🔴 blocks via `parse-verdict.sh` |
| Incremental re-review / thread lifecycle (F2,F3) | ❌ | **VERIFIED DEFECT — deadlock (see below)** |
| Severity taxonomy (F5) | 🟨 | `medium` in schema is a **dead field** (see below) |
| Inline comments, committable fixes (F6,F7) | ✅ | MCP inline + suggestion blocks |
| Required-check integration, fork guard (F17,F21,I2) | ✅ | `additional_contexts` + fork hard-guard |
| Learning/memory (G1–G4) | ❌ | None |
| Timeouts, concurrency, plugin arch (H2,H6,H9) | ✅ | Step/job timeouts, per-PR cancel + slot semaphore |
| Model fallback (H3), blast radius (H7) | ❌🟨 | Single gateway model; single-laptop runner SPOF |
| Prompt-injection, FP filtering, multi-agent (I1,I4,I5) | ✅🟨 | Instruction-based injection guard; validation pass; 5 agents |

## Verified pre-existing defects (evidence before fix)

**V1 — Re-push deadlock (CONFIRMED, severe).** On a second push to an
already-reviewed, still-open PR, the reviewer's triage stops ("Claude has already
commented … stop and do not proceed") **without emitting `verdict.json`**; the
workflow's `Gate on verdict` step then treats the missing verdict as blocking and
fails the required `review / claude-review` check — permanently, since re-pushing
repeats it. Reproduced live on `f5-sales-demo/code-review`:

- push 1 (clean): review `success`, summary posted, verdict written, gate passes.
- push 2 (trivial): review job **failure**; step conclusions show
  `Claude review = success` (graceful stop), `Classify first-attempt failure =
  skipped`, **`Gate on verdict = failure`** (run `30123694613`).

Why the fleet mostly works despite this: clean PRs auto-merge on the first green
before any second push; the deadlock bites PRs that are re-pushed after a first
review (e.g., fixing a flagged 🔴). Fix: WS1-PR1a (always emit a verdict, even on
skip; incremental re-review).

**V2 — Dead `medium` severity (CONFIRMED).** The rubric maps findings only to
`high` (🔴) or `low` (🟡); `medium` appears solely in the schema example and is
never emitted. `parse-verdict.sh` gates only on `high`. Running the real gate on a
crafted `medium` verdict exits 0 (non-blocking). So `medium` is unreachable. Fix:
WS1-PR1b (activate a real 3-tier taxonomy).

**V3 — No dedicated SAST / cross-module dead-code tooling (CONFIRMED).** A
fleet-wide grep for `codeql|semgrep|knip|ts-prune|vulture` matches only an
icon-data entry in `docs-icons`; no tool config exists. Fix: WS3 (Knip, Python
dead-code) + WS4 (Semgrep/CodeQL).

**V4 — Baseline captured.** 38/38 repos gated, all enforced, one online runner
each, no drift. Performance sampled per repo (p50/p90, block counts). The
"one runner each × 38, one host" quantifies the WS6 blast-radius single point of
failure.

**Bonus — UAT auto-merge debris (CONFIRMED).** `run-uat.sh` all-green scenarios
(clean/nit/sync) pass every required check, so auto-merge merges them **before**
the harness's cleanup can close the PR, leaving scratch files under
`uat/sandbox/` on `main`. `uat/sandbox/` cannot simply be gitignored (the harness
`git add`s those files to form each PR diff). Root-cause fix: exclude UAT branches
from auto-merge so throwaway PRs never merge (companion docs-control change);
this file's PR removes the accumulated debris.

## Program roadmap

WS1 reviewer correctness (deadlock, severity taxonomy, branch-prefix bypass) →
WS2 trusted base-pinned `verify.sh` pre-step → WS3 dead/orphaned code (Knip +
Python) → WS4 dedicated SAST (Semgrep/CodeQL + SCA/SBOM) → WS5 YAGNI + semantic
DRY reviewer dimensions → WS6 reliability/ops (org runner pool, telemetry, model
fallback). Deferred as YAGNI for a demo fleet: diagrams, interactive
slash-commands, verbosity profiles, learnings/memory, cost-tiering (revisit if
Opus spend or latency warrants — WS6 telemetry will tell).
