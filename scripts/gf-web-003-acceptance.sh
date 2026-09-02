#!/usr/bin/env bash
set -u -o pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
artifact_root=${GF_WEB003_ARTIFACT_ROOT:-$repo_root/artifacts/gf-web-003/gf-web-003-acceptance-$(date -u +%Y%m%dT%H%M%SZ)-$$}
healthy_runs=1
iterations=1
while (($#)); do
  case "$1" in
    --healthy-runs) healthy_runs=${2:?--healthy-runs requires a value}; shift 2 ;;
    --iterations) iterations=${2:?--iterations requires a value}; shift 2 ;;
    --artifact-root) artifact_root=${2:?--artifact-root requires a value}; shift 2 ;;
    *) printf 'usage: %s [--healthy-runs N] [--iterations N] [--artifact-root PATH]\n' "$0" >&2; exit 2 ;;
  esac
done
[[ $healthy_runs =~ ^[1-9][0-9]*$ && $iterations =~ ^[1-9][0-9]*$ ]] || { printf 'run counts must be positive\n' >&2; exit 2; }

profile="$repo_root/config/hosting/cloudflare-pages.json"
fixture="$repo_root/fixtures/web-export-project"
started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
start_ns=$(date +%s%N)
checks='[]'; failures=0; healthy_pass=0; deterministic_pass=0; negative_pass=0
mkdir -p "$artifact_root/healthy" "$artifact_root/negative" "$artifact_root/deterministic" "$artifact_root/logs"
temp_root=$(mktemp -d "$artifact_root/.tmp.XXXXXX")
cleanup() { find "$temp_root" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT

record() {
  local group=$1 name=$2 status=$3 detail=${4:-}
  checks=$(jq --arg group "$group" --arg name "$name" --arg status "$status" --arg detail "$detail" '.+[{group:$group,name:$name,status:$status,detail:(if $detail=="" then null else $detail end)}]' <<<"$checks")
  printf '%-15s %-36s %s\n' "$group" "$name" "${status^^}"
  [[ $status == pass ]] || failures=$((failures+1))
}

"$repo_root/scripts/doctor.sh" --json >"$artifact_root/doctor.json" 2>"$artifact_root/doctor.stderr"
code=$?
if [[ $code -eq 0 ]] && jq -e '.status=="ready" and .tools.browser_runtime.status=="pass" and .tools.godot.web_export.status=="pass"' "$artifact_root/doctor.json" >/dev/null; then record preflight doctor pass; else record preflight doctor fail "exit=$code"; fi

source_release="$artifact_root/gf-web-001-release"
"$repo_root/scripts/gf-web-export.sh" --fixture-id web-export-fixture --artifact-dir "$source_release" "$fixture" "$source_release/web" >"$artifact_root/export.json" 2>"$artifact_root/export.stderr"
code=$?
if [[ $code -eq 0 ]] && jq -e '.status=="pass" and .verification.status=="pass"' "$source_release/export-result.json" >/dev/null; then record preflight gf_web_001 pass; else record preflight gf_web_001 fail "exit=$code"; fi
source_manifest="$source_release/web-release.json"; source_bundle="$source_release/web"

"$repo_root/scripts/gf-web-hosting-classify.sh" "$source_manifest" >"$artifact_root/classification.json"
code=$?
if [[ $code -eq 0 ]] && jq -e '.compatible==false and .reason=="individual_file_limit" and .largest_file_bytes>.max_file_bytes and .recommended_profile=="cloudflare-pages-r2"' "$artifact_root/classification.json" >/dev/null; then record provider pages_oversize_classification pass; else record provider pages_oversize_classification fail "exit=$code"; fi

set +e
"$repo_root/scripts/gf-web-hosting-package.sh" --hosting-profile cloudflare-pages --slug web-fixture --route /games/web-fixture/ "$source_manifest" "$source_bundle" "$artifact_root/pages-only-rejected" >"$artifact_root/negative/pages-oversize.json" 2>"$artifact_root/negative/pages-oversize.stderr"
code=$?
set -e
if [[ $code -ne 0 ]] && jq -e '.status=="fail" and (.error|contains("Pages-only rejected"))' "$artifact_root/negative/pages-oversize.json" >/dev/null; then negative_pass=$((negative_pass+1)); record negative pages_oversize_rejected pass; else record negative pages_oversize_rejected fail "exit=$code"; fi

hosting_release="$artifact_root/release"
"$repo_root/scripts/gf-web-hosting-package.sh" --slug web-fixture --route /games/web-fixture/ "$source_manifest" "$source_bundle" "$hosting_release" >"$artifact_root/package-result.json" 2>"$artifact_root/package.stderr"
code=$?
if [[ $code -eq 0 ]] && jq -e '.status=="pass" and .hosting_profile=="cloudflare-pages-r2"' "$artifact_root/package-result.json" >/dev/null; then record package split_release pass; else record package split_release fail "exit=$code"; fi
cp "$hosting_release/hosting-manifest.json" "$artifact_root/hosting-manifest.json"
"$repo_root/scripts/gf-web-hosting-verify.sh" "$hosting_release" >"$artifact_root/hosting-verification.json"
code=$?
if [[ $code -eq 0 ]] && jq -e '.status=="pass" and .pages_file_count>0 and .r2_file_count>0' "$artifact_root/hosting-verification.json" >/dev/null; then record package hosting_verification pass; else record package hosting_verification fail "exit=$code"; fi

for ((run=1; run<=healthy_runs; run++)); do
  run_dir="$artifact_root/healthy/run-$(printf '%02d' "$run")"
  "$repo_root/scripts/gf-web-browser-test.sh" --hosting-release "$hosting_release" "$run_dir" >"$run_dir.console.json" 2>"$run_dir.console.stderr"
  code=$?
  if [[ $code -eq 0 ]] && jq -e '.status=="pass" and .hosting_profile=="cloudflare-pages-r2" and .runtime_ready==true and .rendering.nonempty==true and .rendering.changed_after_input==true and .keyboard_test.passed==true and .wasm_status.status==200 and .wasm_status.content_type=="application/wasm" and .wasm_status.origin==.asset_url and .wasm_status.origin!=.site_url and .cors.passed==true and .console_error_count==0 and .page_error_count==0 and .cleanup.browser_closed==true and .cleanup.site_server_closed==true and .cleanup.asset_server_closed==true' "$run_dir/browser-result.json" >/dev/null; then
    healthy_pass=$((healthy_pass+1)); record healthy "split_chromium_$(printf '%02d' "$run")" pass
  else record healthy "split_chromium_$(printf '%02d' "$run")" fail "exit=$code"; fi
done

package_fault() {
  local name=$1 mode=$2 target wasm first second code case_dir omitted omitted_deployment entry entry_deployment entry_size entry_hash source_rel
  case_dir="$artifact_root/negative/$name"
  cp -a --reflink=auto "$hosting_release" "$case_dir"
  wasm=$(jq -r '.files[]|select(.content_role=="wasm")|.deployment_path' "$case_dir/hosting-manifest.json")
  case "$mode" in
    missing_r2) find "$case_dir/r2" -type f -path "*/index.wasm" -delete ;;
    leaked_pages) mkdir -p "$case_dir/pages/$(dirname "$wasm")"; cp --reflink=auto "$case_dir/r2/$wasm" "$case_dir/pages/$wasm" ;;
    package_mismatch) mkdir -p "$case_dir/pages/$(dirname "$wasm")"; mv "$case_dir/r2/$wasm" "$case_dir/pages/$wasm" ;;
    hash_tamper) target="$case_dir/r2/$wasm"; cp --reflink=auto "$target" "$case_dir/tampered"; printf 'CONTROLLED_TAMPER\n' >>"$case_dir/tampered"; mv "$case_dir/tampered" "$target" ;;
    unsafe_path) jq '(.files[0].deployment_path)="../escape"' "$case_dir/hosting-manifest.json" >"$case_dir/manifest.tmp"; mv "$case_dir/manifest.tmp" "$case_dir/hosting-manifest.json" ;;
    duplicate_path) first=$(jq -r '.files[0].deployment_path' "$case_dir/hosting-manifest.json"); jq --arg first "$first" '(.files[1].deployment_path)=$first' "$case_dir/hosting-manifest.json" >"$case_dir/manifest.tmp"; mv "$case_dir/manifest.tmp" "$case_dir/hosting-manifest.json" ;;
    source_omission)
      omitted=$(jq -r '.files[]|select(.content_role=="icon")|.original_path' "$case_dir/hosting-manifest.json" | head -1)
      omitted_deployment=$(jq -r --arg omitted "$omitted" '.files[]|select(.original_path==$omitted)|.deployment_path' "$case_dir/hosting-manifest.json")
      find "$case_dir/pages" -type f -path "*/$omitted" -delete
      jq --arg omitted "$omitted" '.files|=map(select(.original_path!=$omitted))' "$case_dir/hosting-manifest.json" >"$case_dir/manifest.tmp"; mv "$case_dir/manifest.tmp" "$case_dir/hosting-manifest.json"
      ;;
    missing_transformation)
      source_rel=$(jq -r '.source_web_manifest' "$case_dir/hosting-manifest.json")
      entry=$(jq -r .entrypoint "$case_dir/$source_rel")
      entry_deployment=$(jq -r --arg entry "$entry" '.files[]|select(.original_path==$entry)|.deployment_path' "$case_dir/hosting-manifest.json")
      cp "$case_dir/provenance/$entry" "$case_dir/pages/$entry_deployment"
      entry_size=$(stat -c %s "$case_dir/pages/$entry_deployment")
      entry_hash=$(sha256sum "$case_dir/pages/$entry_deployment" | cut -d' ' -f1)
      jq --arg entry "$entry" --arg hash "$entry_hash" --argjson size "$entry_size" '(.files[]|select(.original_path==$entry))|=(.sha256=$hash|.size_bytes=$size|.transformed=false) | .transformations=[]' "$case_dir/hosting-manifest.json" >"$case_dir/manifest.tmp"; mv "$case_dir/manifest.tmp" "$case_dir/hosting-manifest.json"
      ;;
    incomplete_cors) jq '.cors.allowed_methods=["GET"] | del(.required_headers.wasm_content_type)' "$case_dir/hosting-manifest.json" >"$case_dir/manifest.tmp"; mv "$case_dir/manifest.tmp" "$case_dir/hosting-manifest.json" ;;
    source_manifest_escape) jq '.source_web_manifest="../external-web-release.json"' "$case_dir/hosting-manifest.json" >"$case_dir/manifest.tmp"; mv "$case_dir/manifest.tmp" "$case_dir/hosting-manifest.json" ;;
    entrypoint_deployment_mismatch) jq '.entrypoint_deployment_path="games/web-fixture/not-index.html"' "$case_dir/hosting-manifest.json" >"$case_dir/manifest.tmp"; mv "$case_dir/manifest.tmp" "$case_dir/hosting-manifest.json" ;;
    placeholder_hash_mismatch) jq '(.transformations[0].output_sha256)="0000000000000000000000000000000000000000000000000000000000000000"' "$case_dir/hosting-manifest.json" >"$case_dir/manifest.tmp"; mv "$case_dir/manifest.tmp" "$case_dir/hosting-manifest.json" ;;
    inflated_pages_profile)
      python3 - "$case_dir" <<'PY'
