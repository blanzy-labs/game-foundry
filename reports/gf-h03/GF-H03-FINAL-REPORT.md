# GF-H03 Final Report

## GF-H03 Status

**GF-H03 PASS WITH WARNINGS**

Commit: `GF-H03: harden OpenClaw execution transport` (current commit)

## Incident RCA

### Proven

1. Attempt 1 used an 840-second OpenClaw agent-run timeout inside a 900-second shell timeout. Installed OpenClaw 2026.7.1-2 applies `--timeout` to the whole Gateway agent run, not only connection startup. Exact-session audit recorded `agent.run.started` followed by `agent.run.finished` with `timed_out`.
2. OpenClaw entered automatic embedded fallback only after the Gateway run failed. Roughly 30–60 seconds remained in Game Foundry's outer budget, so fallback did not receive a viable implementation budget.
3. Attempt 2's Gateway process terminated on an uncaught `UNKNOWN: unknown error, write`; systemd recorded a 9.5 GB memory peak and restarted the service. The client consequently observed WebSocket 1006. Attempt 2 had no exact-session `agent.run.started`, no workspace mutation, and no branch movement, so it was pre-start.
4. Installed OpenClaw explicitly supports `openclaw agent --local`. A real probe proved OpenClaw remained the orchestrator and the persisted session/result identified `agentHarnessId=codex` and embedded execution.

### Likely

The “Session changed while starting work” error is consistent with the Gateway crash followed by automatic fallback replacing or racing the prepared session entry. Installed source proves the guard compares the prepared session ID with the latest stored session ID, but the exact writer in this incident was not captured.

### Unknown / bounded safely

A failed CLI transport cannot generically prove that Codex stopped or never mutated the candidate. GF-H03 therefore treats exact-session admission, unavailable session evidence, surviving process-group members, dirty/untracked files, or HEAD movement as started/ambiguous. It never launches another implementation call from those states.

## Canonical Resolution

`GAME FOUNDRY OPENCLAW EXECUTION MODE = explicit local OpenClaw with Codex runtime`

- Preflight verifies the installed CLI and `--local`, stable scoped agent configuration, readable session store, loaded Codex plugin, and usable OpenAI/Codex runtime auth.
- Production dispatch uses only `openclaw agent --local`; implicit Gateway fallback is disabled.
- Each dispatch gets a unique exact session key and isolated process group.
- Gateway status is observational only. Game Foundry never restarts, resets, deletes, or rewrites shared Gateway/session state.
- The installed agent's workspace symlink is changed only for the isolated worktree and restored to its exact prior target.
- Session evidence is tri-state: `PRESENT`, `ABSENT`, or `UNAVAILABLE`. Only proven `ABSENT` permits initial dispatch; unavailable evidence after dispatch escalates.

## Exactly-Once Contract

Another Codex implementation is safe only when the prior generation is provably `SAFE_NOT_STARTED`: no exact-session admission, no surviving member of its isolated process group, no dirty/untracked candidate state, and no worktree HEAD movement from the recorded pre-task commit. Any missing or contradictory proof is ambiguity and forbids rerun.

## Failure Classification

| Classification | Action |
|---|---|
| `SAFE_NOT_STARTED` | At most one new transport generation; feature attempt remains unchanged. |
| `STARTED_NO_RESULT` | Escalate; count the feature attempt; never blind-rerun. |
| `CANDIDATE_PRESENT_RESULT_LOST` | Snapshot dirty or clean-committed candidate, then escalate; never accept without proof. |
| `COMPLETED_RESULT_RECOVERABLE` | Continue the existing candidate through normal validation/critic/commit gates. |
| `UNRESOLVED_AMBIGUITY` | Escalate; count an ambiguous start where applicable; no rerun or commit. |

## Timeout Policy

- Preflight command timeout: 20 seconds. Plugin and auth checks permit one bounded pre-start retry. The theoretical worst-case preflight ceiling is 140 seconds; observed final smoke preflight was 8.47–8.57 seconds.
- Dispatch/admission timeout: 30 seconds.
- Healthy agent execution timeout: 1800 seconds.
- Outer safety timeout: 1830 seconds.
- Reconciliation policy bound: 30 seconds; current reconciliation uses local process/session/Git checks and completes immediately.
- Fallback timeout: 0 seconds; fallback is intentionally absent because explicit local mode is canonical.

All production values are locked constants.

## Session Policy

- Logical call: GF-004 run/stage identifier.
- Session: `agent:game-foundry:<logical-run>-transport-<NN>`.
- Maximum transport generations: 2.
- A new generation is allowed only after `SAFE_NOT_STARTED`; an ambiguous session is never reused.
- Game Foundry performs no global session deletion and no automatic Gateway restart, preserving future Media Foundry workloads.

## Fault Matrix

