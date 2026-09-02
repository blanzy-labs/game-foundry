# GF-WEB-003 — Cloudflare hosting contract

GF-WEB-003 separates the existing `web` runtime target from its hosting
profile. It packages a GF-WEB-001-verified and GF-WEB-002-proven bundle for a
future Cloudflare Pages consumer without changing either production site or
performing a deployment.

## Provider profile and decision

`config/hosting/cloudflare-pages.json` is the versioned provider policy. On
2026-08-30 the official Cloudflare Pages limits page still specified a maximum
individual site asset of 25 MiB (26,214,400 bytes), a 20,000-file Free-plan
limit, and R2/public custom domains as the option for larger files:

https://developers.cloudflare.com/pages/platform/limits/

The canonical fixture's `index.wasm` is 39,514,754 bytes, so Pages-only is
incompatible. The selected profile is `cloudflare-pages-r2`. The classifier
checks every bundle file and will make the same decision for any oversized
PCK, video, audio, texture, or other release asset.

## Commands

Classify a verified Web manifest:

```text
./scripts/gf-web-hosting-classify.sh <web-release.json>
```

Create a route-portable hosting release:

```text
./scripts/gf-web-hosting-package.sh \
  --slug <slug> \
  --route /games/<slug>/ \
  <web-release.json> <web-bundle> <hosting-release>
```

Verify and finalize it:

```text
./scripts/gf-web-hosting-verify.sh <hosting-release>
./scripts/gf-web-hosting-finalize.sh \
  --site-origin https://site.example.com \
  --asset-origin https://game-assets.example.com \
  <hosting-release> <finalized-release>
```

Finalization accepts only an HTTP(S) origin without path/query/fragment and
replaces one exact, manifested placeholder in the generated Godot HTML. It
does not use a hidden deployment-time `sed` command or alter generated
JavaScript. Source, placeholder, and finalized hashes are recorded.

## Package contract

The release contains `hosting-manifest.json`, the embedded
`source-web-release.json`, `classification.json`, `pages/`, and `r2/`.
Pages deployment paths are rooted at `games/<slug>/`. R2 paths are immutable
and versioned as `assets/<slug>/<source-manifest-hash-prefix>/`.

For the current Godot output, Pages receives HTML, the primary loader JS, and
icons. R2 receives WASM, PCK, side WASM if present, and generated audio
worklets because Godot derives all of those URLs from the configured
executable base. Every file above the Pages ceiling is always assigned to R2.
Moved files retain their bytes and source hashes.

The hosting manifest records the SHA-256 of the checked-in provider profile,
and verification binds the provider, profile version, limits, verification
date, and source reference back to that trusted configuration. The
authoritative verifier always loads that exact checked-in path and ignores
ambient profile overrides, so a release cannot raise its own Pages limit. The
manifest also records package placement, deployment path, MIME,
cache-policy class, hashes, source provenance, transformations, provider
constraints, and the required CORS/header contract. HTML is revalidation
friendly. Versioned R2 objects use the recommended
`public, max-age=31536000, immutable` policy. These are requirements for a
future release consumer; this slice does not configure Cloudflare caching.

## Asset origin and CORS

The asset origin is configurable and is never baked into game source. A
split release requires explicit GET/HEAD access for the exact site origin;
wildcard CORS is forbidden by the verifier. Local acceptance uses two dynamic
loopback origins and requires the WASM response to contain the site origin in
`Access-Control-Allow-Origin`.

For a finalized release, the verifier also requires the explicit allowed CORS
origin to equal the finalized `local_site_origin`; a different but otherwise
valid origin fails verification.

Cloudflare documents that a public R2 bucket accessed through a custom domain
returns CORS response headers when its bucket CORS policy permits the request:

https://developers.cloudflare.com/r2/buckets/cors/

A same-origin Worker/Pages Functions proxy was not needed: real Chromium
successfully loaded the large WASM and PCK directly from the second origin
with explicit CORS.

## Local production simulation and preview

The existing GF-WEB-002 Playwright harness now accepts a conforming hosting
release. It starts a Pages-like server and, for split releases, an R2-like
asset server. Both bind `127.0.0.1`, serve declared MIME/cache/CORS behavior,
and close with the browser on success or failure.

The Pages-only path is also executed through that same Chromium harness with
a small synthetic runtime package. It proves single-origin package serving,
WASM MIME, manifest asset requests, rendering/input assertions, and cleanup;
it is not presented as a second Godot engine proof. The canonical Pages+R2
path uses the real exported Godot fixture.

For a human preview:

```text
./scripts/gf-web-local-preview.sh <hosting-release>
```

The command verifies the release, allocates loopback ports, finalizes a
temporary Pages package against those origins, prints the game and asset URLs,
and remains active until Ctrl-C. It supports both Pages-only and Pages+R2
profiles and contains no fixture or game name.

## Verification and failure policy

The verifier revalidates the embedded source manifest's GF-WEB-001 schema,
runtime fields, complete inventory, required roles, original bytes, entrypoint
references, and identity binding. It rejects symlinks at the release root,
metadata files, package roots, nested package paths, and provenance paths.

The verifier fails closed for missing R2 files, unmanifested or leaked Pages
files, package mismatch, hash/size changes, unsafe paths, duplicate deployment
paths, invalid transformation state, incomplete CORS, wildcard origins,
invalid origins, source-provenance mismatch, provider-profile drift, per-file
MIME/cache-policy drift, and Pages limits. Browser faults
prove wrong asset origin, missing/wrong CORS, incorrect WASM MIME, and
post-launch dual-server cleanup.

## Future consumer responsibilities

A future Astro integration receives only `pages/` under its public
`games/<slug>/` route. A release/deployment system must publish `r2/` at the
manifested versioned prefix, configure its custom-domain MIME/cache/CORS
behavior, finalize the Pages package for the chosen site and asset origins,
publish Pages, and rerun browser acceptance after deployment.

No Cloudflare token, Wrangler login, R2 bucket, DNS record, production route,
or remote upload is required or created here.

**LOCAL PRODUCTION-LIKE HOSTING SIMULATION = TESTED**

**MYTHADIS SITE INTEGRATION = NOT IMPLEMENTED**

**RCBLANZY SITE INTEGRATION = NOT IMPLEMENTED**

**REMOTE R2 UPLOAD = NOT IMPLEMENTED**

**CLOUDFLARE DEPLOYMENT = NOT IMPLEMENTED**
