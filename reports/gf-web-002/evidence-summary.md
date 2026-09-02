# GF-WEB-002 evidence summary

## GF-WEB-002 Status

**GF-WEB-002 PASS WITH WARNINGS**

The deterministic acceptance result is PASS. The required independent critic
decision is PASS with zero blockers and two reporting-quality warnings.

## Canonical Browser

- Node: `v24.19.0`
- Playwright: `1.62.1` (repository pinned)
- Chromium: `151.0.7922.34` (`Google Chrome for Testing`)
- Mode: headless
- Launch arguments: `--disable-background-networking` plus a unique
  `--gf-web-acceptance-*` process marker used to prove process cleanup
- Canonical desktop viewport: `1280 x 720`
- Small viewport: `390 x 844`

## HTTP Server

The browser harness uses a repository-owned Node `http` server bound only to
`127.0.0.1` on an ephemeral port. The canonical URL was
`http://127.0.0.1:37415/index.html`. It serves only the verified GF-WEB-001
release root and assigns explicit HTML, JavaScript, WASM, PCK, and image MIME
types. The canonical WASM response used `application/wasm`.

The server and browser close in `finally`. Close callback errors fail closed,
and Chromium process markers are checked through `/proc` after Playwright
closes. Canonical cleanup recorded no close errors, no remaining marked
Chromium processes, and a closed HTTP server.

## Web Runtime

- Entrypoint: `index.html`
- Navigation: HTTP `200`; final URL unchanged
- WASM: `index.wasm`, HTTP `200`, `application/wasm`, `39,514,754` bytes
- READY mechanism: GDScript calls `JavaScriptBridge` from `_ready()` and sets
  `window.GF_WEB_RUNTIME_READY`; static HTML contains no READY marker
- Runtime READY: `0.838493 s`
- Canvas: `1280 x 720`, visible and nonzero
- Render proof: a `64 x 64` pixel sample was fully opaque, contained six RGBA
  values, and had a luminance range of `150.037`; the PNG digest changed after
  input
- Screenshot: actual Godot canvas rendering, with no HTML proof overlay

## Input

- Keyboard action: `Space`
- Initial state: `IDLE`
- Expected state: `INPUT_RECEIVED`
- Observed state: `INPUT_RECEIVED`
- Input response: `0.065027 s`
- Mouse acceptance: PASS; a left click inside the canvas reached Godot and set
  the GDScript mouse receipt

## Browser Health

The two browser profiles emitted eight log messages and four WebGL
readback-performance warnings. Console errors were `0`, uncaught page
exceptions were `0`, and failed required resources were `0`. The warnings are
Chromium GPU-stall messages caused by acceptance pixel readback; they are not
runtime errors and are retained in machine-readable evidence.

## Viewports

- Desktop `1280 x 720`: PASS for boot, READY, render, keyboard, mouse,
  screenshot, network, and browser health
- Small `390 x 844`: PASS for fresh runtime boot and visible canvas smoke
- Live resize to `1024 x 640`: PASS; runtime remained READY and canvas remained
  visible

**MOBILE/TOUCH UX = NOT TESTED**

## Negative Tests

- Missing WASM: PASS (rejected)
- Broken JavaScript: PASS (rejected)
- Runtime never READY: PASS (rejected)
- Page exception: PASS (rejected)
- Console error: PASS (rejected)
- Input nonresponsive: PASS (rejected)
- Zero-size canvas: PASS (rejected)
- Blank canvas pixels: PASS (rejected)
- Bad WASM MIME: PASS (rejected)
- HTTP server bind failure: PASS (rejected)
- HTTP server close failure: PASS (rejected with `server_closed=false` and a
  recorded close error)
- Orphan cleanup: PASS

## Repeatability

- Real Chromium healthy runs: `10 PASS`, `0 FAIL`
- Full negative matrix: `12 PASS`, `0 FAIL`; each case ran once
- Deterministic pre-launch server bind/cleanup iterations: `20 PASS`, `0 FAIL`

The 20-iteration result applies specifically to the inexpensive pre-launch
bind/cleanup path. It does not claim 20 repetitions of every post-launch
runtime fault.

## Timings

- Server start: `0.003869 s`
- Browser launch: `0.066981 s`
- HTML navigation: `0.080577 s`
- Runtime READY: `0.838493 s`
- Input response: `0.065027 s`
- Canonical total: `3.267871 s`
- Full 10-run/negative/20-iteration acceptance: `156.297765 s`

