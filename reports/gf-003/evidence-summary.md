# GF-003 — Milestone contract and dry-run queue evidence

**Status: PASS**

Game Foundry now validates and locks a human-approved milestone package, persists dependency-aware task state, resumes without conversational context, selects exactly one `READY` task deterministically, and renders its future Codex prompt without executing it.

## Contract and lock

| Gate | Result |
|---|---:|
| Milestone schema | PASS |
| Task schema | PASS |
| Required fields | PASS |
| Unique filesystem-safe task IDs | PASS |
| Unknown/self/cyclic dependencies rejected | PASS |
| Design, guidelines, manifest, and task hashes recorded | PASS |
| Changed locked design prohibited | PASS |

The fixture lock records design SHA-256 `da050e20d61a9e99858dc3bc73b2609b76323680ec30d457fafb55681c831f0a` and task-package SHA-256 `65f16122639748bf53502260b2a4c3b09435b28a6e380616500a282d745fd559`.

## Queue and persistence

```text
initial               → GF-FIX-001
after 001 PASS        → GF-FIX-002
after 002 PASS        → GF-FIX-003
after 003 PASS        → PENDING_HUMAN
```

After task 001 passed, a separate CLI invocation loaded the persisted files and observed:

```text
GF-FIX-001  PASS
GF-FIX-002  READY
GF-FIX-003  BLOCKED
next         GF-FIX-002
```

The happy path produced 11 durable JSONL history events. `BLOCKED`, `READY`, `RUNNING`, `PASS`, `FAIL`, and `ESCALATED` were exercised. Retry attempt two escalated the fixture task and kept dependents blocked.

## Prompt and dry-run

Generated prompt:

`artifacts/gf-003/gf003-20260823T100622Z-caf5ed/milestones/GF-FIX-M001/GF-FIX-002/prompt.md`

The prompt contains the locked design hash, authoritative design and guidelines, passed dependencies, task objective, allowed scope, acceptance requirements, attempt `1 / 3`, and Game Foundry-controlled safety rules.

The dry run selected `GF-FIX-002`, rendered this prompt, made zero source modifications, invoked Codex zero times, and reported execution as not started.

## Negative tests

| Invalid condition | Result |
|---|---:|
| Invalid milestone JSON | PASS — rejected |
| Duplicate task ID | PASS — rejected |
| Unknown dependency | PASS — rejected |
| Self dependency | PASS — rejected |
| Dependency cycle | PASS — rejected |
| Changed locked design | PASS — rejected |
| Illegal `BLOCKED → PASS` transition | PASS — rejected |
| Retry exhaustion | PASS — escalated |

No false acceptance occurred.

## Metrics

| Metric | Value |
|---|---:|
| Milestone tasks | 3 |
| Happy-path state transitions | 11 |
| Schema validation | 0.120150 seconds |
| Prompt rendering | 0.249433 seconds |
| Dependency calculation | 0.209789 seconds |
| Resume | 0.430937 seconds |
| Total acceptance | 7.155809 seconds |
| Manual interventions | 0 |

Implementation commit: `a8d5386b354fa4e113c4d8864f38ff605dc20d46`.

GF-003 created no scheduler, autonomous Codex execution, critic, release, or GF-004 implementation.
