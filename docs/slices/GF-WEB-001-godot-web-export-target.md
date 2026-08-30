# GF-WEB-001 — Godot Web export target

GF-WEB-001 adds `web` as a runtime target in the existing Game Foundry
execution plane. It does not create a second task runner or a hosting target.
Cloudflare Pages remains a future deployment profile rather than an engine
runtime name.

## Initial Web contract

The profile requires Godot 4.x Standard, GDScript-compatible source, the
Compatibility renderer (`gl_compatibility` for desktop and mobile), installed
`web_nothreads_release.zip` export templates, and a Godot Web preset with
`variant/thread_support=false` and `variant/extensions_support=false`. The
no-threads template is intentional: an initial release must not require
cross-origin isolation headers to boot. Projects containing `.gdextension` or
native `.so`, `.dll`, or `.dylib` resources fail preflight rather than being
rewritten or converted.

The accepted profile is static and client-side. The fixture contains no
networking, remote assets, audio dependency, analytics, native extension, or
server-side game logic.

## Workstation prerequisite

`./scripts/doctor.sh` and `./scripts/doctor.sh --json` report Godot itself,
the exact Godot version, Linux templates, and the single-threaded Web template
as distinct critical checks. Detection never downloads or installs templates.

## Export and release artifact

Run a release export with:

```bash
./scripts/gf-web-export.sh --fixture-id web-export-fixture \
  --artifact-dir artifacts/gf-web-001/<run-id>/export-1 \
  fixtures/web-export-project artifacts/gf-web-001/<run-id>/export-1/web
```

The helper validates the project and preset, fingerprints source before and
after Godot execution, records the command/version/template/stdout/stderr/exit
code/duration, exports `index.html`, inventories the emitted bundle, creates
`web-release.json`, and invokes the independent bundle verifier. Expected
Godot cache changes beneath `.godot/` follow existing generated-metadata policy
and are excluded from the source fingerprint; every other source change fails
closed.

`web-release.json` records the target, engine, renderer, threading policy,
source identity, export preset, entrypoint, total and largest sizes, and each
file's size, SHA-256, role, and safely inferred content type. The verifier
rejects malformed manifests, unsafe or escaping paths, symlinks, missing or
unmanifested files, size/hash changes, missing HTML/WASM/JavaScript/game data,
missing local HTML references, external HTML dependencies, or a threaded
entrypoint. Optional size ceilings are verifier policy inputs and are not tied
to a hosting provider.

## Meaning of PASS

PASS means the installed Godot produced a structurally complete,
self-contained, single-threaded static Web bundle whose final bytes match a
safe machine-readable manifest. It also means unexpected source mutation and
controlled corruption cases failed closed.

PASS does not prove that the release boots, renders, accepts input, or behaves
correctly in any browser. **Browser runtime acceptance is not tested.**
GF-WEB-002 owns HTTP serving and browser execution. GF-WEB-003 owns Astro/site
integration, hosting-profile limits, routes, and deployment. Neither is
implemented by this slice.
