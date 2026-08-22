# GF-002 evidence summary

**Status: PASS**

The canonical command remains `./scripts/gf-001-acceptance.sh`, and the accepted Gateway-backed OpenClaw → Codex route is unchanged. Critical source-token, source-scope, Godot static/runtime, screenshot, export, and exported-runtime decisions are shared between production acceptance and fault testing through `scripts/lib/gf-001-common.sh`.

The test-only driver is disabled unless `GF001_TEST_MODE=1` is explicitly supplied with a recognized fault name. Its process result is the shared production gate's real exit code. The helper suite passed 6/6 checks.

## Fault injection

| Case | Result | Production gate exit | Key proof |
|---|---:|---:|---|
| A — Broken GDScript | PASS | 1 | Real Godot parse failure rejected |
| B — Wrong token | PASS | 1 | Application exited 0 and runtime marker was present; exact token gate rejected output |
| C — Unauthorized source change | PASS | 1 | Allowed target plus `README.md` rejected by shared scope gate |
| D — Missing screenshot | PASS | 1 | Prior command result and token were valid; missing PNG rejected |
| E — Agent success / Godot failure | PASS | 1 | Mock agent result was success and source gate passed; real Godot parse failure was authoritative |

Full fault evidence: `reports/gf-002/fault-injection.json`.

## Canonical happy-path regression

| Field | Evidence |
|---|---|
| Run ID | `gf001-20260822T214748Z-70abd6` |
| Mutation token | `GF001_70ABD6` |
| Base commit | `07cd8703ce8a80b5a2c4ec0d416406d5fa6a55ed` |
| Codex runtime | PASS — result/audit recorded `agentHarnessId/runtime=codex` |
| Godot static/runtime | PASS / PASS |
| Screenshot | PASS — 640×360, 19,102 bytes, SHA-256 `617e654fa08187bf887fe151a2b5738b9739fff1efb9d058bdb6c41d24dbd1de` |
| Export / exported runtime | PASS / PASS |
| Cleanup | PASS |
| Human interventions | 0 |

Latest screenshot for human review:

`artifacts/gf-001/gf001-20260822T214748Z-70abd6/screenshot.png`

Human visual review was **not performed or claimed**. Follow the four-step procedure in `docs/slices/GF-002-production-gate-hardening.md`.

PASS remains written only after the cleanup stage succeeds. The two accepted GF-001 baseline runs remain preserved, and no Turd Burglar work was started.
