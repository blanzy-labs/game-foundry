# GF-004 evidence summary

Status: **GF-004 PASS**

- Acceptance run: `gf004-acceptance-20260823T105134Z-58a184`
- Execution run: `gf004-20260823T105142Z-03cff07c`
- Milestone/task: `GF-EXEC-M001` / `GF-EXEC-001`
- Attempt: `1 / 2`
- Real route: OpenClaw Gateway → Codex (`agentHarnessId=codex`)
- Agent time: `69.802007s`
- Changed file: `fixtures/execution-project/src/marker.txt`
- Scope: PASS
- Validator: `fixtures/execution-project/acceptance/validate-task.sh`
- Validator SHA-256 before/after: `cfc1c228f86488fb1e7b073a09b65f11ef6496eb07d320bee53909a10fda7162`
- Validator result: exit `0`, `GF_EXEC_001_ACCEPTED`
- Pre-task commit: `9563e2311ba3ae64c19c1d89ca5b9ea7c22b1f44`
- Accepted commit: `1189cd08ccf9afee69caa8f0887bcc6a4babaaf6`
- Execution branch: `gf/GF-EXEC-M001` (local only)
- Cleanup/state update: PASS / PASS
- Final state: `GF-EXEC-001 PASS`, `GF-EXEC-002 READY`
- Next execution: NOT STARTED
- Codex invocations: `1`
- Human interventions: `0`

Persistence was independently checked in a new CLI process. The execution branch and state point to the same accepted commit, the marker exists at branch HEAD, task 002's marker is absent, main was unchanged by execution, and the temporary worktree was removed.

## Negative tests

- A — OpenClaw failure: PASS
- B — Agent success / validator failure: PASS
- C — Unauthorized source change: PASS
- D — Validator mutation: PASS
- E — Missing Codex runtime evidence: PASS
- F — Changed milestone lock: PASS
- G — No READY task: PASS
- H — No chaining: PASS

## Regression

- GF-003 acceptance: PASS
- GF-002 affected shared gates: PASS
- GF-000 doctor: PASS (29 critical checks, 0 failures)
- Godot self-test: PASS

## Evidence

- Prompt: `artifacts/executions/GF-EXEC-M001/GF-EXEC-001/gf004-20260823T105142Z-03cff07c/prompt.md`
- OpenClaw result: `artifacts/executions/GF-EXEC-M001/GF-EXEC-001/gf004-20260823T105142Z-03cff07c/openclaw-result.json`
- Agent patch: `artifacts/executions/GF-EXEC-M001/GF-EXEC-001/gf004-20260823T105142Z-03cff07c/agent.patch`
- Scope: `artifacts/executions/GF-EXEC-M001/GF-EXEC-001/gf004-20260823T105142Z-03cff07c/scope.json`
- Validation: `artifacts/executions/GF-EXEC-M001/GF-EXEC-001/gf004-20260823T105142Z-03cff07c/validation.stdout.log`
- Result: `artifacts/executions/GF-EXEC-M001/GF-EXEC-001/gf004-20260823T105142Z-03cff07c/result.json`
- Commit: `artifacts/executions/GF-EXEC-M001/GF-EXEC-001/gf004-20260823T105142Z-03cff07c/commit.json`
- Acceptance artifacts: `artifacts/gf-004/gf004-acceptance-20260823T105134Z-58a184`