No production performance SLO is established by this slice.

## Regression

- Doctor: PASS (`33` critical checks passed, `0` failed)
- GF-H03: PASS (`1/1`)
- GF-009: PASS (`1` iteration, `0` failures)
- GF-WEB-001: PASS (`1` deterministic iteration, three real Godot exports,
  `0` failures)
- GF-WEB-002: PASS (`10/10` healthy, `12/12` negative, `20/20` deterministic)

GF-004, GF-005, GF-008, and GF-H02 were not run as separate suites for this
targeted browser-runtime slice and are not reported as PASS.

## Critic

- Model: `gpt-5.6-sol`
- Decision: PASS
- Blockers: `0`
- Warnings: `2`
- Observations: `0`

The critic noted that the recorded keyboard initial state is sampled before
the mouse click, although the mouse path leaves that state at `IDLE`, and that
the deterministic summary pass/fail counts are serialized from the requested
iteration count rather than separate aggregate counters. Both concerns are
nonblocking and do not alter the underlying per-check records or overall
fail-closed result.

## Evidence

- Doctor JSON: `artifacts/gf-web-002/gf-web-002-acceptance-20260830T215116Z/doctor.json`
- GF-WEB-001 manifest: `artifacts/gf-web-002/gf-web-002-acceptance-20260830T215116Z/gf-web-001-release/web-release.json`
- Browser result: `artifacts/gf-web-002/gf-web-002-acceptance-20260830T215116Z/healthy/run-01/browser-result.json`
- Network: `artifacts/gf-web-002/gf-web-002-acceptance-20260830T215116Z/healthy/run-01/network.json`
- Console: `artifacts/gf-web-002/gf-web-002-acceptance-20260830T215116Z/healthy/run-01/console.json`
- Page errors: `artifacts/gf-web-002/gf-web-002-acceptance-20260830T215116Z/healthy/run-01/page-errors.json`
- Timings: `artifacts/gf-web-002/gf-web-002-acceptance-20260830T215116Z/healthy/run-01/timings.json`
- Runtime screenshot: `artifacts/gf-web-002/gf-web-002-acceptance-20260830T215116Z/healthy/run-01/browser-runtime-ready.png`
- Healthy acceptance result: `artifacts/gf-web-002/gf-web-002-acceptance-20260830T215116Z/evidence-summary.json`
- Negative evidence: `artifacts/gf-web-002/gf-web-002-acceptance-20260830T215116Z/negative/`
- Deterministic cleanup evidence: `artifacts/gf-web-002/gf-web-002-acceptance-20260830T215116Z/deterministic/`
- Regression evidence: `artifacts/gf-web-002/regression-20260830T213738Z/`
- Critic result: `artifacts/gf-web-002/gf-web-002-acceptance-20260830T215116Z/critic/result.json`
- Combined machine-readable report: `reports/gf-web-002/evidence-summary.json`

## Explicit Boundaries

**CHROMIUM RUNTIME ACCEPTANCE = PASS**

**MULTI-BROWSER COMPATIBILITY = NOT TESTED**

**MOBILE/TOUCH UX = NOT TESTED**

**ASTRO SITE INTEGRATION = NOT IMPLEMENTED**

**CLOUDFLARE DEPLOYMENT = NOT IMPLEMENTED**

No Turd Burglar gameplay, production site, Astro, or Cloudflare configuration
was modified, and nothing was deployed.

## Human Gate

**HUMAN GF-WEB-002 APPROVAL = PENDING**

## Recommendation

1. Yes. Game Foundry can now prove that a GF-WEB-001-verified Godot Web bundle
   boots in real Chromium, loads actual WASM, reaches GDScript READY, renders,
   and responds to browser-delivered keyboard and mouse input.
2. Yes. GF-WEB-003 — Astro / Cloudflare Release Contract is the correct next
   slice. It was not started here.
3. GF-WEB-003 must preserve correct WASM and static-asset MIME types, release
   root paths, focus/input behavior, cache and integrity behavior, and visible
   error reporting in hosted conditions. Current proof covers one managed
   headless Chromium runtime, a single-threaded Compatibility export, and
   layout smoke at a small viewport. It does not prove Firefox/WebKit/Safari,
   touch UX, production hosting, CDN behavior, or a real game workload.

**HUMAN GF-WEB-002 APPROVAL = PENDING**
