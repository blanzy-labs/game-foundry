# GF-010 Evidence Summary

## GF-010 Status

GF-010 PASS WITH WARNINGS

The implementation candidate passed deterministic acceptance and independent
critic review. It is ready for the GF-010 human gate. It has not been committed,
pushed, merged, or used to integrate WEB-POC-001.

## Authority Contract

- Human: product, creative, QA, and release/integration approval authority.
- Codex: implementation agent; never approval or final acceptance authority.
- Game Foundry: approval-record, accepted-commit, integration, push/merge,
  remote-verification, recovery, cleanup, and milestone-transition owner.
- Godot and deterministic tests: validity and regression authority.
- Critic: independent read-only semantic and safety review authority.

## Approval Workflow

```text
PENDING_HUMAN → APPROVED → INTEGRATION_PRECHECK → INTEGRATING
→ INTEGRATION_VALIDATING → PUSHING → REMOTE_VERIFYING → INTEGRATED
```

PR mode additionally checkpoints branch push, PR creation, target refresh,
revalidation, required checks, merge start/result, exact target verification,
and compare-and-delete branch cleanup. `HUMAN_REQUIRED`,
`INTEGRATION_FAILED`, and `REVOKED` fail closed.

## Approval Command

For exactly one pending approval, the operator-facing agent maps the human's
explicit current approval to:

```text
./scripts/gf-approve.sh approve --current --source operator_agent_explicit_human
```

Plain “Approved” is accepted only when exactly one approval is pending.
Multiple pending approvals fail with `MULTIPLE_PENDING`. Scheduled/unattended
execution cannot create approval, including through the canonical runner.

## Approval Bundles

`schemas/approval.schema.json` and `schemas/approval-bundle.schema.json` define
candidate and adoption bundles. One approval can bind multiple units,
candidate commits, evidence records, critic results, and milestone human gates.
Each unit must have exact evidence coverage; duplicate, missing, or ambiguous
mapping fails closed.

## Adoption

Adoption is restricted to an exact source-controlled path inventory and content
fingerprint. Game Foundry creates candidates with a private index, binds unit
ownership, preserves byte-exact validation/critic evidence, rejects unrelated
or ambiguous paths (including both sides of renames), and cleans only approved
paths after exact remote verification. Interrupted cleanup is idempotent even
when an adopted evidence file has already been removed.

## Current Web Adoption

`WEB-POC-001` declares 41 exact paths: 32 source/infrastructure paths, three
Godot UID metadata files, and six report/evidence files. It contains two
ordered adoption commits:

1. GF-WEB-002/003 browser-runtime and Cloudflare-hosting infrastructure.
2. GF-WEB-004 Cyber Shield Web game POC.

Current classification is intentionally `reject`: the 41 Web paths are exact,
there are zero ambiguous Web paths, and 15 GF-010/control/report paths remain
outside the Web bundle. After GF-010 itself is approved and integrated, the
same manifest is safely adoptable. This run did not integrate WEB-POC-001.

## Integration Policy

The trusted target is `origin/main`; force updates to the integration target
are forbidden. Direct mode fetches, applies exact candidates in an isolated
worktree, handles descendant target movement by merge plus revalidation,
rejects resets/conflicts, performs a normal push, fetches again, and verifies
the exact remote commit and tree.

PR mode binds the open PR to the configured base and exact validated head before
checks and immediately before merge. Temporary branch deletion occurs only
after target verification and uses an exact compare-and-delete lease; raced or
ambiguous cleanup preserves the branch and requires human attention.

The Web policy temporarily shares `node_modules` with an isolated validation
worktree only when its `package-lock.json` exactly matches the source lockfile.
The link is verified, removed, and recorded in validation evidence.

## Validation, Push, Recovery, and Milestones

Validation begins and ends at the recorded clean HEAD/tree. Dirtying validators,
candidate/evidence/policy changes, remote identity changes, ambiguous transport,
and corrupt recovery evidence fail closed. Recovery rebinds immutable evidence
before completion or retry-push, reconciles exact remote outcomes without
duplicate commits/pushes, and safely removes stale worktrees.

Successful verified integration atomically satisfies every mapped
`pending_human` milestone with approval/bundle/commit provenance. Terminal
`complete` survives milestone recalculation. Partial gate and state/history
crashes reconcile with exactly one history event per milestone.

