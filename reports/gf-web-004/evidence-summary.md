# GF-WEB-004 Status

GF-WEB-004 PASS WITH WARNINGS

The canonical candidate is
`artifacts/gf-web-004/gf-web-004-acceptance-20260831T100611Z-95640`.
Deterministic acceptance completed in 227.830070 seconds with zero failures.
The independent critic returned PASS with zero blockers and one coverage
warning. Human gameplay QA remains pending.

## Game

- Game ID: `cyber-shield`
- Working title: Cyber Shield
- Engine: Godot 4.7.2 Standard
- Architecture: native Godot `Node2D`, 2D canvas drawing and rectangle collision
- Viewport: 960×540
- Source identity: `games/cyber-shield`
- Source files: 9, including generated Godot UID metadata
- Gameplay code: 350 lines in `cyber_shield.gd`

## Gameplay

- Controls: Left/Right, A/D, mouse horizontal position, and touch position
- Threat labels: PHISHING, VIRUS, MALWARE, DDoS, RANSOMWARE, BOTNET
- Spawn: repeated random horizontal positions at the fixed top region; every
  rectangle remains within the play bounds
- Fall speed: one shared 132 pixels/second speed
- Block: paddle intersection resolves one `BLOCKED` outcome, removes the threat,
  and adds exactly one score point
- Breach: passing the bottom resolves one `MISSED` outcome, removes the threat,
  and adds exactly one breach
- Game over: exactly three breaches, active threats cleared, spawning stopped,
  final blocked-attack score displayed
- Restart: R resets score, breaches, state, spawn clock/count, threats, and paddle

The browser-only deterministic mode is enabled solely by `?gf_test=1`. Its
S/B/M keys create controlled threats through normal Godot input and the same
fall/collision/miss resolver. They never assign score, breaches, or game state
directly. The normal local-preview URL has no query flag.

## Automated Game Acceptance

- Initial state (`score=0`, `breaches=0`, `PLAYING`): PASS
- Paddle movement: PASS
- Paddle left/right bounds: PASS
- Spawn bounds, 100 controlled samples: PASS
- First blocked threat (`score=1`): PASS
- Duplicate terminal-event protection: PASS
- Second blocked threat (`score=2`): PASS
- Miss exactly once (`breaches=1`): PASS
- Three-breach `GAME_OVER`: PASS
- Spawn stop after game over: PASS
- Clean restart: PASS

All 11 game-specific deterministic checks passed.

## Web Pipeline

- GF-WEB-001: PASS — real export, manifest, hash/integrity, source unchanged
- GF-WEB-002: PASS — real Chromium 151, real WASM, runtime ready, nonempty and
  input-changing canvas, keyboard/mouse input, zero console/page errors
- GF-WEB-003: PASS — current Cloudflare classifier, Pages/R2 package, manifest
  verification, asset-origin finalization, explicit CORS, local dual-origin
  Chromium validation
- Web bundle: 9 files, 39,866,473 bytes
- Largest file: `index.wasm`, 39,514,754 bytes
- Hosting profile: `cloudflare-pages-r2`
- Package: 5 Pages files and 4 R2 files
- Site route: `/games/cyber-shield/`

## Browser Gameplay

Two independent game-specific production-like Chromium runs passed, in
addition to the Cyber Shield GF-WEB-002 and GF-WEB-003 browser runs.

- ArrowLeft moved paddle X from 385.000 to 324.333: PASS
- Mouse moved paddle to X 604.333: PASS
- Touch moved paddle to X 295.533: PASS
- Two labeled threats spawned and fell from Y 91.4 to Y 133.2: PASS
- Real controlled paddle intersection changed score to 1: PASS
- Three real controlled misses produced `GAME_OVER`, breaches 3: PASS
- Active threats cleared and an attempted post-game spawn was rejected: PASS
- R returned to `PLAYING`, score/breaches/spawn count zero: PASS
- WASM: HTTP 200, `application/wasm`, separate asset origin, exact site CORS: PASS
- Console errors: 0; page errors: 0; browser/site/asset cleanup: PASS

## Linux Build

- Linux x86_64 export: PASS
- Runtime smoke marker: PASS
- Binary: 73,536,528 bytes

## Local Human Preview

LOCAL CYBER SHIELD PREVIEW COMMAND:

```text
./scripts/gf-web-local-preview.sh artifacts/gf-web-004/gf-web-004-acceptance-20260831T100611Z-95640/release
```

