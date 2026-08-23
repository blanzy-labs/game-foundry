# GF-007 — Bounded Critic-Guided Repair

GF-007 extends the existing `execute-one` transaction. A repair is eligible only after source scope, validator integrity, and deterministic validation pass and a valid required critic response contains at least one blocker. Execution, validation, critic transport, contract, integrity, and configuration failures remain ordinary fail-closed task failures.

## Policy and bounds

Repair is opt-in through the locked milestone review policy:

```json
{"review_policy":{"type":"openai_critic","required":true,"block_on":["blocker"],"repair":{"enabled":true,"max_attempts":2}}}
```

The schema caps configured repairs at five and requires a positive bound when enabled. The fixture and recommended production policy use two. The initial implementation and task retry count remain separate from critic-guided repair attempts. A task with repairs still consumes one GF-005 task slot.

## Repair contract and context

Game Foundry creates a deterministic, self-contained prompt containing the locked design and hash, guidelines, original task JSON, original allowed scope, acceptance contract, full candidate diff from the accepted HEAD, blocker IDs and evidence references, attempt number, remaining budget, and safety rules. Warnings and observations are labeled non-blocking.

Critic text is untrusted evidence. It cannot expand source scope, modify the locked contract, weaken validation, authorize commits, or set task state. Repairs use fresh Codex turns in the same isolated candidate worktree; stored evidence, not hidden conversational memory, is the recovery authority.

## Validation and review order

Every candidate follows the same chain:

```text
Codex → changed-file enumeration → scope → validator integrity
      → deterministic validation → fresh independent critic review
```

The authoritative patch is always the full diff from the pre-task accepted commit. No intermediate repair commit exists. A final critic PASS, including warning-only PASS, permits exactly one Game Foundry-owned task commit. A repair that breaks scope, validator integrity, deterministic validation, runtime ownership, or critic transport fails immediately without another semantic repair.

The critic still uses a separate direct Responses API request with `store:false`, no tools, strict Structured Outputs, and fresh evidence. Game Foundry assigns deterministic finding IDs in the persisted `review.json`. Each repair records entering, conservatively matched remaining, resolved, and new blocker IDs.

## State and exhaustion

The task remains `RUNNING` during the bounded repair loop. A successful repair transitions once to `PASS`. If the final allowed repair still receives a valid BLOCK, Game Foundry transitions directly from `RUNNING` to `ESCALATED`; dependents remain blocked and GF-005 stops with `ESCALATED`. Existing stale-RUNNING recovery behavior remains unchanged.

## Artifacts and metrics

Each run preserves:

```text
attempt-01/{prompt,agent.patch,scope,validator-integrity,validation,critic}
repair-01/{prompt,agent.patch,scope,validator-integrity,validation,critic,finding-tracking.json}
repair-02/...
agent-history.json
critic-history.json
result.json
```

Results record repair outcome (`not_needed`, `repaired`, `exhausted`, or `failed`), attempts, Codex and critic calls, timing and averages, token usage, and context strategy. GF-005 aggregates repaired and repair-escalated tasks. The GF-006 failure-path timing anomaly was an instrumentation bug: state timing previously began before candidate execution. GF-007 measures only the actual failure/escalation state transition.

## Limitations

GF-007 does not implement interrupted-run reconciliation, general task retry redesign, critic transport retry, scheduling, parallel repair, multi-critic voting, architecture redesign, milestone mutation, publication, or release. GF-008 may add explicit reconciliation for interrupted `RUNNING` work.