import hashlib
import json
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1])
path = root / "hosting-manifest.json"
manifest = json.loads(path.read_text())
route = manifest["site_route"].strip("/")
for item in manifest["files"]:
    old = root / item["package"] / item["deployment_path"]
    new_relative = f"{route}/{item['original_path']}"
    new = root / "pages" / new_relative
    new.parent.mkdir(parents=True, exist_ok=True)
    if item["transformed"]:
        shutil.copyfile(root / "provenance" / item["original_path"], new)
    elif old != new:
        shutil.move(old, new)
    item.update({
        "deployment_path": new_relative,
        "package": "pages",
        "size_bytes": new.stat().st_size,
        "sha256": hashlib.sha256(new.read_bytes()).hexdigest(),
        "transformed": False,
        "cache_policy_class": "revalidate" if item["original_path"].endswith(".html") else "versioned-site-asset",
    })
manifest["hosting_profile"] = "cloudflare-pages"
manifest["entrypoint_deployment_path"] = f"{route}/{json.loads((root / 'source-web-release.json').read_text())['entrypoint']}"
manifest["asset_package"] = None
manifest["asset_origin"] = {"mode": "same_origin", "placeholder": None, "value": None, "asset_prefix": None}
manifest["cross_origin_required"] = False
manifest["cors"] = {"required": False, "allowed_origins": [], "allowed_methods": [], "response_header": None, "wildcard_forbidden": True}
manifest["transformations"] = []
manifest["pages_constraints"]["max_file_bytes"] = 50_000_000
shutil.rmtree(root / "r2", ignore_errors=True)
(root / "r2").mkdir()
shutil.rmtree(root / "provenance", ignore_errors=True)
(root / "provenance").mkdir()
path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
      ;;
    mime_contract) jq '(.files[]|select(.original_path|endswith(".png"))|.mime)="application/octet-stream"' "$case_dir/hosting-manifest.json" >"$case_dir/manifest.tmp"; mv "$case_dir/manifest.tmp" "$case_dir/hosting-manifest.json" ;;
    cache_contract) jq '(.files[]|select(.original_path|endswith(".js"))|.cache_policy_class)="revalidate"' "$case_dir/hosting-manifest.json" >"$case_dir/manifest.tmp"; mv "$case_dir/manifest.tmp" "$case_dir/hosting-manifest.json" ;;
    invalid_source_manifest)
      jq '.schema_version="invalid"' "$case_dir/source-web-release.json" >"$case_dir/source.tmp"; mv "$case_dir/source.tmp" "$case_dir/source-web-release.json"
      source_hash=$(sha256sum "$case_dir/source-web-release.json" | cut -d' ' -f1)
      jq --arg hash "$source_hash" '.source_web_manifest_sha256=$hash' "$case_dir/hosting-manifest.json" >"$case_dir/manifest.tmp"; mv "$case_dir/manifest.tmp" "$case_dir/hosting-manifest.json"
      ;;
    source_role_mismatch) jq '(.files[]|select(.content_role=="wasm")|.content_role)="other"' "$case_dir/hosting-manifest.json" >"$case_dir/manifest.tmp"; mv "$case_dir/manifest.tmp" "$case_dir/hosting-manifest.json" ;;
    hosting_identity_mismatch) jq '.fixture_id="different-fixture"' "$case_dir/hosting-manifest.json" >"$case_dir/manifest.tmp"; mv "$case_dir/manifest.tmp" "$case_dir/hosting-manifest.json" ;;
  esac
  set +e; "$repo_root/scripts/gf-web-hosting-verify.sh" "$case_dir" >"$case_dir.result.json"; code=$?; set -e
  if [[ $code -ne 0 ]] && jq -e '.status=="fail" and (.errors|length)>0' "$case_dir.result.json" >/dev/null; then negative_pass=$((negative_pass+1)); record negative "$name" pass; else record negative "$name" fail "exit=$code"; fi
}