## Deterministic Tests A–T

- A approval required — PASS
- B approved direct integration — PASS
- C no repeated approval — PASS
- D candidate/evidence changed — PASS
- E clean remote advance — PASS
- F remote conflict/reset — PASS
- G crash after push and missing-evidence recovery — PASS
- H push failure before remote — PASS
- I ambiguous push reconciliation and changed-evidence rejection — PASS
- J adoption and cleanup recovery — PASS
- K unrelated/rename rejection — PASS
- L multi-unit bundle and milestone-gate recovery — PASS
- M multiple pending approvals — PASS
- N already integrated idempotence — PASS
- O PR policy, recovery, identity, and safe cleanup races — PASS
- P external reviewer stop/resume — PASS
- Q post-integration validation and locked dependencies — PASS
- R cleanup and receipts — PASS
- S canonical scheduler cannot approve — PASS
- T force push, target redirect, and remote identity changes forbidden — PASS

Repeatability: 20 iterations, 400/400 top-level checks PASS, zero failures,
zero orphan approval worktrees.

## Real GitHub Smoke

NOT RUN. No real repository/branch/PR/push/verification/cleanup mutation was
authorized before the GF-010 human gate. The local fixture and fake-GitHub
adversarial coverage passed. The isolated real Web policy smoke passed without
deploying or mutating a production remote.

## Regression Results

- Repository doctor — PASS.
- GF-010 — PASS, 20 iterations, 400/400 checks.
- GF-H02 — PASS.
- GF-H03 — PASS.
- GF-009 — PASS.
- Pytest — PASS, 16 tests and 12 subtests.
- Fresh GF-008 — NOT COMPLETE: its external critic credential/model was
  unavailable; retained output contains failures and is not represented as PASS.

## Critic

Model: `gpt-5.6-sol` in read-only mode.

Decision: PASS. Blockers: 0.

Warnings: real GitHub mutation smoke was not authorized; fresh GF-008 was
environmentally unavailable; some copied fixture paths retain their original
temporary absolute paths, but the referenced artifacts remain present.

## Evidence

- Deterministic result: `artifacts/gf-010/gf010-acceptance-20260831T165300Z/result.json`
- Per-check JSONL: `artifacts/gf-010/gf010-acceptance-20260831T165300Z/results.jsonl`
- Critic: `artifacts/gf-010/gf010-acceptance-20260831T165300Z/critic.json`
- Direct integration fixture: `artifacts/gf-010/gf010-acceptance-20260831T165300Z/fixtures/i1-direct/`
- Bundle/milestone fixture: `artifacts/gf-010/gf010-acceptance-20260831T165300Z/fixtures/i1-bundle/`
- Adoption cleanup recovery: `artifacts/gf-010/gf010-acceptance-20260831T165300Z/fixtures/i1-adopt-cleanup-crash/`
- Push/evidence recovery: `artifacts/gf-010/gf010-acceptance-20260831T165300Z/fixtures/i1-crash-evidence-missing/`
- PR cleanup race: `artifacts/gf-010/gf010-acceptance-20260831T165300Z/fixtures/i1-pr-branch-race/`
- Canonical scheduler probe: `artifacts/gf-010/gf010-acceptance-20260831T165300Z/fixtures/i1-scheduler/runner-probe/`
- Real Web policy smoke: `artifacts/gf-010/gf010-acceptance-20260831T165300Z/real-web-policy-smoke/`
- Final regressions: `artifacts/gf-010/regression-final-20260831T170100Z/`

## Recommendations

1. After explicit human GF-010 approval, the operator can say “Approved”; when
   GF-010 is the sole pending approval, Game Foundry owns the remaining commit,
   integration, push/merge, verification, cleanup, and milestone mechanics.
2. WEB-POC-001 is safely adoptable only after GF-010 itself is integrated and
   its current classification becomes PASS.
3. Use the exact `WEB-POC-001` bundle: GF-WEB-002/003 infrastructure first,
   then GF-WEB-004, under one candidate-bound human approval.
4. Human intervention remains required for conflicts/resets, candidate/evidence/
   policy changes, ambiguous remote outcomes, external-review requirements,
   authentication/policy failures, validation failures, or unsafe cleanup races.

## Human Gate

HUMAN GF-010 APPROVAL = PENDING
