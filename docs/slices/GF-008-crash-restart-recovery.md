# GF-008 — Crash/Restart Recovery and Reconciliation

GF-008 extends the existing `execute-one` transaction with durable recovery evidence. It does not introduce a second implementation pipeline: recovered work reuses the GF-004 scope checks, validator-integrity check, deterministic validator, GF-006 critic, GF-007 repair contract, and Game Foundry commit policy.

## Durable execution record and ownership

Claiming a task persists `active_execution` in milestone state. The record contains task/run identity, accepted pre-task commit, execution branch, worktree and artifact paths, checkpoint, candidate and repair ordinals, integrity hashes, recovery policy, counters, and owner identity.

Owner identity is the tuple of Linux PID, boot ID from `/proc/sys/kernel/random/boot_id`, and process start ticks from `/proc/<pid>/stat`. A PID alone is never evidence of liveness. A different boot ID, absent PID, or different process-start identity makes the old owner stale. The milestone `.execution.lock` remains the long transaction lock; state changes use the short state lock and atomic replacement.

## Checkpoint and journal semantics

Every run stores `checkpoint.json` and `journal.jsonl` in its execution artifact directory. A checkpoint means that the named stage and its prerequisites completed and have durable evidence. Checkpoints cover claim, worktree, agent, scoped candidate snapshot, deterministic PASS, critic results, repair boundaries, accepted commit, cleanup, and terminal state.

Checkpoint replacement writes validated JSON to a same-directory temporary file, flushes it, renames it atomically, and flushes the directory where supported. The journal is append-only history; the checkpoint is the authoritative last complete stage. Invalid, missing, unknown, or contradictory checkpoint evidence escalates and can never be promoted to PASS.

## Candidate snapshots

After changed-file enumeration, path/symlink safety, and allowed-scope validation pass, Game Foundry writes the full candidate tree to a private ref:

```text
refs/game-foundry/recovery/<run-id>/candidate-<ordinal>
```

The snapshot commit has the pre-task accepted commit as parent, is not the execution branch, is not pushed, and is not accepted work. Its ref, commit, tree, changed files, candidate ordinal, and repair ordinal are recorded. Recovery can recreate a missing worktree from that tree. Successful PASS deletes private refs but preserves patch, scope, validation, critic, commit, checkpoint, journal, and recovery-result artifacts. Escalation retains recovery refs for investigation.

## Classification and continuation

`recovery-status` is read-only and returns one stable `recovery_action`. Live ownership returns `RECOVERY_BUSY`. Stale work before trusted agent completion returns `RESTART_TASK`; partial work is preserved as evidence and discarded. A candidate snapshot resumes deterministic validation. Deterministic PASS or an interrupted critic resumes a fresh critic request without a Codex call. Critic PASS creates the single accepted commit. An already-created accepted commit is reconciled only if its parent, tree, changed files, author, message, task, run, and execution branch agree.

Critic BLOCK resumes the same repair budget. An interrupted repair restores the previous trusted snapshot and repeats the same repair ordinal. Repair attempts and recovery agent restarts are independently bounded and persisted. Deterministic failure becomes task FAIL; critic transport/schema errors retain GF-006 fail-closed behavior; exhausted repair or restart budgets escalate.

Recovery performs exactly one stale-task transaction. PASS recalculates dependencies and stops with the child READY. It never executes that child. A human completion gate remains `PENDING_HUMAN` and cannot be approved by recovery.

## Idempotency and ambiguity

Recovery never resets an unexpected execution branch. It never infers agent or critic completion from partial logs. Missing snapshots after a snapshot-dependent checkpoint, changed milestone locks, conflicting run identity, unexpected commit parents/trees, or corrupt checkpoint JSON produce `ESCALATE`. Running recovery again after PASS returns `NO_RECOVERY_NEEDED` and creates no commit or state transition.

## Operator guide

Inspect without mutation:

```bash
./scripts/gf-milestone.sh recovery-status <milestone-id>
./scripts/gf-milestone.sh recovery-status <milestone-id> --json
```

Recover one stale task:

```bash
./scripts/gf-milestone.sh recover <milestone-id>
./scripts/gf-milestone.sh recover <milestone-id> --json
```

For escalation, inspect the task's `last_evidence`/`recovery_execution`, then open `checkpoint.json`, `journal.jsonl`, candidate snapshot JSON, validation logs, critic result, `commit.json`, and `recovery-result.json`. Recovery does not alter unknown source movement or delete retained escalation refs.

After a recovered PASS, confirm the dependent is READY and start a separate bounded process when desired:

```bash
./scripts/gf-milestone.sh run-bounded <milestone-id> --max-tasks 1 --max-minutes 30
```

## Metrics and boundaries

The active record and recovery result track invocations, agent restarts, critic retries, commit reconciliations, worktree recreations, repair resumptions, Codex/critic calls, and reused Codex/deterministic/critic work. Acceptance aggregates successful recovery, escalation, calls avoided, duration, and human intervention.

GF-008 does not add scheduling, daemons, reboot control, multi-host/distributed locking, cross-foundry supervision, parallel milestones, push, PR, release, or human approval. Those remain outside this slice.
