# GF-009 — scheduled unattended bounded execution

GF-009 provides a finite, scheduler-neutral entrypoint. A scheduler invokes
Game Foundry; it does not select tasks, reset failures, or interpret milestone
internals.

## Manual invocation

```bash
./scripts/gf-unattended-run.sh --json GF-MILESTONE-ID
./scripts/gf-unattended-run.sh --json --max-tasks 2 --max-minutes 45 GF-MILESTONE-ID
```

Defaults are one task and 45 minutes. The hard per-invocation ceilings are 10
tasks and 240 minutes.

Each invocation acquires the execution-domain lock `state/.unattended.lock`
without waiting. This prevents two unattended milestone invocations from
controlling the same Game Foundry state domain concurrently.
It then validates milestone state, invokes GF-008 recovery for any RUNNING
task, and only after successful reconciliation delegates remaining work to the
existing GF-005 `run-bounded` command. GF-H03 continues to own transport retry
and ambiguity handling. Lock files are never deleted based on age; `flock`
kernel ownership determines whether a runner is live.

Receipts are written to
`artifacts/unattended/<milestone>/<run-id>/result.json`. They record bounds,
initial and final state, task/call counts, recovery actions, accepted commits,
transport classifications, source heads, stop policy, artifact references,
and the runner-lock outcome. Child execution, critic, recovery, and transport
evidence remains in its authoritative artifact directory and is referenced
rather than copied.

## Exit semantics

| Shell | Exit class | Typical stop reason | Invoke later | Human action |
|---:|---|---|---|---|
| 0 | `SUCCESS_WORK_COMPLETED` | `TASK_LIMIT`, `TIME_LIMIT` | yes | no |
| 0 | `SUCCESS_IDLE` | `NO_READY_WORK` | yes | no |
| 0 | `SUCCESS_HUMAN_GATE` | `HUMAN_GATE` | no | yes |
| 0 | `SUCCESS_MILESTONE_COMPLETE` | `MILESTONE_COMPLETE` | no | no |
| 75 | `BUSY` | `RUNNER_BUSY` | yes | no |
| 20 | `ESCALATED` | `ESCALATED` | no | yes |
| 70 | `INFRASTRUCTURE_FAILURE` | preflight, recovery, source, or execution failure | receipt-dependent | normally yes |

The receipt fields `human_action_required`, `next_action`, and
`scheduler_should_invoke_again` are the scheduler-facing contract. A generic
scheduler only needs to invoke the command, retain the receipt, and either run
again later or request human review.

## systemd reference

Reference units live under `ops/systemd/`. They are templates for human review:
the milestone placeholder and workstation paths must be set before use. GF-009
does not install, enable, or start either unit. Scheduling cadence remains an
external operational choice.
