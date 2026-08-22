# Game Foundry pipeline

Game Foundry separates AI-directed orchestration from deterministic execution. AI output is a proposal until the repository, Godot, and automated checks validate it.

```text
Human request
     ↓
OpenClaw
     ↓
Codex harness
     ↓
repository modification
     ↓
Godot CLI
     ↓
import / parse / test
     ↓
runtime smoke test
     ↓
visual artifact
     ↓
build artifact
     ↓
OpenClaw result synthesis
     ↓
human QA
     ↓
release approval
```

## Control plane

- Human: intent, creative direction, QA, and release approval.
- OpenClaw: orchestration, task routing, and result synthesis.
- Codex: scoped repository implementation.
- OpenAI or Ollama: inference used by agents.

## Deterministic execution plane

- Git records the exact source state.
- Godot imports, parses, executes, and exports the project.
- Tests determine regressions and acceptance.
- Build scripts create reproducible outputs.
- Artifacts preserve observable evidence and builds.

AI must never substitute its own opinion for deterministic build or test results. No AI agent can approve a production release.

