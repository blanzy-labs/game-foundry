# GF-003 — Milestone contract and dry-run queue

GF-003 adds a deterministic control plane for locked, human-approved milestones. It validates and persists work definitions, calculates dependency readiness, renders the exact future Codex prompt, and stops before execution. It does not invoke OpenClaw, Codex, target validation, Git mutation, publishing, or scheduling.

## Milestone package

A package contains `milestone.json`, its referenced `design.md` and `guidelines.md`, and an ordered task list. The contract is documented by `schemas/milestone.schema.json`. Required fields identify the milestone, version, target repository, source documents, ordered task paths, and either an automated or human-review completion gate.

Task files follow `schemas/task.schema.json`. They require a filesystem-safe unique ID, title, objective, dependency list, allowed scope, acceptance requirements, retry limit, and failure policy. Task content is descriptive; GF-003 never executes commands from it.

The fixture package is `milestones/examples/fixture-milestone`:

```text
GF-FIX-001 → GF-FIX-002 → GF-FIX-003
```

## Validation and locking

```bash
./scripts/gf-milestone.sh validate milestones/examples/fixture-milestone
./scripts/gf-milestone.sh init milestones/examples/fixture-milestone
```

Validation rejects invalid JSON/contracts, unsafe paths, duplicate IDs, duplicate dependencies, unknown/self dependencies, and cycles. Initialization writes state outside the package under `state/<milestone-id>/`.

`lock.json` records the milestone, design, guidelines, and task-package SHA-256 values plus every locked relative path and hash. Every stateful command verifies these hashes before continuing. Missing or changed content fails with `LOCK VALIDATION FAIL`; GF-003 has no revision or silent-relock operation.

## State and dependency model

The supported task states are:

```text
BLOCKED  dependency has not passed
READY    all dependencies passed and work has not started
RUNNING  work has been claimed
PASS     deterministic acceptance succeeded
FAIL     the current attempt failed but may retry
ESCALATED retry limit was reached or an operator escalated
```

Legal operator transitions are:

```text
READY → RUNNING
RUNNING → PASS
RUNNING → FAIL
FAIL → READY        while attempts remain
FAIL → ESCALATED
```

All other transitions are rejected. `RUNNING → FAIL` increments the failure-attempt counter. Reaching `retry_policy.max_attempts` changes the task directly to `ESCALATED`. Dependents remain blocked.

After every accepted transition, Game Foundry recalculates only derived `BLOCKED`/`READY` states in milestone task order. Each change is appended to `history.jsonl`. State updates use an atomic replacement and commands take a per-milestone file lock.

When every task is `PASS`, automated work is complete. A `human_review` completion gate produces `PENDING_HUMAN`; automation cannot mark the milestone released or approved.

## Selection, persistence, and resume

```bash
./scripts/gf-milestone.sh status GF-FIX-M001
./scripts/gf-milestone.sh next GF-FIX-M001
```

`next` selects the first `READY` task in the locked milestone order. It can return `NEXT_TASK=<id>`, `NO_READY_TASK`, `MILESTONE_BLOCKED`, or `MILESTONE_COMPLETE`. Selection is never delegated to an LLM.

`lock.json`, `state.json`, and append-only `history.jsonl` live on disk. A later process can reconstruct the exact state without conversation or agent memory. The acceptance suite initializes, passes task 001, exits that command, then proves a fresh invocation returns task 002.

## Prompt rendering and dry-run

```bash
./scripts/gf-milestone.sh render-prompt GF-FIX-M001 GF-FIX-001
./scripts/gf-milestone.sh dry-run GF-FIX-M001
./scripts/gf-milestone.sh dry-run GF-FIX-M001 --json
```

A prompt can be rendered only for a `READY` task. In fixed order it contains milestone identity and design hash, authoritative design, guidelines, task objective, passed dependencies, allowed scope, acceptance requirements, retry attempt, and Game Foundry-owned safety rules. Prompts are generated under `artifacts/milestones/<milestone>/<task>/prompt.md`.

Dry-run verifies the package lock, recalculates readiness, selects one task, renders its prompt, reports the proposed action, and stops. Its JSON explicitly records `codex_invocations: 0`, `source_modifications: 0`, and `execution: "not_started"`.

All important inspection commands support `--json`. `GF_MILESTONE_STATE_ROOT` and `GF_MILESTONE_ARTIFACT_ROOT` may redirect generated state/artifacts for isolated testing; production defaults remain `state/` and `artifacts/milestones/`.

## Verification

```bash
./scripts/gf-003-acceptance.sh artifacts/gf-003/<run-id>
```

The suite proves schema and graph validation, lock integrity, three-task progression, restart/resume, prompt safety, dry-run non-execution, human-gated completion, invalid JSON, duplicate IDs, unknown dependencies, cycles, design mutation, illegal transitions, and retry exhaustion.

## Future execution model

GF-003 stops at prompt materialization. Proposed later boundaries are:

- GF-004: execute exactly one real `READY` task.
- GF-005: chain multiple dependency-selected tasks.
- GF-006: add independent deterministic/critic review.
- GF-007: run one bounded autonomous milestone.
- GF-008+: add scheduling, multiple games, and longer operations.

None of those execution or scheduling capabilities are implemented here.
