# GF-005 — Bounded Chained Execution

GF-005 adds an explicit sequential runner:

```bash
./scripts/gf-milestone.sh run-bounded GF-CHAIN-M001 --max-tasks 2 --max-minutes 30
```

Defaults are deliberately finite: three attempted tasks and 30 minutes. Both options accept positive integers only; zero, negative, missing, and non-numeric values are rejected without changing state.

## Flow and authority

The runner does not implement tasks. Before each attempt it calls the existing status path to verify the locked package and queue, checks the controlled execution branch against `state.source.head_commit`, and then invokes GF-004 `execute-one --json`. It consumes the child JSON result, never human-formatted output.

Each passing child creates a Game Foundry-owned commit. The next child therefore starts from the preceding accepted commit recorded in milestone state. Deterministic dependency order remains authoritative. Codex cannot select, accept, commit, or request execution of a successor task.

A bounded run records a parent manifest under:

```text
artifacts/bounded-runs/<milestone>/<gf005-run-id>/
```

The parent contains bounds, counters, timings, stop reason, queue state, and references to each GF-004 child result. Child evidence is not duplicated.

## Stop reasons and exit codes

Stable stop reasons are `TASK_LIMIT`, `TIME_LIMIT`, `HUMAN_GATE`, `NO_READY_TASK`, `MILESTONE_BLOCKED`, `TASK_FAILED`, `ESCALATED`, `LOCK_INTEGRITY_FAILURE`, `SOURCE_STATE_MISMATCH`, `RECOVERY_REQUIRED`, `RUNNER_BUSY`, and `INTERNAL_ERROR`.

Normal bounded stops—task limit, time limit, human gate, and no READY work—exit zero when no task failed. Failure, escalation, integrity errors, stale RUNNING recovery, runner contention, blocked milestones, and internal errors exit non-zero.

The wall-clock deadline is checked before starting the next task. A child already in progress is allowed to finish under GF-004's own timeout policy. `max-tasks` counts attempts, including a failed attempt. There is no automatic retry.

## Safety boundaries

A per-milestone runner lock prevents concurrent bounded parents. GF-004 retains its separate child execution lock, so the parent never holds the short-lived state lock while Codex runs. A stale RUNNING task stops with `RECOVERY_REQUIRED`; no result is inferred.

Lock changes and source-branch movement between tasks stop before another Codex invocation. A task failure stops immediately, descendants remain blocked, and failed work is not committed. Completion at a human gate stops with `HUMAN_GATE`; automation cannot approve it.

Test-only inter-task fault injection requires `GF_GF005_ENABLE_TEST_HOOKS=1`. It is disabled by default. Bounded execution never pushes, merges, publishes, schedules itself, runs tasks in parallel, or invokes an independent critic.

## Roadmap

- GF-006: independent OpenAI critic.
- GF-007: bounded retry and autonomous milestone supervisor.
- GF-008: interrupted-run recovery and reconciliation.
- GF-009: scheduled long-running operation.
- GF-010+: parallel games and workers.

These behaviors are not part of GF-005.
