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

## Implemented GF-001 acceptance loop

GF-001 operates on a detached temporary Git worktree. A dedicated `game-foundry` OpenClaw agent is model-pinned to `openai/gpt-5.6-sol`, with that model's `agentRuntime.id` pinned to the official `codex` harness. The installed OpenClaw 2026.7.1-2 stable CLI does not expose the documented `agent exec --cwd` surface, so the harness uses the supported Gateway-backed `openclaw agent` command and points the dedicated agent workspace at the isolated worktree. This compatibility choice is recorded in every manifest.

The acceptance result is derived from independent stages:

```text
OpenClaw/Codex claim
        │
        ▼
allowlisted Git diff
        │
        ▼
Godot import + static token validation
        │
        ▼
runtime markers + exact token
        │
        ├── rendered viewport screenshot under Xvfb
        │
        └── Linux export + exported self-test
        │
        ▼
manifest and machine-readable stage result
```

Any missing marker, unexpected file, unproven runtime, render failure, export failure, or exported-runtime failure produces a non-zero result. OpenClaw's response text is stored as evidence but never determines acceptance.