The command prints a dynamic loopback Game URL ending in
`/games/cyber-shield/`, serves the Pages shell and R2 assets, remains active
until Ctrl-C, and performs no remote action. Its automated smoke passed.

## Regression

Fresh after the single acceptance-harness repair:

- Doctor: READY
- GF-WEB-001: PASS, 1 deterministic iteration, 3 real Godot export invocations
- GF-WEB-002: PASS, 1 healthy run, complete fault matrix, cleanup iteration
- GF-WEB-003: PASS, 1 split Chromium run, 1 deterministic package iteration,
  complete negative matrix
- Acceptance source fingerprint: unchanged

## Critic

- Model: `gpt-5.6-sol`
- Calls: 1
- Decision: PASS
- Blockers: 0
- Warnings: 1
- Observations: 2
- Repair attempts before canonical acceptance: 1
- Human implementation interventions: 0

Warning: the query-free preview's disabled test mode is established by source
inspection and URL construction, but acceptance does not explicitly press
S/B/M in a query-free Chromium session and assert that controlled mutations do
not occur. This is non-blocking and is preserved here rather than reported as
fully covered.

## Evidence

- Game source: `games/cyber-shield`
- Game acceptance: `artifacts/gf-web-004/gf-web-004-acceptance-20260831T100611Z-95640/game/game-acceptance.json`
- Linux build/result: `artifacts/gf-web-004/gf-web-004-acceptance-20260831T100611Z-95640/linux/`
- Web manifest: `artifacts/gf-web-004/gf-web-004-acceptance-20260831T100611Z-95640/web-export/web-release.json`
- GF-WEB-002 browser: `artifacts/gf-web-004/gf-web-004-acceptance-20260831T100611Z-95640/gf-web-002/browser-result.json`
- Hosting manifest: `artifacts/gf-web-004/gf-web-004-acceptance-20260831T100611Z-95640/release/hosting-manifest.json`
- GF-WEB-003 browser: `artifacts/gf-web-004/gf-web-004-acceptance-20260831T100611Z-95640/gf-web-003/browser-result.json`
- Gameplay browser result: `artifacts/gf-web-004/gf-web-004-acceptance-20260831T100611Z-95640/game-browser/run-01/browser-result.json`
- Gameplay screenshot: `artifacts/gf-web-004/gf-web-004-acceptance-20260831T100611Z-95640/game-browser/run-01/cyber-shield-gameplay.png`
- Game-over screenshot: `artifacts/gf-web-004/gf-web-004-acceptance-20260831T100611Z-95640/game-browser/run-01/cyber-shield-game-over.png`
- GF-WEB-003 release: `artifacts/gf-web-004/gf-web-004-acceptance-20260831T100611Z-95640/release`
- Combined result: `artifacts/gf-web-004/gf-web-004-acceptance-20260831T100611Z-95640/result.json`
- Critic: `artifacts/gf-web-004/gf-web-004-acceptance-20260831T100611Z-95640/critic/result.json`

## Explicit Boundaries

MYTHADIS SITE INTEGRATION = NOT IMPLEMENTED

RCBLANZY SITE INTEGRATION = NOT IMPLEMENTED

REMOTE R2 UPLOAD = NOT IMPLEMENTED

CLOUDFLARE DEPLOYMENT = NOT IMPLEMENTED

## Human Gate

**HUMAN WEB GAMEPLAY QA = APPROVED**

- [x] Game loads in my normal browser.
- [x] Paddle is clearly visible.
- [x] Left/right keyboard movement works.
- [x] Mouse movement works.
- [x] Touch/drag works if tested on a touch device.
- [x] Cyber-threat labels are readable.
- [x] Threats repeatedly fall from the top.
- [x] Blocking an attack feels clear.
- [x] Score increases once per blocked attack.
- [x] Missed attacks increase BREACHES once.
- [x] Three breaches causes GAME OVER.
- [x] Threat spawning stops on GAME OVER.
- [x] Final score is visible.
- [x] R starts a clean new game.
- [x] No obvious browser errors occur.
- [x] The game is simple but genuinely playable.

Full approval was provided by the human authority on 2026-08-31. This records
the human gameplay gate without changing deterministic or critic evidence and
without independently authorizing production deployment or site integration.

## Recommendation

1. Yes. The deterministic and browser evidence shows Game Foundry created its
   first small but real playable Web game.
2. Yes. The conforming local release is ready for human gameplay testing with
   the exact preview command above.
3. After human approval, a separate bounded slice may integrate this release
   into a non-production Mythadis/rcblanzy route. This slice does not begin
   that integration or authorize deployment.