package_fault missing_r2_asset missing_r2
package_fault large_asset_leaked_pages leaked_pages
package_fault manifest_package_mismatch package_mismatch
package_fault hash_tamper hash_tamper
package_fault unsafe_path unsafe_path
package_fault duplicate_deployment_path duplicate_path
package_fault source_asset_omission source_omission
package_fault missing_entrypoint_transformation missing_transformation
package_fault incomplete_cors_header_contract incomplete_cors
package_fault external_source_manifest_path source_manifest_escape
package_fault entrypoint_deployment_mismatch entrypoint_deployment_mismatch
package_fault placeholder_transformation_hash_mismatch placeholder_hash_mismatch
package_fault inflated_self_declared_pages_limit inflated_pages_profile
package_fault non_wasm_mime_contract mime_contract
package_fault per_file_cache_contract cache_contract
package_fault invalid_embedded_gf_web_001_manifest invalid_source_manifest
package_fault source_content_role_mismatch source_role_mismatch
package_fault hosting_source_identity_mismatch hosting_identity_mismatch

forged_profile="$temp_root/forged-cloudflare-pages.json"
jq '.max_file_bytes=50000000' "$profile" >"$forged_profile"
forged_profile_hash=$(sha256sum "$forged_profile" | cut -d' ' -f1)
forged_release="$artifact_root/negative/ambient-profile-forged-release"
"$repo_root/scripts/gf-web-hosting-package.sh" --profile "$forged_profile" --hosting-profile cloudflare-pages --slug web-fixture --route /games/web-fixture/ "$source_manifest" "$source_bundle" "$forged_release" >"$artifact_root/negative/profile-override-package.json" 2>"$artifact_root/negative/profile-override-package.stderr"
forged_package_code=$?
set +e
GF_WEB_HOSTING_PROFILE_CONFIG="$forged_profile" "$repo_root/scripts/gf-web-hosting-verify.sh" "$forged_release" >"$artifact_root/negative/profile-override.result.json"
code=$?
set -e
if [[ $forged_package_code -eq 0 && $code -ne 0 ]] \
  && jq -e --arg hash "$forged_profile_hash" '.hosting_profile=="cloudflare-pages" and .provider_profile_sha256==$hash and .pages_constraints.max_file_bytes==50000000 and ([.files[]|select(.content_role=="wasm" and .package=="pages" and .size_bytes==39514754)]|length)==1' "$forged_release/hosting-manifest.json" >/dev/null \
  && jq -e '.status=="fail" and (.errors|index("hosting manifest is not bound to the trusted provider profile"))!=null and ([.errors[]|select(contains("Pages file exceeds individual limit"))]|length)>0' "$artifact_root/negative/profile-override.result.json" >/dev/null; then
  negative_pass=$((negative_pass+1)); record negative ambient_profile_override_rejected pass
