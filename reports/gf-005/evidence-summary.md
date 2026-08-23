# GF-005 evidence summary

Status: **GF-005 PASS**

- Acceptance: `gf005-acceptance-20260823T200649Z-000205`
- Two-task parent: `gf005-20260823T200650Z-464f7b00` — `TASK_LIMIT`
- Human-gate parent: `gf005-20260823T200921Z-f0610d0d` — `HUMAN_GATE`
- Real Codex invocations: `5`
- Evidence: `artifacts/gf-005/gf005-acceptance-20260823T200649Z-000205`

All recorded checks: PASS

## Two-task bounded run

- Bounds: 2 tasks / 30 minutes
- `GF-CHAIN-001`: PASS — `99c6598119ada0a7e0f103ab83d2bcae3b19fb54`
- `GF-CHAIN-002`: PASS — `839fe781fba5089d43b62b7dbb677311a14d29d8`
- `GF-CHAIN-003`: READY, not executed
- Codex invocations: 2
- Stop reason: `TASK_LIMIT`
- Persistence: PASS in a new CLI process

Source chain:

```text
1b39cac385d2033b9a9d370b884d28acff93518b
  -> 99c6598119ada0a7e0f103ab83d2bcae3b19fb54
  -> 839fe781fba5089d43b62b7dbb677311a14d29d8
```

## Human-gate run

- `GF-CHAIN-001`: PASS — `40842b70a5f26593dfcaf5101bb02620b334d001`
- `GF-CHAIN-002`: PASS — `b2720e45374d94500127c4a132bc0031475059bd`
- `GF-CHAIN-003`: PASS — `9c86b33558668b1e678ea447341dbd5f51f9be2a`
- Milestone: `PENDING_HUMAN`
- Codex invocations: 3
- Stop reason: `HUMAN_GATE`

Each task's pre-task commit exactly equals its predecessor's accepted commit.

## Negative tests

- A — Middle-task deterministic validation failure: PASS
- B — Unauthorized task-2 change: PASS
- C — Lock changed between tasks: PASS
- D — Source HEAD changed between tasks: PASS
- E — Time limit before task 2: PASS
- F — No READY / blocked milestone: PASS
- G — Stale RUNNING recovery stop: PASS
- H — Invalid limits: PASS
- Concurrent runner rejection: PASS

## Regression

- GF-003: PASS
- GF-004: PASS
- GF-002 shared gates: PASS
- Doctor: PASS (29/29 critical)
- Godot self-test: PASS

## Metrics

Two-task fixture run:

- Total: `150.905397s`
- Attempted/passed/failed: `2 / 2 / 0`
- OpenClaw/Codex: `139.119802s`
- Average OpenClaw/Codex per attempt: `69.559901s`
- Validation: `0.237140s`
- Commit: `0.064828s`
- State transitions: `0.178941s`
- Fixture throughput: `47.712011 accepted tasks/hour`
- Human interventions: `0`

Human-gate fixture run:

- Total: `224.392919s`
- Attempted/passed/failed: `3 / 3 / 0`
- OpenClaw/Codex: `206.406109s`
- Fixture throughput: `48.129861 accepted tasks/hour`
- Human interventions: `0`

Fixture throughput is acceptance-fixture performance, not game-development throughput.

## Evidence paths

- Two-task parent: `artifacts/gf-005/gf005-acceptance-20260823T200649Z-000205/two-task-real/result.json`
- Human-gate parent: `artifacts/gf-005/gf005-acceptance-20260823T200649Z-000205/human-gate-real/result.json`
- Child results: beneath each parent case's `children/GF-CHAIN-M001/` directory
- Negative cases: `artifacts/gf-005/gf005-acceptance-20260823T200649Z-000205/<case>/result.json`
- GF-004 regression: `artifacts/gf-005/gf005-acceptance-20260823T200649Z-000205/regression/gf004-summary.json`
