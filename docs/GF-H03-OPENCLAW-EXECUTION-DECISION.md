# GF-H03 OpenClaw execution decision

Status: canonical production policy.

## Incident RCA

Installed version: OpenClaw 2026.7.1-2. Its `agent --help` documents `--local` as the embedded-agent mode. Inspection of the installed client shows that `--timeout` covers the agent run, not merely Gateway connection establishment. The old Game Foundry command nested an 840-second OpenClaw timeout inside a 900-second shell timeout. OpenClaw did not enter its automatic embedded fallback until the Gateway run timed out, leaving at most about 60 seconds of the outer budget.

Attempt 1 is proven by the exact-session audit as `agent.run.started` followed by `agent.run.finished` with `timed_out`. Attempt 2's Gateway process is proven to have terminated on an uncaught `UNKNOWN: unknown error, write`, after reaching a 9.5 GB memory peak; systemd then restarted it and the client observed WebSocket 1006. No `agent.run.started`, candidate mutation, or branch movement exists for attempt 2, so that attempt was pre-start. The installed session admission guard emits “session changed while starting work” when the stored session ID differs from the prepared ID. In this incident the Gateway death followed by automatic fallback is consistent with an ownership/persistence race, but the precise writer is not proven.

A CLI transport failure can occur after Codex starts. It must therefore never imply that a new execution is safe. A live process, a Codex-tagged session entry, or candidate mutation proves or makes start ambiguous.

## Supported mode comparison

| Mode | Reliability and session semantics | Provenance | Shared-service and duplicate risk |
|---|---|---|---|
| Gateway-first with OpenClaw automatic fallback | One command owns a Gateway session, then creates a fallback session only after failure. The primary can consume the full run timeout. | Gateway audit and result can prove Codex. | Gateway crash/reload and late ownership transfer create shared-service and ambiguous duplicate risk. |
| Explicit `openclaw agent --local` | Supported embedded agent from the outset; one scoped session and no transport handoff. | JSON result plus the scoped session store record `agentHarnessId=codex` prove OpenClaw orchestration and Codex runtime. | Does not depend on or restart the shared Gateway; lowest ownership complexity. |
| Game Foundry-managed Gateway then local fallback | Separate budgets are possible, but Game Foundry must prove the Gateway execution never started before local dispatch. | Both paths can prove Codex. | Two authoritative routes substantially increase reconciliation and duplicate-execution risk. |

## Decision

`GAME FOUNDRY OPENCLAW EXECUTION MODE = explicit local OpenClaw with Codex runtime`

Game Foundry invokes `openclaw agent --local` only. It does not use OpenClaw's implicit Gateway fallback and does not automatically restart, reset, or clean the shared Gateway. Gateway health is recorded only as observational evidence.

The stable `game-foundry` agent must already point at the stable agent workspace and declare the selected model's `agentRuntime.id=codex`. Production execution verifies configuration; it does not rewrite global OpenClaw configuration. Only the workspace symlink inside the stable agent workspace is scoped to the isolated Git worktree and restored afterward.

## Timing and session policy

- Each preflight command: 20 seconds. The two runtime-dependent checks (plugin and auth) permit one bounded pre-start retry, so transient CLI contention cannot consume a feature attempt. Preflight verifies CLI support, stable agent configuration, Codex plugin, and usable runtime auth.
- Admission/start proof: 30 seconds, using the exact scoped session-store entry.
- Healthy agent execution: 1800 seconds. This is separate from admission and exceeds the observed legitimate 840-second workload.
- Outer safety: 1830 seconds.
- Reconciliation: 30 seconds.
- Fallback: disabled (zero seconds) because there is only one authoritative route.

Each logical call uses `agent:game-foundry:<logical-run>-transport-<NN>`. Session inspection is tri-state: `PRESENT`, `ABSENT`, or `UNAVAILABLE`. Only `ABSENT` permits initial dispatch; `UNAVAILABLE` after dispatch is unresolved ambiguity and never permits another generation. A new generation is permitted only after `SAFE_NOT_STARTED`; an ambiguous session is never reused. Production retry and timeout values are locked constants rather than environment-overridable defaults.

## Exactly-once and accounting contract

A new Codex dispatch is safe only when the preceding generation has no exact-session admission, no surviving process in its isolated process group, no dirty/untracked worktree state, and no worktree HEAD movement from the recorded pre-task commit. This is `SAFE_NOT_STARTED`. It permits at most one additional transport generation and does not consume a feature attempt. If both bounded generations are provably pre-start, the task returns to READY without incrementing its feature-attempt counter. The original stable workspace symlink target is captured before dispatch and restored exactly during cleanup.

Any start proof or ambiguity is a feature execution. `STARTED_NO_RESULT` and `UNRESOLVED_AMBIGUITY` escalate without rerun. `CANDIDATE_PRESENT_RESULT_LOST` is snapshotted before escalation; it is never accepted without normal runtime, validation, critic, and commit proof. `COMPLETED_RESULT_RECOVERABLE` continues the existing candidate.

GF-008 may recreate/restart only from `CLAIMED` or `WORKTREE_READY`. `AGENT_STARTED` and `AGENT_COMPLETED` are ambiguous without stronger persisted evidence and therefore escalate rather than launching Codex again.
