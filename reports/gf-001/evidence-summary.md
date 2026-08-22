# GF-001 acceptance evidence summary

**Status: PASS**

GF-001 is accepted because two independent full executions passed and all four injected defects produced non-zero deterministic pipeline results. Agent prose was not used to decide acceptance.

## Successful runs

| Evidence | Run A | Run B |
|---|---|---|
| Run ID | `gf001-20260822T201203Z-45de91` | `gf001-20260822T205541Z-3a2e70` |
| Base commit | `3dfed16f9ba6d069904da13bde9c2ebf03b3dbbc` | `30d71f16aae39ca24397c836602f8efda77a9df1` |
| Mutation token | `GF001_45DE91` | `GF001_3A2E70` |
| Codex proof | `agentHarnessId=codex`; Gateway app-server evidence | `agentHarnessId=codex` |
| Godot static/runtime | PASS / PASS | PASS / PASS |
| Screenshot | PASS, 640×360 | PASS, 640×360 |
| Screenshot SHA-256 | `50d91be2418d5484cf2b182a43841b84b490f9ff5a4adf58338c549141d39875` | `00bb92cd390202fbe5a8ca1e3740d474b201bf7c992b950cd87187c51bc9eae7` |
| Export / exported runtime | PASS / PASS | PASS / PASS |
| Human interventions | 0 | 0 |
| Total duration | 231.825 s | 186.650 s |
| Artifact directory | `artifacts/gf-001/gf001-20260822T201203Z-45de91` | `artifacts/gf-001/gf001-20260822T205541Z-3a2e70` |

Run B includes evidence-only fail-closed hardening committed after Run A. Both runs started from clean commits, used detached temporary worktrees, independently changed the target from `GF001_INITIAL`, produced distinct artifacts, and removed their successful worktrees. The primary fixture remains unchanged.

## Negative tests

For these tests, PASS means the injected fault was correctly rejected.

| Test | Result | Process evidence | Pipeline evidence |
|---|---:|---|---:|
| A — Broken GDScript | PASS | Godot exit 1; Parse Error | Exit 1 |
| B — Wrong token | PASS | Application exit 0; runtime marker present; wrong token | Exit 1 |
| C — Unauthorized change | PASS | Allowed target and unexpected `README.md` both detected | Exit 1 |
| D — Missing screenshot | PASS | Nonexistent screenshot rejected | Exit 1 |

Detailed logs and fields are preserved in [negative-test-evidence.json](negative-test-evidence.json).

## Fail-closed review

No critical-failure path was found that could still produce GF-001 PASS. The review covered OpenClaw exit, Codex runtime ownership, source mutation, scope, Godot static validation, Godot runtime, exact token, screenshot, export, and exported runtime.

One evidence-ordering weakness was corrected: the harness previously wrote its PASS manifest before confirming successful worktree cleanup. PASS creation now occurs only after cleanup succeeds, cleanup is an explicit stage, and Run B records `cleanup=pass`.

## Known limitation

OpenClaw 2026.7.1-2 stable does not expose the anticipated `agent exec` command. The accepted implementation preserves the supported Gateway-backed `openclaw agent` route, uses a dedicated isolated workspace, pins `agentRuntime.id=codex`, and requires actual Codex harness/app-server evidence.
