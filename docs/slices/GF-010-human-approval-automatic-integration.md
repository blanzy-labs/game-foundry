# GF-010 — Human approval to automatic integration

GF-010 closes the post-QA Git mechanics gap. Human approval is bound to an
exact candidate commit/tree or an exact adoption path fingerprint. The
operator-facing agent invokes Game Foundry once; Game Foundry then owns the
isolated integration, validation, non-force push or PR, fetch-based remote
verification, recovery reconciliation, and cleanup.

## Operator commands

```text
./scripts/gf-approve.sh create <approval-manifest.json>
./scripts/gf-approve.sh list --json
./scripts/gf-approve.sh status <approval-id> --json
GF_APPROVAL_OPERATOR_CONTEXT=interactive \
  ./scripts/gf-approve.sh approve <approval-id> \
  --source operator_agent_explicit_human
./scripts/gf-approve.sh reconcile <approval-id>
```

When exactly one approval is `PENDING_HUMAN`, an operator-facing agent may map
the human's explicit current “Approved” instruction to:

```text
./scripts/gf-approve.sh approve --current \
  --source operator_agent_explicit_human
```

The command records approval and immediately executes the whole integration
transaction. It is rejected in scheduled/unattended context. With multiple
pending records, `--current` fails closed and the agent must identify which
approval the human means.

The canonical `gf-unattended-run.sh` exports `GF_UNATTENDED_RUN=1` before any
milestone, agent, validator, or helper subprocess is invoked; the reference
systemd unit sets the same marker defensively. GF-010 rejects approval even if
an unattended child supplies an otherwise accepted operator-source string.

## Persistent states

```text
PENDING_HUMAN → APPROVED → INTEGRATION_PRECHECK → INTEGRATING
→ INTEGRATION_VALIDATING → PUSHING → REMOTE_VERIFYING → INTEGRATED
```

`HUMAN_REQUIRED`, `INTEGRATION_FAILED`, and `REVOKED` are terminal or
operator-attention states. Records live under `state/approvals/`; receipts and
Git/validation evidence live under `artifacts/approvals/`. Checkpoints make a
crash after push reconcilable without a duplicate commit or push.

An approval manifest may map its units to one or more configured
`milestone_gates`. Creation snapshots each exact `pending_human` milestone
state and verifies that every mapped task is already `pass`. Only after the
validated remote result and cleanup are complete does Game Foundry atomically
set each mapped human gate to terminal `complete`, record the approval and
integration commit in milestone state/history, and finally mark the approval
`INTEGRATED`. A stable event ID plus atomic replacement makes the state/history
pair recoverable across either write boundary without duplicating history.
Partial gate updates are idempotently reconciled after a crash; a changed or
unrelated milestone state fails closed. Reconciliation of an already integrated
record is a read-only success even when the remote has subsequently advanced.

## Adoption

An adoption manifest declares every allowed dirty path, evidence-bearing unit,
logical commit group, deterministic commit message, base SHA, remote, target,
and integration validation argv. Creation rejects missing, extra, unsafe,
non-file, or symlink paths. Game Foundry builds candidate commits with a
private temporary Git index and preservation refs; it never uses `git add -A`
or the caller's index. Validation and critic evidence are content-digested and
bound in the source-controlled manifest to unit IDs and exact candidate
commits/path ownership. Adoption manifests additionally carry the exact
combined path-content fingerprint; the integration base is captured separately
when the pending record is created so committing GF-010 first does not
invalidate the approved Web content fingerprint. Any evidence, policy,
candidate, or dirty-inventory change before approval fails closed.
Both source and destination of a staged rename/copy are inventoried.

The current Web bundle is declared by
`config/approvals/web-poc-001-adoption.json` as two commits: GF-WEB-002/003
infrastructure followed by GF-WEB-004 Cyber Shield. During GF-010 development,
classification deliberately rejects GF-010's own dirty files as outside that
bundle. After GF-010 is accepted and integrated, the same manifest can create
the `WEB-POC-001` pending approval without absorbing unrelated work.

## Integration and recovery

