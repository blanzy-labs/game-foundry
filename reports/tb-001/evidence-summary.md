# TB-001 — First Flush evidence

**Status: PASS WITH WARNINGS**

Game Foundry produced the first playable Turd Burglar room through OpenClaw → Codex → Godot. GF-002 prerequisites passed before work began. The game repository was authored by the dedicated Codex agent, and the final deterministic acceptance passed on commit `4d5b3e510268c5af5ae39899a591e43c5c91589d`.

## Pipeline

| Stage | Result |
|---|---:|
| OpenClaw | PASS WITH WARNING |
| Codex runtime | PASS |
| Godot static | PASS |
| Godot runtime | PASS |
| Gameplay tests | PASS |
| Two rendered screenshots | PASS |
| Linux x86_64 export | PASS |
| Exported runtime | PASS |

The initial long-running Gateway request reached its client timeout after the implementation commit and acceptance had completed. The same-session OpenClaw/Codex follow-up returned successfully, identified `agentHarnessId: codex`, made only the requested repository-hygiene cleanup, and reconfirmed static validation. No deterministic game stage failed.

## Gameplay proof

Automated markers prove movement, camera control, zero/locked start state, first collection, duplicate prevention, exactly three collected turds, exit unlock, heist completion, and restart. The room contains three stalls, three toilets, three primitive turd visuals, floor/wall collision, a third-person player, HUD, and one exit.

## Automation metric

| Metric | Value |
|---|---:|
| Human implementation interventions | 0 |
| Human implementation minutes | 0 |
| Agent execution | 1,268.707 seconds |
| Godot validation | 2.917 seconds |
| Build | 2.623 seconds |
| Final deterministic acceptance | 8.859 seconds |
| Total pipeline | 1,497 seconds |

## Artifacts

- Start screenshot: `artifacts/tb-001/tb001-20260822T220747Z-e07856/screenshot-start.png`
- Completion screenshot: `artifacts/tb-001/tb001-20260822T220747Z-e07856/screenshot-complete.png`
- Linux executable: `artifacts/tb-001/tb001-20260822T220747Z-e07856/build/turd-burglar.x86_64`
- Manifest: `artifacts/tb-001/tb001-20260822T220747Z-e07856/manifest.json`

Both screenshots are non-empty 960×540 PNGs. The executable is an x86-64 ELF and its self-test emitted the exact required runtime markers.

## Manual QA

Human play-test approval is pending and is not claimed. Launch:

```bash
/home/blanzy/projects/game-foundry/artifacts/tb-001/tb001-20260822T220747Z-e07856/build/turd-burglar.x86_64
```

Verify movement, camera feel, all three one-shot interactions, HUD increments, exit unlock, completion, and restart. No release was published, and TB-002 was not started.
