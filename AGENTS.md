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