else
  record negative ambient_profile_override_rejected fail "package=$forged_package_code verify=$code"
fi

symlink_fault() {
  local name=$1 mode=$2 case_dir target code
  case_dir="$artifact_root/negative/$name"
  target="$artifact_root/negative/.symlink-target-$name"
  case "$mode" in
    release_root) ln -s "$hosting_release" "$case_dir" ;;
    hosting_manifest)
      cp -a --reflink=auto "$hosting_release" "$case_dir"
      mv "$case_dir/hosting-manifest.json" "$target"
      ln -s "$target" "$case_dir/hosting-manifest.json"
      ;;
    source_manifest)
      cp -a --reflink=auto "$hosting_release" "$case_dir"
      mv "$case_dir/source-web-release.json" "$target"
      ln -s "$target" "$case_dir/source-web-release.json"
      ;;
    package_root)
      cp -a --reflink=auto "$hosting_release" "$case_dir"
      mv "$case_dir/pages" "$target"
      ln -s "$target" "$case_dir/pages"
      ;;
    nested_package)
      cp -a --reflink=auto "$hosting_release" "$case_dir"
      mv "$case_dir/pages/games" "$target"
      ln -s "$target" "$case_dir/pages/games"
      ;;
  esac
  set +e; "$repo_root/scripts/gf-web-hosting-verify.sh" "$case_dir" >"$artifact_root/negative/$name.result.json"; code=$?; set -e
  if [[ $code -ne 0 ]] && jq -e '.status=="fail" and (.errors|length)>0' "$artifact_root/negative/$name.result.json" >/dev/null; then negative_pass=$((negative_pass+1)); record negative "$name" pass; else record negative "$name" fail "exit=$code"; fi
}
symlink_fault release_root_symlink release_root
symlink_fault hosting_manifest_symlink hosting_manifest
symlink_fault source_manifest_symlink source_manifest
symlink_fault package_root_symlink package_root
symlink_fault nested_package_symlink nested_package

