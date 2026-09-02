# GF-WEB-002 — Browser runtime acceptance

GF-WEB-002 proves that a GF-WEB-001 integrity-verified bundle boots and
responds to real input in repository-pinned Playwright Chromium. It remains a
capability of the existing Game Foundry execution plane and does not add a
deployment pipeline.

## Canonical browser and prerequisites

The canonical runtime is Playwright `1.62.1` with its managed Chromium,
installed once with `npm ci` followed by `npx playwright install chromium`.
Acceptance never installs or downloads dependencies. Doctor reports Node,
Playwright, the managed Chromium executable/version, and the GF-WEB-001 export
prerequisite as separate critical checks.

## Runtime contract

`scripts/gf-web-browser-test.sh MANIFEST BUNDLE ARTIFACT_DIR` first invokes the
GF-WEB-001 verifier. It then runs a repository-owned Node harness that binds an
ephemeral port on `127.0.0.1`, serves only the release root with explicit HTML,
JavaScript, WASM, PCK, and image MIME types, and launches an isolated headless
Chromium context with service workers blocked and caching disabled by server
policy.

The fixture publishes `GF_WEB_RUNTIME_READY` from GDScript after `_ready()` by
using `JavaScriptBridge`. It also publishes IDLE/INPUT_RECEIVED state and
keyboard/mouse receipts from `_unhandled_input()`. No ready marker is added to
static HTML, and the browser harness never invokes fixture game methods.

Canonical desktop acceptance uses 1280×720, clicks the canvas, sends Space,
requires the Godot state to become INPUT_RECEIVED, serializes canvas pixels
before and after input, and captures `browser-runtime-ready.png`. It resizes the
live page to 1024×640 and performs a fresh 390×844 runtime smoke. The smaller
viewport is runtime/layout smoke only.

Unexpected console errors, page exceptions, required-resource failures,
invalid WASM MIME, missing READY, zero/hidden canvas,
blank/transparent/unchanged rendering,
or nonresponsive input fail closed. Startup and input waits are bounded.
Browser/context and server closure occur in `finally`, and machine-readable
console, page-error, network, timing, cleanup, and result evidence is written
for success and failure.

Controlled fault hooks are disabled unless
`GF_GF_WEB002_ENABLE_TEST_HOOKS=1`. They cover missing WASM, broken runtime JS,
READY timeout, page exception, console error, input failure, zero canvas, blank
pixel output, bad WASM MIME, HTTP bind/close failure, and failed-run cleanup. Integrity bypass exists
only for those controlled corrupt-bundle cases.

The default 20-iteration deterministic loop repeats the inexpensive pre-launch
server-bind and cleanup path. Each full post-launch browser/runtime fault is run
once; the 10-run healthy sample separately repeats real Chromium startup and
shutdown.

## Meaning of PASS

PASS proves a fresh real Chromium requested the manifest's WASM and critical
assets over loopback HTTP, executed Godot game logic to READY, rendered a
nonempty changing canvas, delivered keyboard and mouse input through Godot,
remained alive through resize and a small viewport smoke, produced a
screenshot, and emitted no unexpected browser/runtime error.

**CHROMIUM RUNTIME = TESTED**

**MULTI-BROWSER COMPATIBILITY = NOT TESTED**

**MOBILE/TOUCH UX = NOT TESTED**

**ASTRO INTEGRATION = NOT IMPLEMENTED**

**CLOUDFLARE DEPLOYMENT = NOT IMPLEMENTED**
