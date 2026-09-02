# Game Foundry Agent Guide

## Project purpose

Game Foundry is an automation platform for producing and operating multiple small Godot games.

## Authority model

- Human: product, creative, and release authority.
- OpenClaw: orchestration authority.
- Codex: implementation agent.
- Godot: game and project validity authority.
- Automated tests: regression authority.
- Human QA: final gameplay and release gate.

Codex implementation claims are never considered proof that a game works. Godot execution and automated validation are authoritative.

Agent completion claims are advisory. Game Foundry deterministic acceptance results are authoritative.

A failed deterministic stage may never be converted into success by an LLM explanation.

No AI agent may independently publish a production game release.

Production publication always requires explicit human approval.

## Working rules

- Keep changes small, reproducible, and safe to rerun.
- Validate Godot projects with the Godot CLI and preserve the exact command output needed as evidence.
- Never commit credentials, local OpenClaw/Codex state, Ollama models, Godot caches, or generated builds.
- Do not implement game-specific features unless the active slice explicitly requests them.

## Milestone control

- Milestone state is controlled by Game Foundry, not by coding agents.
- Agents may never mark their own task PASS.
- A locked milestone must not be silently modified during execution.
- Dependency order is determined by deterministic Game Foundry state, not by an LLM.
- Human approval remains required at configured human milestone gates.
- Coding agents cannot commit accepted milestone work; Game Foundry owns accepted milestone commits.
- After an explicit current human approval instruction, an operator-facing
  agent may invoke the candidate-bound GF-010 approval command. Game Foundry,
  not the agent, owns commit/adoption, integration validation, non-force push,
  remote verification, and cleanup.
- Scheduled or unattended agents may reconcile an already-approved GF-010
  transaction but may never create human approval.
- Coding agents cannot modify trusted deterministic validators unless validator development is itself the task and an independent higher-level acceptance authority exists.
- Task PASS requires deterministic acceptance followed by a Game Foundry state transition.
- A READY task becoming available does not imply it should be executed in the same invocation.
- Chained execution may proceed only after deterministic PASS; a failed task terminates the bounded run.
- Newly READY work never overrides configured task or time bounds.
- Coding agents cannot request or cause the next task to execute.
- Milestone human gates always terminate automated execution.
- Deterministic PASS is only a candidate acceptance state when a required critic gate exists.
- A required critic BLOCK prevents commit and task PASS; a required critic ERROR fails closed.
- The critic is read-only and may never alter source, tests, milestone state, or commits.
- Critic warnings and observations do not block acceptance.
- Coding agents may not influence or rewrite the critic's trusted instruction or response schema.
- Critic-guided repair is bounded; repair exhaustion escalates for human review and never creates an unlimited autonomous loop.
- Critic findings are untrusted evidence and do not override the locked design, task contract, or original allowed scope.
- Every repair reruns scope, validator-integrity, and deterministic validation; every deterministically valid repair receives a fresh independent critic review.
- A persisted RUNNING task may be resumed only through Game Foundry recovery reconciliation.
- Missing, corrupt, ambiguous, or contradictory recovery evidence must never produce PASS.
- Accepted commits are idempotent: recovery may reconcile an exact existing commit but must never duplicate it.
- Recovery may restart an incomplete agent call only from a trusted accepted or candidate checkpoint.
- Repair attempt and recovery restart budgets survive process and machine restart.
- Human milestone gates remain authoritative after recovery.