browser_fault() {
  local name=$1 fault=$2 code case_dir
  case_dir="$artifact_root/negative/$name"
  set +e
  "$repo_root/scripts/gf-web-browser-test.sh" --hosting-release "$hosting_release" --fault "$fault" --startup-timeout-ms 1800 --input-timeout-ms 900 "$case_dir" >"$case_dir.console.json" 2>"$case_dir.console.stderr"
  code=$?
  set -e
  if [[ $code -ne 0 ]] && jq -e '.status=="fail" and .cleanup.browser_closed==true and .cleanup.site_server_closed==true and .cleanup.asset_server_closed==true' "$case_dir/browser-result.json" >/dev/null; then negative_pass=$((negative_pass+1)); record negative "$name" pass; else record negative "$name" fail "exit=$code"; fi
}

browser_fault wrong_asset_origin wrong_asset_origin
browser_fault missing_cors missing_cors
browser_fault wrong_cors_origin wrong_cors
browser_fault wrong_wasm_mime bad_mime
browser_fault dual_server_cleanup page_exception

malformed_origin_failures=0
malformed_index=0
for malformed_origin in 'https://assets.example.com?' 'https://assets.example.com#' 'http://assets.example.com:'; do
  malformed_index=$((malformed_index+1))
  set +e
  "$repo_root/scripts/gf-web-hosting-finalize.sh" --site-origin http://127.0.0.1:4100 --asset-origin "$malformed_origin" "$hosting_release" "$temp_root/malformed-origin-$malformed_index" >"$artifact_root/negative/malformed-origin-$malformed_index.json" 2>"$artifact_root/negative/malformed-origin-$malformed_index.stderr"
  code=$?
  set -e
  [[ $code -ne 0 ]] && malformed_origin_failures=$((malformed_origin_failures+1))
done
if [[ $malformed_origin_failures -eq 3 ]]; then negative_pass=$((negative_pass+1)); record negative malformed_origin_finalization pass; else record negative malformed_origin_finalization fail "rejected=$malformed_origin_failures/3"; fi

baseline_final="$temp_root/repeatability-baseline-finalized"
"$repo_root/scripts/gf-web-hosting-finalize.sh" --site-origin http://127.0.0.1:4100 --asset-origin http://127.0.0.1:4200 "$hosting_release" "$baseline_final" >"$artifact_root/deterministic/baseline-finalize.json"
baseline_finalize_code=$?
baseline_template_hash=$(sha256sum "$hosting_release/hosting-manifest.json" | cut -d' ' -f1)
baseline_final_hash=$(sha256sum "$baseline_final/hosting-manifest.json" | cut -d' ' -f1)
fixed_origin_case="$artifact_root/negative/invalid_fixed_origin_manifest"
cp -a --reflink=auto "$baseline_final" "$fixed_origin_case"
jq '.asset_origin.value="http://assets.example.com:"' "$fixed_origin_case/hosting-manifest.json" >"$fixed_origin_case/manifest.tmp"; mv "$fixed_origin_case/manifest.tmp" "$fixed_origin_case/hosting-manifest.json"
set +e; "$repo_root/scripts/gf-web-hosting-verify.sh" "$fixed_origin_case" >"$fixed_origin_case.result.json"; code=$?; set -e
if [[ $code -ne 0 ]] && jq -e '.status=="fail" and (.errors|length)>0' "$fixed_origin_case.result.json" >/dev/null; then negative_pass=$((negative_pass+1)); record negative invalid_fixed_origin_manifest pass; else record negative invalid_fixed_origin_manifest fail "exit=$code"; fi

