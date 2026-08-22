# TB-002 — Second Flush evidence

**Status: PASS**

OpenClaw and the Codex runtime converted Turd Burglar into a validated JSON-driven restroom runtime. Both levels use `scripts/level_loader.gd`, `scripts/restroom.gd`, and the same player, camera, toilet, HUD, exit, completion, and restart mechanics. There is no Second Flush gameplay class or generated/manual `restroom_002.tscn`.

## Architecture

- First Flush: `levels/restroom_001.json`
- Second Flush: `levels/restroom_002.json`
- Loader/validator: `scripts/level_loader.gd`
- Shared builder/controller: `scripts/restroom.gd`
- Format: small restroom-specific JSON schema for identity, objective, spawn, exit, toilets, primitive geometry, colors, lighting, environment, and labels.

## Acceptance

| Gate | Result |
|---|---:|
| First Flush regression | PASS |
| Second Flush: six toilets | PASS |
| Second Flush: five turds and one empty toilet | PASS |
| Dynamic HUD `0 / 5` through `5 / 5` | PASS |
| Exit locked through four, unlocked at five | PASS |
| Heist completion | PASS |
| Data-driven runtime proof | PASS |
| Missing required field rejected | PASS |
| Invalid JSON rejected | PASS |
| Objective mismatch rejected | PASS |
| Missing level file rejected | PASS |
| Distinct 960×540 screenshots | PASS |
| Single Linux export loads both levels | PASS |

## Data-driven proof

The test copied `restroom_002.json` to a temporary definition and changed only `player_spawn` from `[-6.0, 0.05, 6.1]` to `[-8.75, 0.05, 5.25]`. The real shared runtime instantiated the player at the proof position without changing gameplay code.

The acceptance runner also moved `restroom_002.json` away temporarily. Loading Level 2 then returned non-zero with `level=restroom_002 field=file reason=not found`. Restoring the JSON restored Level 2 in source and exported runtimes.

## Automation

| Metric | Actual value |
|---|---:|
| OpenClaw/Codex execution | 1,772.758 seconds |
| Godot validation | 2.918 seconds |
| Build | 2.623 seconds |
| Final independent acceptance | 11.561 seconds |
| Total pipeline | 1,892 seconds |
| Human implementation interventions | 0 |
| Human implementation minutes | 0 |
| Manual Godot editor changes | 0 |
| Manual human source changes | 0 |
| Human Implementation Minutes Per New Level | 0 |

## Artifacts

- First Flush screenshot: `artifacts/tb-002/tb002-20260822T224200Z-39afcc/first-flush.png`
- Second Flush screenshot: `artifacts/tb-002/tb002-20260822T224200Z-39afcc/second-flush.png`
- Linux executable: `artifacts/tb-002/tb002-20260822T224200Z-39afcc/build/turd-burglar.x86_64`
- Required pack: `artifacts/tb-002/tb002-20260822T224200Z-39afcc/build/turd-burglar.pck`
- Manifest: `artifacts/tb-002/tb002-20260822T224200Z-39afcc/manifest.json`

Human visual/gameplay approval remains pending and is not claimed. No release was published, and TB-003 was not started.