| Required case | Result |
|---|---|
| Healthy execution | PASS |
| Gateway unavailable pre-start | PASS (`SAFE_NOT_STARTED`) |
| WebSocket 1006 pre-start | PASS (`SAFE_NOT_STARTED`) |
| Session changed during start | PASS (new generation only when absence is proven) |
| Transport lost after Codex start | PASS (escalate; zero duplicate starts) |
| Candidate produced/result lost | PASS (snapshot and escalate) |
| Unresolved ambiguity | PASS (escalate) |
| Fallback budget/replacement | PASS (fallback removed; one local route owns full budget) |
| Shared Gateway safety | PASS (no shared state mutation/restart) |
| Feature retry accounting | PASS (pre-start transport does not increment; ambiguous start does) |
| Clean committed candidate mutation | PASS (HEAD movement detected) |
| Surviving process group | PASS (retry refused) |
| Corrupt/unavailable session store | PASS (`UNRESOLVED_AMBIGUITY`) |

## Real Smoke Proof

- Runs attempted: 3
- Runs passed: 3
- Runs failed: 0
- Codex starts: 3
- Candidate mutations: 3
- Duplicate starts: 0
- Session conflicts: 0
- Gateway failures: 0
- Human implementation interventions: 0

## Repeatability

- Deterministic runs: 20
- PASS: 20
- FAIL: 0

## Regression

| Suite | Result |
|---|---|
| GF-004 | PASS |
| GF-005 | PASS |
| GF-006 | PASS |
| GF-007 | PASS |
| GF-008 | PASS |
| GF-H02 | PASS |
| GF-H03 | PASS |
| Doctor | PASS (30 critical, 0 failed) |

## Files Changed

- `docs/GF-H03-OPENCLAW-EXECUTION-DECISION.md`
- `reports/gf-h03/GF-H03-FINAL-REPORT.md`
- `scripts/doctor.sh`
- `scripts/gf-008-acceptance.sh`
- `scripts/gf-h03-acceptance.sh`
- `scripts/gf-h03-critic.sh`
- `scripts/gf-h03-real-smoke.sh`
- `scripts/gf-milestone.sh`
- `scripts/gf-openai-critic.py`
- `scripts/lib/gf-004-execution.sh`
- `scripts/lib/gf-005-runner.sh`
- `scripts/lib/gf-008-recovery.sh`
- `scripts/lib/gf-h03-transport.sh`
- `scripts/lib/milestone-common.sh`

No Turd Burglar or TB-R08 files changed. No TB-R08-M002 was created or executed.

## Evidence

- RCA local probe: `artifacts/gf-h03/rca-local-probe/`
- Decision record: `docs/GF-H03-OPENCLAW-EXECUTION-DECISION.md`
- Deterministic fault matrix and 20-run soak: `artifacts/gf-h03/acceptance-20260825T193125Z-4006186/`
- Final real OpenClaw/Codex smoke: `artifacts/gf-h03/real-smoke-20260825T193522Z-4012280/`
- Session/transport/timing JSON: the real-smoke `transports/run-*-agent-transport.json` files, summarized by `result.json`
- GF-004: `artifacts/gf-004/gf004-acceptance-20260825T174402Z-ac5ea9/`
- GF-005: `artifacts/gf-005/gf005-acceptance-20260825T175910Z-15ef82/`
- GF-006: `artifacts/gf-006/gf006-acceptance-20260825T180627Z-49eab4/`
- GF-007: `artifacts/gf-007/gf007-acceptance-20260825T181825Z-11011b/`
- GF-008: `artifacts/gf-008/gf008-acceptance-20260825T185522Z-0a380f/`
- GF-H02: `artifacts/gf-h02/gfh02-acceptance-20260825T184612Z/`
- Final doctor: `artifacts/gf-h03/doctor-final.json`
- First critic incomplete evidence: `artifacts/gf-h03/critic-20260825T191825Z-3983267/`
- First blocking safety review: `artifacts/gf-h03/critic-20260825T191922Z-3984180/`
- Second blocking safety review: `artifacts/gf-h03/critic-20260825T192547Z-3996310/`
- Accepted independent safety review: `artifacts/gf-h03/critic-20260825T193135Z-4008524/`

## Recommendation

1. **Yes.** The OpenClaw/Gateway/session failure class is sufficiently resolved to authorize another autonomous feature milestone, subject to the human approval gate below.
2. **Yes.** After human approval, TB-R08 should be rerun as a fresh `TB-R08-M002` from the trusted base. GF-H03 did not create or execute it.
3. Residual failure modes: provider/auth outages cause bounded preflight refusal; session-store corruption or process/session ambiguity causes safe escalation; kernel-level escape outside the isolated process group remains a conservative operational risk; rare mid-execution transport races have deterministic rather than destructive live fault coverage; `/tmp` was near quota, so long acceptance runs used workspace-backed `TMPDIR`.

`HUMAN EXECUTION-RELIABILITY APPROVAL = PENDING`