finalized_fault() {
  local name=$1 filter=$2 case_dir code
  case_dir="$artifact_root/negative/$name"
  cp -a --reflink=auto "$baseline_final" "$case_dir"
  jq "$filter" "$case_dir/hosting-manifest.json" >"$case_dir/manifest.tmp"; mv "$case_dir/manifest.tmp" "$case_dir/hosting-manifest.json"
  set +e; "$repo_root/scripts/gf-web-hosting-verify.sh" "$case_dir" >"$case_dir.result.json"; code=$?; set -e
  if [[ $code -ne 0 ]] && jq -e '.status=="fail" and (.errors|length)>0' "$case_dir.result.json" >/dev/null; then negative_pass=$((negative_pass+1)); record negative "$name" pass; else record negative "$name" fail "exit=$code"; fi
}
finalized_fault finalized_cors_site_origin_mismatch '.cors.allowed_origins=["http://127.0.0.1:4300"]'
finalized_fault invalid_runtime_target '.runtime_target="native"'
finalized_fault invalid_site_package '.site_package="r2"'
finalized_fault invalid_asset_package '.asset_package="pages"'
for ((iteration=1; iteration<=iterations; iteration++)); do
  iteration_dir="$artifact_root/deterministic/$(printf '%02d' "$iteration")"
  mkdir -p "$iteration_dir"
  iteration_release="$temp_root/repeat-release-$(printf '%02d' "$iteration")"
  iteration_final="$temp_root/repeat-final-$(printf '%02d' "$iteration")"
  "$repo_root/scripts/gf-web-hosting-package.sh" --skip-compression-analysis --slug web-fixture --route /games/web-fixture/ "$source_manifest" "$source_bundle" "$iteration_release" >"$iteration_dir/package.json" 2>"$iteration_dir/package.stderr"
  package_code=$?
  "$repo_root/scripts/gf-web-hosting-verify.sh" "$iteration_release" >"$iteration_dir/verify.json"
  verify_code=$?
  "$repo_root/scripts/gf-web-hosting-finalize.sh" --site-origin http://127.0.0.1:4100 --asset-origin http://127.0.0.1:4200 "$iteration_release" "$iteration_final" >"$iteration_dir/finalize.json" 2>"$iteration_dir/finalize.stderr"
  finalize_code=$?
  "$repo_root/scripts/gf-web-hosting-verify.sh" "$iteration_final" >"$iteration_dir/final-verify.json"
  final_verify_code=$?
  template_hash=$(sha256sum "$iteration_release/hosting-manifest.json" | cut -d' ' -f1)
  final_hash=$(sha256sum "$iteration_final/hosting-manifest.json" | cut -d' ' -f1)
  cp "$iteration_release/hosting-manifest.json" "$iteration_dir/hosting-manifest.json"
  cp "$iteration_final/hosting-manifest.json" "$iteration_dir/finalized-hosting-manifest.json"
  jq -n --arg template "$template_hash" --arg expected_template "$baseline_template_hash" --arg final "$final_hash" --arg expected_final "$baseline_final_hash" '{template_manifest_sha256:$template,expected_template_manifest_sha256:$expected_template,finalized_manifest_sha256:$final,expected_finalized_manifest_sha256:$expected_final,identical:($template==$expected_template and $final==$expected_final)}' >"$iteration_dir/comparison.json"
  if [[ $baseline_finalize_code -eq 0 && $package_code -eq 0 && $verify_code -eq 0 && $finalize_code -eq 0 && $final_verify_code -eq 0 && $template_hash == "$baseline_template_hash" && $final_hash == "$baseline_final_hash" ]] && jq -e '.status=="pass"' "$iteration_dir/verify.json" "$iteration_dir/final-verify.json" >/dev/null; then
    deterministic_pass=$((deterministic_pass+1)); record deterministic "package_verify_$(printf '%02d' "$iteration")" pass
  else record deterministic "package_verify_$(printf '%02d' "$iteration")" fail "package=$package_code verify=$verify_code finalize=$finalize_code final_verify=$final_verify_code"; fi
  find "$iteration_release" "$iteration_final" -depth -delete 2>/dev/null || true
done

ready="$temp_root/preview-ready.json"
GF_WEB_PREVIEW_READY_FILE="$ready" "$repo_root/scripts/gf-web-local-preview.sh" "$hosting_release" >"$artifact_root/manual-preview.log" 2>"$artifact_root/manual-preview.stderr" &
preview_pid=$!
for _ in $(seq 1 150); do [[ -s $ready ]] && break; sleep 0.1; done
preview_ok=false
if [[ -s $ready ]]; then
  game_url=$(jq -r .game_url "$ready")
  site_origin=$(jq -r .site_origin "$ready")
  asset_origin=$(jq -r .asset_origin "$ready")
  wasm_path=$(jq -r '.files[]|select(.content_role=="wasm")|.deployment_path' "$hosting_release/hosting-manifest.json")
  if curl -fsS "$game_url" | grep -Fq 'GODOT_CONFIG' && curl -fsSI -H "Origin: $site_origin" "$asset_origin/$wasm_path" | grep -Fiq "Access-Control-Allow-Origin: $site_origin"; then preview_ok=true; fi
