# GF-004 — Execute One READY Task

GF-004 adds one production command to the GF-003 milestone control plane:

```bash
./scripts/gf-milestone.sh execute-one GF-EXEC-M001
```

The command verifies the locked milestone and expected source HEAD, asks the existing deterministic selector for one READY task, claims that task as RUNNING, and creates an isolated Git worktree on `gf/<milestone-id>`. It renders the GF-003 prompt and sends it through the accepted OpenClaw Gateway-backed agent with fail-closed `agentRuntime.id = codex` configuration. Runtime evidence—not the configured model name—is required.

## Acceptance ownership

The agent may only change paths matched by `allowed_scope`. Game Foundry enumerates every tracked and untracked change, rejects traversal and repository-escaping symlinks, and preserves the binary patch as evidence. A source change is required.

Executable task contracts use a structured validator:

```json
{
  "validation": {
    "type": "repo_script",
    "path": "fixtures/execution-project/acceptance/validate-task.sh",
    "args": ["GF-EXEC-001"],
    "timeout_seconds": 60,
    "success_markers": ["GF_EXEC_001_ACCEPTED"]
  }
}
```

The validator must be an executable, non-symlink file inside the target repository and outside the agent's allowed scope. Its SHA-256 is recorded before the agent runs and verified afterward. It is executed directly with an argument array and a timeout; arbitrary shell strings and `eval` are not supported. Acceptance requires both exit code zero and every configured marker.

Codex output is evidence only. PASS requires OpenClaw success, proven Codex runtime ownership, an allowed meaningful mutation, intact validation authority, and deterministic validation success.

## Commit, cleanup, and state

Codex is told not to commit. After all gates pass, Game Foundry explicitly stages only the verified file list and creates a controlled local commit on the execution branch. It does not push, merge, tag, publish, or deploy.

The temporary worktree is removed and the execution branch/commit are verified before PASS is written. State records the source repository, original base, execution branch, accepted HEAD, run ID, commit, and evidence path. If a critical post-commit step fails before PASS persistence, the branch and state are rolled back to the pre-task snapshot.

On failure, evidence is retained, the worktree is removed, the branch remains at its prior accepted commit, and Game Foundry transitions RUNNING to FAIL using the existing attempt semantics. There is no automatic retry.

After PASS, the existing dependency recalculation may make another task READY, but `execute-one` stops. A second task is never started in the same invocation.

## Evidence and recovery

Each attempt has an immutable directory beneath:

```text
artifacts/executions/<milestone>/<task>/<run-id>/
```

It contains the prompt, OpenClaw output, runtime proof, source baseline, patch, scope decision, validator hashes and logs, commit evidence, and machine-readable result. Timing for selection, prompt rendering, agent execution, scope, validation, commit, cleanup, state, and total duration is recorded.

A per-milestone non-blocking lock enforces one executor. If state contains RUNNING without the current executor owning it, execution stops with `RECOVERY REQUIRED`; Game Foundry does not guess whether interrupted work passed.

The acceptance harness exposes test-only fault injection through `GF_GF004_ENABLE_TEST_HOOKS=1` and a named `GF_GF004_FAULT`. Production execution has no active hook when that opt-in variable is absent.

## Next slices

- GF-005: bounded chained task runner.
- GF-006: independent OpenAI critic.
- GF-007: autonomous milestone execution with retry and escalation.
- Later: scheduling, continuous operation, and parallel projects.

None of those behaviors are implemented in GF-004.
