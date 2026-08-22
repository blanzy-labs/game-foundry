# GF-001 — end-to-end acceptance

GF-001 tests whether OpenClaw can delegate one tightly scoped source mutation to the official Codex harness and whether Godot can independently prove the resulting source, runtime, render, and standalone build.

This is an integration fixture, not a game.

## Architecture

Each run creates a unique run ID and mutation token, then creates a detached Git worktree from the clean current commit. A dedicated OpenClaw agent uses `openai/gpt-5.6-sol` with per-model runtime policy `agentRuntime.id = codex`. The agent may modify only `fixtures/godot-smoke/automation_target.gd`.

The installed stable OpenClaw CLI does not currently expose the live documentation's `openclaw agent exec --cwd` options. GF-001 therefore uses the supported Gateway-backed `openclaw agent` command with the dedicated agent workspace redirected to the temporary worktree. Runtime policy, plugin status, authentication, OpenClaw JSON, audit data, and Gateway logs are retained as evidence; failure to prove actual Codex selection is fatal.

## Commands

Run the complete acceptance loop:

```bash
./scripts/gf-001-acceptance.sh
```

Run all controlled negative tests:

```bash
./scripts/gf-001-failure-tests.sh
```

Both commands return zero only when every expected condition is satisfied.

## Artifacts

Each run writes to `artifacts/gf-001/<run-id>/`:

- agent task, stdout, stderr, JSON result, audit, and runtime-policy evidence;
- agent patch and worktree lifecycle log;
- Godot import, validation, runtime, screenshot, export, and exported-runtime logs;
- a rendered 640×360 PNG and its SHA-256 in `manifest.json`;
- an exported Linux x86_64 executable;
- stage timings and a deterministic pass/fail manifest.

The latest concise outputs are `reports/gf-001/latest.json` and `reports/gf-001/latest.txt`. Generated artifacts and latest-run reports are Git-ignored.

## Pass/fail semantics

Agent prose is advisory. Git must show exactly one allowlisted change containing the unique token. Godot must then import the project, validate the exact token, run it, render it, export it, and run the exported executable with exact success and token markers. Any failed critical stage returns non-zero and remains failed regardless of an agent explanation.

## Failure injection

The negative test proves that the validators reject:

1. deliberately broken temporary GDScript;
2. a successful runtime log containing the wrong token;
3. an unauthorized Git mutation outside the target;
4. a missing screenshot.

All corrupt content lives in temporary workspaces and is removed afterward.

## Human review

Open each run's `screenshot.png` and confirm that it visibly shows the same mutation token recorded in `manifest.json`. Confirm the run IDs, tokens, and artifact directories differ across repeat runs. Human visual review supplements programmatic PNG type, size, dimensions, and checksum validation.

## Known limitations

- Visual text matching is human-reviewed; GF-001 does not claim OCR.
- The stable OpenClaw build uses the Gateway-backed headless surface because `agent exec --cwd` is not present in its CLI parser.
- The exported runtime is a Linux x86_64 smoke fixture, not a distributable game package.
