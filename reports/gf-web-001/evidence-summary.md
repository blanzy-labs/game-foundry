# GF-WEB-001 evidence summary

## GF-WEB-001 Status

**GF-WEB-001 FAIL**

The implementation and Web-specific deterministic acceptance pass. The slice
cannot be accepted because the required current GF-008 regression was not run,
and the independent critic correctly returned BLOCK. The shell has working
Codex OAuth but no `OPENAI_API_KEY`; the official GF-008 suite requires that
key for its nested Responses-API critic regression. Prior GF-008 PASS evidence
and unchanged GF-008 source were not presented as a current PASS.

## Web Target Contract

- Target: `web`
- Godot: `4.7.2.stable.official.ed1daf0bf`
- Renderer: `gl_compatibility` for desktop and mobile
- Threading: single-threaded; `variant/thread_support=false`
- Template: `web_nothreads_release.zip`
- Extensions: `variant/extensions_support=false`; `.gdextension` and native
  shared-library resources are rejected
- Other rejection conditions: missing template/preset, non-Web platform,
  incompatible renderer, unsafe output, source mutation, or invalid bundle

## Doctor

Doctor reports Godot installation/version, Linux templates, and Web export
templates separately. Result: **31 critical PASS, 0 FAIL**. Web capability:
**PASS**.

## Real Export

- Fixture: `fixtures/web-export-project`
- Preset: `Game Foundry Web`
- Command: `godot --headless --path <fixture> --export-release 'Game Foundry Web' <artifact>/web/index.html`
- Duration: `2.610451` seconds for export 1
- Exit: `0`
- Output: `artifacts/gf-web-001/gf-web-001-acceptance-20260830T203254Z/export-1/web`

## Bundle

- Entrypoint: `index.html`
- Files: `9`
- Total: `39,852,163` bytes
- Largest: `index.wasm` (`39,514,754` bytes)
- WASM: `index.wasm`
- JavaScript: `index.js`, `index.audio.worklet.js`,
  `index.audio.position.worklet.js`
- Game data: `index.pck`

## Integrity

- Manifest: `export-1/web-release.json`
- Hash: SHA-256 for every final bundle file
- Verification: **PASS**
- Tamper test: **PASS** (corruption rejected)
- Traversal/path-safety test: **PASS**
- Missing HTML/WASM tests: **PASS**

## Repeatability

- Deterministic iterations: `20`
- PASS: `20`
- FAIL: `0`
- Genuine Godot invocations: `3` (two clean accepted exports and one
  controlled source-mutation export)
- Clean accepted exports: `2`
- Bundle outputs: byte-identical
- Nondeterministic bundle files: none observed
- Manifest `created_at` is intentionally excluded from bundle-byte comparison

## Negative Tests

| Test | Result |
|---|---|
| Missing Web templates (doctor and exporter) | PASS |
| Incompatible renderer | PASS |
| Threaded profile | PASS |
| Unsupported native extension | PASS |
| Missing entrypoint | PASS |
| Missing WASM | PASS |
| Hash tamper | PASS |
| Unsafe manifest path | PASS |
| Unexpected source mutation | PASS |

## Regression

| Suite | Current result |
|---|---|
| Doctor | PASS |
| GF-004 | PASS |
| GF-005 | PASS |
| GF-H02 | PASS |
| GF-H03 | PASS |
| GF-009 | PASS |
| GF-WEB-001 | PASS (20/20 Web acceptance) |
| GF-008 | **NOT RERUN — required API key unavailable** |

The latest source-controlled GF-008 evidence is PASS and no GF-008 source was
changed, but neither fact is represented as a current run.

## Critic

- Model: `gpt-5.6-sol`
- Mode: separate ephemeral Codex invocation with read-only sandbox and strict
  critic response schema
- Decision: **BLOCK**
- Blockers: `1`
- Warnings: `0`
- Observations: `2`
- Read-only proof: source status unchanged
- Blocker: current GF-008 regression evidence is mandatory and absent

The critic found no Web implementation, integrity, path safety, mutation, or
scope defect.

## Evidence

- Doctor JSON: `artifacts/gf-web-001/gf-web-001-acceptance-20260830T203254Z/doctor.json`
- Real export command/logs: `artifacts/gf-web-001/gf-web-001-acceptance-20260830T203254Z/export-1/logs/`
- Bundle: `artifacts/gf-web-001/gf-web-001-acceptance-20260830T203254Z/export-1/web/`
- Manifest: `artifacts/gf-web-001/gf-web-001-acceptance-20260830T203254Z/export-1/web-release.json`
- Verification: `artifacts/gf-web-001/gf-web-001-acceptance-20260830T203254Z/export-1/verification.json`
- Negative evidence: `artifacts/gf-web-001/gf-web-001-acceptance-20260830T203254Z/negative/` and `iterations/`
- Acceptance: `artifacts/gf-web-001/gf-web-001-acceptance-20260830T203254Z/evidence-summary.json`
- Regression: `artifacts/gf-web-001/gf-web-001-acceptance-20260830T203254Z/regression/regression-summary.json`
- Critic: `artifacts/gf-web-001/gf-web-001-acceptance-20260830T203254Z/critic-final/`

## Explicit Boundaries

**BROWSER RUNTIME ACCEPTANCE = NOT TESTED**

**ASTRO SITE INTEGRATION = NOT IMPLEMENTED**

**CLOUDFLARE DEPLOYMENT = NOT IMPLEMENTED**

## Human Gate

**HUMAN GF-WEB-001 APPROVAL = APPROVED**

Approval was provided by the human authority on 2026-08-30. This records the
human gate decision. The project owner subsequently directed commit and merge
with the outstanding GF-008 regression and critic blocker explicitly
acknowledged. The deterministic evidence above remains unchanged and is not
represented as PASS.

## Recommendation

1. Game Foundry now produces a structurally valid, integrity-verified Godot
   Web release bundle according to the deterministic GF-WEB-001 checks.
2. Clear the GF-008 and critic gate before starting GF-WEB-002. After that,
   GF-WEB-002 — Browser Runtime Acceptance is the correct next slice.
3. GF-WEB-002 should serve `.wasm` as `application/wasm`, preserve the
   no-threads profile without cross-origin-isolation requirements, and account
   for the observed `39,514,754`-byte engine WASM payload. It must independently
   prove boot, console cleanliness, rendering, input, runtime markers, and
   viewport behavior.