Direct mode fetches the configured remote, creates a detached worktree from
the current remote target, cherry-picks exact approved commits without conflict
resolution, validates, performs a normal non-force push, fetches again, and
requires the remote HEAD and tree to equal the validated expected result. Clean
movement before integration does not require reapproval; conflicts do. Movement
after the push is treated as an unexpected result and requires reconciliation.
Validation starts and ends on the exact recorded HEAD/tree with an empty Git
status; a validator that changes tracked or untracked content fails closed, and
the same clean-tree assertion is repeated immediately before push.
For the trusted Web policy, the isolated worktree receives a temporary ignored
`node_modules` symlink to the source repository only when both worktrees have
the exact same `package-lock.json`. The source dependency directory must be a
real directory, the link is verified and removed after validation, and the
mode plus lock digest are retained in validation evidence.
Immediately before direct push the target is fetched again: clean descendant
movement is merged and revalidated, while resets, rewrites, conflicts, or
repeated movement fail closed.

Repository, remote, target, mode, validation argv, force-push prohibition, and
PR policy come from the trusted per-project `config/integration.json`; a
manifest cannot redirect them. The policy file is itself content-bound when
the pending approval is created. Both fetch URL and push URL are mandatory,
persisted, and rechecked before fetch, push, merge, or branch deletion.
Per-approval and per-target filesystem locks cover approval, integration,
reconciliation, failure recording, and revocation so concurrent transactions
cannot race or overwrite state.

PR mode pushes an isolated approval branch. The fixture adapter persists a
mock PR receipt and exercises branch push, required-check state, merge, exact
target verification, branch cleanup, and crash replay. The GitHub adapter
reconciles an existing branch/PR before creation, waits for configured required
checks, merges by configured method, reads the actual merge commit, and verifies
that exact target result. Recovery reconciles both crash-after-PR-create and
crash-after-merge windows before replay. If a distinct review is required, the
transaction stops; a later reconciliation queries the review result and resumes
the mechanics automatically once the review is present. Before merge, PR mode
re-fetches the target; clean movement is merged into the approval branch using a
non-force fast-forward branch update, then validation and required checks rerun.
Non-descendant resets/rewrites, repeated movement, and conflicts fail closed.
The GitHub adapter additionally requires strict up-to-date-base branch
protection and passes the validated PR head SHA to the merge command, so GitHub
atomically refuses a merge if either the checked base or approved head changed.
Discovery is restricted to an open PR with the configured base, and both a
newly discovered and persisted PR must prove exact open state, head SHA, and
base branch before checks and again immediately before merge.
External-review policy stops at `HUMAN_REQUIRED_EXTERNAL_POLICY` without asking
the operator to run Git commands.

Temporary PR branch cleanup is conditional: Game Foundry proves the branch
still points to the exact validated integration commit before deletion, checks
the deletion transport result, and verifies remote absence afterward. A moved
branch is preserved, and an ambiguous lookup or deletion fails closed rather
than being reported as successful cleanup.
Deletion itself uses an exact compare-and-delete lease, so work pushed after
the lookup is also preserved. GitHub merge does not request branch deletion;
the same post-remote-verification cleanup transaction owns it.

Candidate changes, ambiguous adoption, validation failures, unresolved push
state, conflicts, authentication/policy failures, and corrupt evidence fail
closed. Ambiguous push recovery fetches before acting: exact presence completes,
proven absence retries the same validated integration commit, and unresolved
movement requires a human. Persisted worktree paths allow crash cleanup, and a
successful adoption cleans only its exact approved source paths after remote
verification. Worktree paths are persisted before `git worktree add`, and
adoption cleanup checkpoints each path before and after an idempotent mutation,
so crashes in either window can reconcile safely. Force push is rejected by
schema and runtime policy. GF-010
integrates source only and never deploys Cloudflare, R2, or a production game/site.

Every recovery entry point revalidates the bound policy digest, validation and
critic evidence, candidate commits, remote identity, and milestone snapshots
before completing an observed push. A proven-absent retry additionally
revalidates the live adoption fingerprint before it can push. Missing or
changed evidence fails closed and stale worktrees are still cleaned safely.
Approval creation also stores approval-owned byte-exact validation and critic
evidence copies. Live evidence remains mandatory until adoption cleanup begins;
after checkpointed cleanup intentionally restores or removes an adopted
evidence path, recovery verifies the preserved copy while cleanup verifies each
live path is exactly the approved candidate or its original baseline.
