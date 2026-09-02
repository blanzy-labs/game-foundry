# GF-WEB-003 Status

GF-WEB-003 PASS

## Discovered Constraint

- Cloudflare Pages maximum file bytes: 26,214,400 (25 MiB)
- Canonical GF-WEB-002 `index.wasm`: 39,514,754 bytes
- Pages-only compatibility: FAIL — `index.wasm` exceeds the limit by 13,300,354 bytes
- Compression evidence: raw 39,514,754; gzip 10,248,949; Brotli 8,300,310 bytes. Classification remains based on the uploaded source asset size.

## Hosting Strategy Evaluation

- Pages-only: FAIL for the canonical Godot bundle because the WASM exceeds the trusted Pages limit. The profile still passes a small synthetic package through the shared Chromium harness.
- Pages+R2: PASS. The real Godot shell loads from a Pages-like origin and the real WASM/PCK load from a separate R2-like origin with explicit CORS.
- Same-origin proxy: NOT NEEDED. Direct cross-origin loading passed in real Chromium.

## Canonical Hosting Contract

CANONICAL GODOT WEB CLOUDFLARE PROFILE =
cloudflare-pages-r2

The checked-in Cloudflare profile is authoritative. It is SHA-256-bound into the hosting manifest, and verification/finalization always load the exact checked-in configuration. Oversized files and Godot executable-derived assets go to versioned R2 paths. The HTML, primary loader, and icons remain in the Pages route.

## Package

- Pages: 5 files, 324,422 bytes; largest file `index.js` at 279,815 bytes.
- R2: 4 files, 39,528,777 bytes; largest file `index.wasm` at 39,514,754 bytes.
- Total source bundle: 9 files, 39,853,139 bytes.
- Pages route: `games/web-fixture/`.
- R2 prefix: `assets/web-fixture/dc5904cc6c54ea78/`.
- Source-manifest SHA-256: `dc5904cc6c54ea78a6efe89f27c1911ded43217f23e0a1c23c3bff95906819a8`.

## Asset Origin

- Contract: a manifested `__GF_WEB_ASSET_ORIGIN__` placeholder is instantiated by the explicit finalizer.
- Transformed file: `index.html` only; its original, placeholder output, and finalized output are hash-tracked.
- CORS: exact site origin, GET and HEAD, `Access-Control-Allow-Origin`, no wildcard.
- MIME: HTML `text/html; charset=utf-8`; JavaScript `text/javascript; charset=utf-8`; WASM `application/wasm`; PCK `application/octet-stream`; PNG `image/png`.
- Cache: HTML `no-cache`; versioned R2 assets `public, max-age=31536000, immutable`; other site assets use the manifested site-asset class.
- The local servers serve only manifested paths and derive MIME/cache behavior from verified file records.

## Local Browser Proof

- Site URL: `http://127.0.0.1:43133`
- Asset URL: `http://127.0.0.1:37487`
- WASM URL: `http://127.0.0.1:37487/assets/web-fixture/dc5904cc6c54ea78/index.wasm`
- WASM response: 200, `application/wasm`, 39,514,754 bytes
- CORS: PASS; allowed origin was exactly `http://127.0.0.1:43133`
- Runtime READY: PASS
- Canvas: PASS at 1280×720; nonempty and changed after input
- Keyboard: PASS; Space changed `IDLE` to `INPUT_RECEIVED`
- Mouse: PASS
- Console errors: 0
- Page errors: 0
- Failed required requests: 0
- Cleanup: browser, site server, and asset server closed; zero browser processes remained
- Visual inspection: PASS; the screenshot contains the rendered green canvas and pink face fixture.

## Manual Preview

LOCAL HUMAN WEB PREVIEW:

```text
./scripts/gf-web-local-preview.sh <release-dir>
```

For this evidence artifact:

```text
./scripts/gf-web-local-preview.sh artifacts/gf-web-003/gf-web-003-acceptance-20260831T000712Z/release
```

Open the printed `Game URL`. The command binds loopback addresses, prints the asset URL for split releases, remains active for inspection, and cleans up both servers on Ctrl-C.

## Repeatability

- Real split Godot Chromium runs: 10 PASS, 0 FAIL.
- Independent deterministic package/finalize/verify iterations: 20 PASS, 0 FAIL.
- Pages-only synthetic Chromium path: PASS.
- Manual split preview smoke: PASS.
- Pages-only single-origin preview smoke: PASS.

## Negative Tests

All 36 negative cases passed by producing the required rejection:

- Pages oversized asset
- Missing R2 asset
- Large asset leaked into Pages
- Manifest/package mismatch
- Hash tamper
- Unsafe deployment path
- Duplicate deployment path
- Source asset omission
- Missing entrypoint transformation
- Incomplete CORS/header contract
- External source-manifest path
- Entrypoint deployment mismatch
- Placeholder transformation hash mismatch
- Inflated self-declared Pages limit
- Non-WASM MIME drift
- Per-file cache-policy drift
- Invalid embedded GF-WEB-001 manifest
- Source content-role mismatch
- Hosting/source identity mismatch
- Ambient forged-profile override
- Release-root symlink
- Hosting-manifest symlink
- Source-manifest symlink
- Package-root symlink
- Nested-package symlink
- Wrong asset origin
- Missing CORS
- Wrong CORS origin
- Wrong WASM MIME
- Dual-server cleanup after failure
- Malformed finalization origin
- Invalid fixed-origin manifest
- Finalized CORS/site-origin mismatch
- Invalid runtime target
- Invalid site package
- Invalid asset package

## Regression

- Doctor: READY
- GF-H03: PASS, 1/1
- GF-009: PASS, 1 iteration, 0 failures
- GF-WEB-001: PASS, 1 iteration, 3 real Godot exports, 0 failures
- GF-WEB-002: PASS, 1 healthy Chromium run, complete fault matrix, 1 deterministic cleanup iteration, 0 failures
- GF-WEB-003: PASS, 10/10 browser, 20/20 deterministic, 36/36 negative, 0 failures

## Critic

- Model: `gpt-5.6-sol`
- Decision: PASS
- Blockers: 0
- Warnings: 0
- Observations: 4

The observations confirm symlink containment, embedded GF-WEB-001 provenance validation, manifested hosting behavior, and complete fresh acceptance/regression evidence.

## Evidence

- Classification: `artifacts/gf-web-003/gf-web-003-acceptance-20260831T000712Z/classification.json`
- Hosting manifest: `artifacts/gf-web-003/gf-web-003-acceptance-20260831T000712Z/release/hosting-manifest.json`
- Pages package: `artifacts/gf-web-003/gf-web-003-acceptance-20260831T000712Z/release/pages`
- R2 package: `artifacts/gf-web-003/gf-web-003-acceptance-20260831T000712Z/release/r2`
- Finalized local package: `artifacts/gf-web-003/gf-web-003-acceptance-20260831T000712Z/healthy/run-01/finalized-local`
- Browser result: `artifacts/gf-web-003/gf-web-003-acceptance-20260831T000712Z/healthy/run-01/browser-result.json`
- Network/CORS evidence: `artifacts/gf-web-003/gf-web-003-acceptance-20260831T000712Z/healthy/run-01/network.json`
- Runtime screenshot: `artifacts/gf-web-003/gf-web-003-acceptance-20260831T000712Z/healthy/run-01/browser-runtime-ready.png`
- Pages-only browser result: `artifacts/gf-web-003/gf-web-003-acceptance-20260831T000712Z/pages-only-browser/browser-result.json`
- Negative evidence: `artifacts/gf-web-003/gf-web-003-acceptance-20260831T000712Z/negative`
- Acceptance result: `artifacts/gf-web-003/gf-web-003-acceptance-20260831T000712Z/result.json`
- Regression evidence: `artifacts/gf-web-003/regression-20260831T000921Z`
- Critic result: `artifacts/gf-web-003/gf-web-003-acceptance-20260831T000712Z/critic/result.json`
- Combined machine report: `reports/gf-web-003/evidence-summary.json`

## Explicit Boundaries

LOCAL PRODUCTION-LIKE HOSTING SIMULATION = PASS

MYTHADIS SITE INTEGRATION = NOT IMPLEMENTED
RCBLANZY SITE INTEGRATION = NOT IMPLEMENTED
REMOTE R2 UPLOAD = NOT IMPLEMENTED
CLOUDFLARE DEPLOYMENT = NOT IMPLEMENTED

## Recommendation

1. The current canonical Godot Web bundle is not compatible with Pages-only hosting because its WASM is 13,300,354 bytes over the trusted limit.
2. The Pages/R2 contract is technically proven in a real local browser with real Godot execution, explicit cross-origin WASM/PCK loading, CORS, rendering, and input.
3. Game Foundry is ready for a HUMAN LOCAL TEST of a real Web game with `./scripts/gf-web-local-preview.sh <release-dir>`.
4. After that human test, the next slice should implement a bounded site-consumer/release integration that installs the Pages package, publishes the versioned R2 package, applies explicit headers/CORS, finalizes site-specific origins, and runs post-deploy browser acceptance behind its own human deployment gate.

## Human Gate

**HUMAN GF-WEB-003 APPROVAL = APPROVED**

Approval was provided by the human authority on 2026-08-31. This records the
human gate decision without changing the deterministic acceptance evidence or
authorizing a Cloudflare deployment, production release, or subsequent slice.