fi
kill -INT "$preview_pid" 2>/dev/null || true
wait "$preview_pid" 2>/dev/null; preview_code=$?
if $preview_ok && [[ $preview_code -eq 0 ]] && ! kill -0 "$preview_pid" 2>/dev/null; then record preview manual_preview_smoke pass; else record preview manual_preview_smoke fail "exit=$preview_code"; fi
cp "$ready" "$artifact_root/manual-preview-ready.json" 2>/dev/null || true

# A tiny synthetic runtime fixture proves the one-origin Pages-only packaging,
# manual-preview, and shared Chromium paths without pretending the real 39.5 MB
# Godot WASM fits.
small_bundle="$temp_root/pages-only-source"
mkdir -p "$small_bundle"
cat >"$small_bundle/index.html" <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;background:#18352b}canvas{display:block;width:min(100vw,1280px);height:auto}</style></head><body><canvas id="canvas" width="640" height="360" tabindex="0"></canvas><script>const GODOT_THREADS_ENABLED = false; const GODOT_CONFIG={"executable":"index","files":["index.wasm","index.pck"]};</script><script src="index.js"></script></body></html>
EOF
cat >"$small_bundle/index.js" <<'EOF'
(async () => {
  await Promise.all([
    WebAssembly.instantiateStreaming(fetch('index.wasm')),
    fetch('index.pck').then((response) => { if (!response.ok) throw new Error('PCK request failed'); return response.arrayBuffer(); }),
  ]);
  const canvas = document.getElementById('canvas');
  const context = canvas.getContext('2d');
  const draw = (active) => {
    context.fillStyle = active ? '#ca4f7d' : '#297a5b'; context.fillRect(0, 0, canvas.width, canvas.height);
    context.fillStyle = '#f7d154'; context.fillRect(active ? 220 : 80, 90, 180, 180);
  };
  window.GF_WEB_RUNTIME_STATE = 'IDLE';
  window.GF_WEB_MOUSE_RECEIVED = false;
  window.GF_WEB_KEYBOARD_RECEIVED = false;
  canvas.addEventListener('mousedown', () => { window.GF_WEB_MOUSE_RECEIVED = true; });
  window.addEventListener('keydown', (event) => {
    if (event.code === 'Space') {
      window.GF_WEB_KEYBOARD_RECEIVED = true;
      window.GF_WEB_RUNTIME_STATE = 'INPUT_RECEIVED';
      draw(true);
    }
  });
  draw(false);
  window.GF_WEB_RUNTIME_READY = true;
})();
EOF
printf '\x00asm\x01\x00\x00\x00' >"$small_bundle/index.wasm"
printf 'synthetic browser acceptance payload\n' >"$small_bundle/index.pck"
small_manifest="$temp_root/pages-only-web-release.json"
python3 "$repo_root/scripts/lib/gf-web.py" create-manifest "$small_manifest" "$small_bundle" --fixture-id pages-only-structural-fixture --godot-version structural-only --source-fingerprint structural-only >"$artifact_root/pages-only-source.json"
small_release="$artifact_root/pages-only-release"
"$repo_root/scripts/gf-web-hosting-package.sh" --hosting-profile cloudflare-pages --slug pages-only-smoke --route /games/pages-only-smoke/ "$small_manifest" "$small_bundle" "$small_release" >"$artifact_root/pages-only-package.json" 2>"$artifact_root/pages-only-package.stderr"
small_package_code=$?
small_ready="$temp_root/pages-only-ready.json"
GF_WEB_PREVIEW_READY_FILE="$small_ready" "$repo_root/scripts/gf-web-local-preview.sh" "$small_release" >"$artifact_root/pages-only-preview.log" 2>"$artifact_root/pages-only-preview.stderr" &
small_pid=$!
for _ in $(seq 1 100); do [[ -s $small_ready ]] && break; sleep 0.1; done
small_ok=false
if [[ -s $small_ready ]] && curl -fsS "$(jq -r .game_url "$small_ready")" | grep -Fq '<canvas id="canvas"' && [[ $(jq -r .asset_origin "$small_ready") == null ]]; then small_ok=true; fi
kill -INT "$small_pid" 2>/dev/null || true
wait "$small_pid" 2>/dev/null; small_preview_code=$?
if [[ $small_package_code -eq 0 && $small_preview_code -eq 0 ]] && $small_ok; then record preview pages_only_single_origin_smoke pass; else record preview pages_only_single_origin_smoke fail "package=$small_package_code preview=$small_preview_code"; fi
small_browser="$artifact_root/pages-only-browser"
"$repo_root/scripts/gf-web-browser-test.sh" --hosting-release "$small_release" "$small_browser" >"$small_browser.console.json" 2>"$small_browser.console.stderr"
small_browser_code=$?
if [[ $small_browser_code -eq 0 ]] && jq -e '.status=="pass" and .hosting_profile=="cloudflare-pages" and .runtime_ready==true and .rendering.nonempty==true and .rendering.changed_after_input==true and .keyboard_test.passed==true and .wasm_status.status==200 and .wasm_status.content_type=="application/wasm" and .wasm_status.origin==.site_url and .asset_url==null and .cors.required==false and .cleanup.browser_closed==true and .cleanup.site_server_closed==true and .cleanup.asset_server_closed==true' "$small_browser/browser-result.json" >/dev/null; then record preview pages_only_chromium pass; else record preview pages_only_chromium fail "exit=$small_browser_code"; fi

