# GF-002 — Production gate hardening

GF-002 keeps the canonical production command unchanged:

```bash
./scripts/gf-001-acceptance.sh
```

Routine fault-injection runs write their generated report into temporary storage so
the production acceptance preflight still sees a clean checkout. Refresh the
committed canonical fault-injection evidence only when intentionally recording a
new accepted GF-002 run:

```bash
GF002_UPDATE_REPORTS=1 ./scripts/gf-001-failure-tests.sh
```

The source token, Godot static/runtime, screenshot, export, and exported-runtime decisions now live in `scripts/lib/gf-001-common.sh`. Production acceptance and `scripts/gf-001-failure-tests.sh` use those same functions. Scope validation remains shared there as well.

Fault injection is isolated in `scripts/lib/gf-002-fault-gate.sh`. It refuses to run unless `GF001_TEST_MODE=1`, requires one recognized `GF001_TEST_FAULT`, operates only on disposable copies/worktrees, and cannot affect a normal acceptance invocation. Each injected case returns the shared production gate's actual exit code; the failure-test suite treats a non-zero gate result as a negative-test PASS.

The five cases cover a broken GDScript, a wrong token despite application exit 0, an unauthorized source mutation, a missing screenshot, and an apparent agent success followed by a real Godot failure. The last case uses a controlled mock agent-success record, verifies the expected source token exists, and then proves the deterministic static gate rejects the broken project.

PASS ordering remains fail-closed: `write_results pass` occurs only after OpenClaw, Codex runtime evidence, mutation, scope, all Godot/build gates, and successful worktree cleanup.

## Verification

```bash
./scripts/gf-002-shared-gate-tests.sh
./scripts/gf-001-failure-tests.sh
./scripts/gf-001-acceptance.sh
```

## Human visual review

Automated acceptance verifies the screenshot is a non-empty 640×360 PNG and that its render log has the exact token. A human reviewer should:

1. Open the latest screenshot path printed in `reports/gf-002/evidence-summary.md`.
2. Confirm the fixture rendered normally.
3. Confirm the visible mutation token looks plausible and matches the recorded run token.
4. Record visual review as PASS or FAIL separately.

The automated pipeline does not claim human approval.