finished_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
duration=$(awk -v start="$start_ns" -v end="$(date +%s%N)" 'BEGIN{printf "%.6f",(end-start)/1000000000}')
status=pass; ((failures>0)) && status=fail
pages_count=$(jq '[.files[]|select(.package=="pages")]|length' "$hosting_release/hosting-manifest.json")
r2_count=$(jq '[.files[]|select(.package=="r2")]|length' "$hosting_release/hosting-manifest.json")
pages_bytes=$(jq '[.files[]|select(.package=="pages")|.size_bytes]|add//0' "$hosting_release/hosting-manifest.json")
r2_bytes=$(jq '[.files[]|select(.package=="r2")|.size_bytes]|add//0' "$hosting_release/hosting-manifest.json")
jq -n --arg status "$status" --arg started "$started_at" --arg finished "$finished_at" --arg artifact_root "$artifact_root" --arg source_manifest "$source_manifest" \
  --argjson duration "$duration" --argjson healthy_runs "$healthy_runs" --argjson healthy_pass "$healthy_pass" --argjson iterations "$iterations" --argjson deterministic_pass "$deterministic_pass" --argjson negative_pass "$negative_pass" --argjson failures "$failures" --argjson pages_count "$pages_count" --argjson r2_count "$r2_count" --argjson pages_bytes "$pages_bytes" --argjson r2_bytes "$r2_bytes" --argjson checks "$checks" \
  --slurpfile classification "$artifact_root/classification.json" --slurpfile hosting "$hosting_release/hosting-manifest.json" --slurpfile browser "$artifact_root/healthy/run-01/browser-result.json" \
  '{slice:"GF-WEB-003",status:$status,started_at:$started,finished_at:$finished,artifact_root:$artifact_root,duration_seconds:$duration,source_web_manifest:$source_manifest,source_web_manifest_sha256:$hosting[0].source_web_manifest_sha256,provider:$hosting[0].provider,canonical_hosting_profile:$hosting[0].hosting_profile,pages_limit_bytes:$classification[0].max_file_bytes,largest_source_file:$classification[0].largest_file,largest_source_file_bytes:$classification[0].largest_file_bytes,pages_file_count:$pages_count,pages_total_bytes:$pages_bytes,r2_file_count:$r2_count,r2_total_bytes:$r2_bytes,asset_origin_mode:$hosting[0].asset_origin.mode,cross_origin_required:$hosting[0].cross_origin_required,cors_required:$hosting[0].cors.required,local_site_url:$browser[0].site_url,local_asset_url:$browser[0].asset_url,browser_runtime_result:$browser[0],manual_preview_supported:true,repeatability:{real_split_browser:{runs:$healthy_runs,pass:$healthy_pass,fail:($healthy_runs-$healthy_pass)},deterministic_packaging:{runs:$iterations,pass:$deterministic_pass,fail:($iterations-$deterministic_pass)}},negative_tests:[$checks[]|select(.group=="negative")],failures:$failures,failure_reason:(if $failures==0 then null else "acceptance checks failed" end),checks:$checks,boundaries:{local_production_like_hosting_simulation:(if $status=="pass" then "pass" else "fail" end),mythadis_site_integration:"not_implemented",rcblanzy_site_integration:"not_implemented",remote_r2_upload:"not_implemented",cloudflare_deployment:"not_implemented"}}' >"$artifact_root/result.json"
printf 'GF-WEB-003 ACCEPTANCE: %s\nREAL SPLIT CHROMIUM: %s/%s\nDETERMINISTIC PACKAGE: %s/%s\nNEGATIVE PASS: %s\nFAILURES: %s\nEVIDENCE: %s\n' "${status^^}" "$healthy_pass" "$healthy_runs" "$deterministic_pass" "$iterations" "$negative_pass" "$failures" "$artifact_root"
((failures==0))
