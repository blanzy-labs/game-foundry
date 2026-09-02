#!/usr/bin/env python3
"""Deterministic Cloudflare hosting packaging for verified Game Foundry Web releases."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import html.parser
import json
import mimetypes
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
from typing import Any
from urllib.parse import urlparse


SCHEMA_VERSION = "1"
ASSET_TOKEN = "__GF_WEB_ASSET_ORIGIN__"
SITE_TOKEN = "__GF_SITE_ORIGIN__"
ORIGIN_PATTERN = re.compile(r"^https?://(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)(?::[1-9][0-9]{0,4})?/?$")
LOCAL_FILE_PATTERN = re.compile(r"[A-Za-z0-9_.-]+\.(?:html|js|wasm|pck|png|svg|webp|jpg|jpeg|ico)")


class ReferenceParser(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.references: list[str] = []

    def handle_starttag(self, _tag: str, attrs: list[tuple[str, str | None]]) -> None:
        for key, value in attrs:
            if key in {"src", "href"} and value:
                self.references.append(value)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def emit(value: dict[str, Any]) -> None:
    print(json.dumps(value, indent=2, sort_keys=True))


def load_object(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON root must be an object: {path}")
    return value


def safe_relative(value: Any) -> str | None:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        return None
    parsed = PurePosixPath(value)
    if parsed.is_absolute() or any(part in {"", ".", ".."} for part in parsed.parts):
        return None
    return parsed.as_posix()


def safe_route(value: str) -> str:
    if not value.startswith("/") or not value.endswith("/") or "\\" in value or "\x00" in value:
        raise ValueError("site route must start and end with /")
    parts = PurePosixPath(value.lstrip("/")).parts
    if not parts or any(part in {"", ".", ".."} for part in parts):
        raise ValueError("site route is unsafe")
    return "/" + "/".join(parts) + "/"


def valid_origin(value: str) -> bool:
    if not isinstance(value, str) or any(char in value for char in {'"', "'", "\\", "\r", "\n", "\t", " "}):
        return False
    if ORIGIN_PATTERN.fullmatch(value) is None or value.endswith("//"):
        return False
    parsed = urlparse(value)
    try:
        port = parsed.port
    except ValueError:
        return False
    return (
        parsed.scheme in {"http", "https"}
        and bool(parsed.hostname)
        and parsed.username is None
        and parsed.password is None
        and parsed.path in {"", "/"}
        and not parsed.params
        and not parsed.query
        and not parsed.fragment
        and (port is None or 1 <= port <= 65535)
    )


def mime_for(path: str) -> str:
    suffix = PurePosixPath(path).suffix.lower()
    explicit = {
        ".html": "text/html; charset=utf-8",
        ".js": "text/javascript; charset=utf-8",
        ".wasm": "application/wasm",
        ".pck": "application/octet-stream",
    }
    return explicit.get(suffix) or mimetypes.guess_type(path)[0] or "application/octet-stream"


def cache_policy_for(path: str, package: str) -> str:
    if package == "r2":
        return "immutable"
    return "revalidate" if path.endswith(".html") else "versioned-site-asset"


def classify(manifest: dict[str, Any], profile: dict[str, Any]) -> dict[str, Any]:
    files = manifest.get("files")
    if not isinstance(files, list) or not files:
        raise ValueError("source manifest files are missing")
    maximum = int(profile["max_file_bytes"])
    max_files = int(profile["max_files"])
    normalized: list[dict[str, Any]] = []
    for item in files:
        path = safe_relative(item.get("path")) if isinstance(item, dict) else None
        size = item.get("size_bytes") if isinstance(item, dict) else None
        if path is None or not isinstance(size, int) or size < 0:
            raise ValueError("source manifest contains an invalid file record")
        normalized.append({"path": path, "size_bytes": size, "content_role": item.get("content_role")})
    largest = max(normalized, key=lambda item: item["size_bytes"])
    oversized = [item for item in normalized if item["size_bytes"] > maximum]
    count_exceeded = len(normalized) > max_files
    compatible = not oversized and not count_exceeded
    reason = None
    if oversized:
        reason = "individual_file_limit"
    elif count_exceeded:
        reason = "file_count_limit"
    raw = largest["size_bytes"]
    compression = {"path": largest["path"], "raw_bytes": raw, "gzip_bytes": None, "brotli_bytes": None}
    return {
        "schema_version": SCHEMA_VERSION,
        "provider": profile["provider"],
        "hosting_profile": profile["profile"],
        "profile_version": profile["profile_version"],
        "compatible": compatible,
        "reason": reason,
        "file_count": len(normalized),
        "total_release_bytes": sum(item["size_bytes"] for item in normalized),
        "largest_file": largest["path"],
        "largest_file_bytes": raw,
        "max_file_bytes": maximum,
        "max_files": max_files,
        "oversized_files": oversized,
        "recommended_profile": profile["profile"] if compatible else profile["large_asset_recommendation"],
        "compression": compression,
    }


def deployment_file(root: Path, relative: str) -> Path:
    candidate = root.joinpath(*PurePosixPath(relative).parts)
    candidate.parent.mkdir(parents=True, exist_ok=True)
    return candidate


def is_r2_runtime_file(item: dict[str, Any], stem: str, maximum: int) -> bool:
    path = str(item["path"])
    role = item.get("content_role")
    return (
        int(item["size_bytes"]) > maximum
        or role in {"wasm", "game_data"}
        or path.endswith(".side.wasm")
        or path in {f"{stem}.audio.worklet.js", f"{stem}.audio.position.worklet.js"}
    )


def package_release(args: argparse.Namespace) -> dict[str, Any]:
    source_manifest_path = args.manifest.resolve(strict=True)
    bundle = args.bundle.resolve(strict=True)
    profile = load_object(args.profile.resolve(strict=True))
    source = load_object(source_manifest_path)
    classification = classify(source, profile)
    selected = args.hosting_profile
    if selected == "auto":
        selected = profile["profile"] if classification["compatible"] else profile["large_asset_recommendation"]
    if selected == profile["profile"] and not classification["compatible"]:
        raise ValueError(f"Pages-only rejected: {classification['largest_file']} is {classification['largest_file_bytes']} bytes; limit is {classification['max_file_bytes']} bytes")
    if selected not in {profile["profile"], profile["large_asset_recommendation"]}:
        raise ValueError("unsupported hosting profile")
    if not args.skip_compression_analysis:
        largest_source = bundle.joinpath(*PurePosixPath(classification["largest_file"]).parts)
        largest_bytes = largest_source.read_bytes()
        classification["compression"]["gzip_bytes"] = len(gzip.compress(largest_bytes, compresslevel=5, mtime=0))
        try:
            import brotli  # type: ignore[import-not-found]
            classification["compression"]["brotli_bytes"] = len(brotli.compress(largest_bytes, quality=5))
        except ImportError:
            classification["compression"]["brotli_bytes"] = None
    route = safe_route(args.route)
    slug = safe_relative(args.slug)
    if slug is None or "/" in slug:
        raise ValueError("slug must be one safe path segment")
    output = args.output.resolve(strict=False)
    if output.exists():
        raise ValueError("output directory already exists")
    pages = output / "pages"
    r2 = output / "r2"
    provenance = output / "provenance"
    pages.mkdir(parents=True)
    r2.mkdir(parents=True)
    provenance.mkdir(parents=True)
    manifest_hash = sha256(source_manifest_path)
    release_id = manifest_hash[:16]
    entrypoint = safe_relative(source.get("entrypoint"))
    if entrypoint is None:
        raise ValueError("source entrypoint is unsafe")
    stem = entrypoint[:-5] if entrypoint.endswith(".html") else str(PurePosixPath(entrypoint).with_suffix(""))
    split = selected == profile["large_asset_recommendation"]
    asset_prefix = f"assets/{slug}/{release_id}"
    route_prefix = route.lstrip("/").rstrip("/")
    file_records: list[dict[str, Any]] = []
    transformations: list[dict[str, Any]] = []
    source_files = {item["path"]: item for item in source["files"]}
    for original_path in sorted(source_files):
        item = source_files[original_path]
        safe = safe_relative(original_path)
        if safe is None:
            raise ValueError(f"unsafe source path: {original_path}")
        source_file = bundle.joinpath(*PurePosixPath(safe).parts)
        if not source_file.is_file() or source_file.is_symlink() or sha256(source_file) != item.get("sha256") or source_file.stat().st_size != item.get("size_bytes"):
            raise ValueError(f"source provenance mismatch: {safe}")
        package = "r2" if split and is_r2_runtime_file(item, stem, int(profile["max_file_bytes"])) else "pages"
        deployment = f"{asset_prefix}/{safe}" if package == "r2" else f"{route_prefix}/{safe}"
        destination = deployment_file(r2 if package == "r2" else pages, deployment)
        transformed = False
        if split and safe == entrypoint:
            old = f'"executable":"{stem}"'
            asset_base = f"{ASSET_TOKEN}/{asset_prefix}/{stem}"
            new = f'"executable":"{asset_base}"'
            text = source_file.read_text(encoding="utf-8")
            if text.count(old) != 1:
                raise ValueError("Godot HTML executable contract was not found exactly once")
            destination.write_text(text.replace(old, new), encoding="utf-8")
            source_copy = deployment_file(provenance, safe)
            shutil.copyfile(source_file, source_copy)
            transformed = True
            transformations.append({
                "original_path": safe,
                "deployment_path": deployment,
                "kind": "godot_executable_asset_origin",
                "placeholder": ASSET_TOKEN,
                "source_copy": f"provenance/{safe}",
                "source_sha256": item["sha256"],
                "output_sha256": sha256(destination),
            })
        else:
            shutil.copyfile(source_file, destination)
        file_records.append({
            "original_path": safe,
            "deployment_path": deployment,
            "package": package,
            "size_bytes": destination.stat().st_size,
            "sha256": sha256(destination),
            "source_sha256": item["sha256"],
            "transformed": transformed,
            "content_role": item.get("content_role", "other"),
            "mime": mime_for(safe),
            "cache_policy_class": cache_policy_for(safe, package),
        })
    shutil.copyfile(source_manifest_path, output / "source-web-release.json")
    entry_deployment = next(item["deployment_path"] for item in file_records if item["original_path"] == entrypoint)
    hosting = {
        "schema_version": SCHEMA_VERSION,
        "fixture_id": source.get("fixture_id"),
        "game_id": source.get("game_id"),
        "runtime_target": "web",
        "provider": profile["provider"],
        "provider_profile_sha256": sha256(args.profile.resolve(strict=True)),
        "hosting_profile": selected,
        "profile_version": profile["profile_version"],
        "release_id": release_id,
        "game_slug": slug,
        "site_route": route,
        "entrypoint_deployment_path": entry_deployment,
        "site_package": "pages",
        "asset_package": "r2" if split else None,
        "source_web_manifest": "source-web-release.json",
        "source_web_manifest_sha256": manifest_hash,
        "pages_constraints": {
            "max_file_bytes": profile["max_file_bytes"],
            "max_files": profile["max_files"],
            "verified_at": profile["verified_at"],
            "source_reference": profile["source_reference"],
        },
        "asset_origin": {
            "mode": "placeholder" if split else "same_origin",
            "placeholder": ASSET_TOKEN if split else None,
            "value": None,
            "asset_prefix": asset_prefix if split else None,
        },
        "cross_origin_required": split,
        "cors": {
            "required": split,
            "allowed_origins": [SITE_TOKEN] if split else [],
            "allowed_methods": ["GET", "HEAD"] if split else [],
            "response_header": "Access-Control-Allow-Origin" if split else None,
            "wildcard_forbidden": True,
        },
        "required_headers": {
            "wasm_content_type": "application/wasm",
            "pck_content_type": "application/octet-stream",
            "html_cache_control": "no-cache",
            "immutable_asset_cache_control": "public, max-age=31536000, immutable",
        },
        "placement_policy": {
            "oversized_files": "r2",
            "godot_executable_derived_assets": "r2",
            "primary_loader_and_site_shell": "pages"
        },
        "files": file_records,
        "transformations": transformations,
    }
    (output / "classification.json").write_text(json.dumps(classification, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (output / "hosting-manifest.json").write_text(json.dumps(hosting, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return {"status": "pass", "output": str(output), "hosting_profile": selected, "classification": classification, "hosting_manifest": str(output / "hosting-manifest.json")}


def actual_files(root: Path) -> set[str]:
    if not root.exists():
        return set()
    if root.is_symlink() or not root.is_dir():
        raise ValueError(f"package root must be a real directory: {root}")
    real_root = root.resolve(strict=True)
    values: set[str] = set()
    for path in root.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"package symlink is forbidden: {path}")
        if path.is_file():
            resolved = path.resolve(strict=True)
            if real_root not in resolved.parents:
                raise ValueError(f"package file escapes its root: {path}")
            values.add(path.relative_to(root).as_posix())
    return values


def verify_release(root: Path, profile_path: Path) -> dict[str, Any]:
    errors: list[str] = []
    unresolved_root = root.absolute()
    if unresolved_root.is_symlink():
        return {"status": "fail", "release": str(unresolved_root), "errors": ["release root symlink is forbidden"]}
    try:
        root = root.resolve(strict=True)
        manifest_path = root / "hosting-manifest.json"
        if manifest_path.is_symlink() or not manifest_path.is_file():
            raise ValueError("hosting manifest must be a real file inside the release")
        manifest = load_object(manifest_path)
        profile_path = profile_path.resolve(strict=True)
        profile = load_object(profile_path)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        return {"status": "fail", "release": str(root), "errors": [f"manifest parse failed: {error}"]}
    files = manifest.get("files")
    if manifest.get("schema_version") != SCHEMA_VERSION or not isinstance(files, list):
        errors.append("unsupported or incomplete hosting manifest")
        files = []
    for name, kind in (("source-web-release.json", "file"), ("classification.json", "file"), ("pages", "directory"), ("r2", "directory"), ("provenance", "directory")):
        candidate = root / name
        valid = candidate.is_file() if kind == "file" else candidate.is_dir()
        if candidate.is_symlink() or not valid:
            errors.append(f"release {kind} must be a real in-root path: {name}")
            continue
        try:
            if root not in candidate.resolve(strict=True).parents:
                errors.append(f"release path escapes root: {name}")
        except OSError:
            errors.append(f"release path is unreadable: {name}")
    expected_constraints = {
        "max_file_bytes": profile.get("max_file_bytes"),
        "max_files": profile.get("max_files"),
        "verified_at": profile.get("verified_at"),
        "source_reference": profile.get("source_reference"),
    }
    if (
        manifest.get("provider") != profile.get("provider")
        or manifest.get("provider_profile_sha256") != sha256(profile_path)
        or manifest.get("profile_version") != profile.get("profile_version")
        or manifest.get("hosting_profile") not in {profile.get("profile"), profile.get("large_asset_recommendation")}
        or manifest.get("pages_constraints") != expected_constraints
    ):
        errors.append("hosting manifest is not bound to the trusted provider profile")
    expected_split_profile = manifest.get("hosting_profile") == profile.get("large_asset_recommendation")
    if (
        manifest.get("runtime_target") != "web"
        or manifest.get("site_package") != "pages"
        or manifest.get("asset_package") != ("r2" if expected_split_profile else None)
    ):
        errors.append("top-level runtime/package contract is invalid")
    seen_original: set[str] = set()
    seen_deployment: set[str] = set()
    expected = {"pages": set(), "r2": set()}
    source_by_path: dict[str, dict[str, Any]] = {}
    source_manifest: dict[str, Any] = {}
    source_semantic_errors: list[str] = []
    source_manifest_relative = manifest.get("source_web_manifest")
    if source_manifest_relative != "source-web-release.json" or safe_relative(source_manifest_relative) is None:
        errors.append("source Web manifest path must be the canonical embedded source-web-release.json")
        source_manifest_relative = "source-web-release.json"
    source_path = root / source_manifest_relative
    try:
        if source_path.is_symlink() or not source_path.is_file() or root not in source_path.resolve(strict=True).parents:
            raise ValueError("embedded source manifest must be a real file inside the release")
        if sha256(source_path) != manifest.get("source_web_manifest_sha256"):
            errors.append("source Web manifest hash mismatch")
        source_manifest = load_object(source_path)
        source_records = source_manifest.get("files")
        if source_manifest.get("schema_version") != "1" or source_manifest.get("target") != "web" or source_manifest.get("renderer") != "gl_compatibility" or source_manifest.get("threaded") is not False:
            source_semantic_errors.append("schema/target/renderer/threading contract is invalid")
        if not isinstance(source_records, list) or not source_records:
            source_semantic_errors.append("file inventory is missing")
            source_records = []
        roles: set[str] = set()
        declared_total = 0
        largest: dict[str, Any] | None = None
        for source_item in source_records:
            source_relative = safe_relative(source_item.get("path")) if isinstance(source_item, dict) else None
            if source_relative is None or source_relative in source_by_path:
                source_semantic_errors.append("source inventory contains an unsafe or duplicate path")
                continue
            size = source_item.get("size_bytes")
            digest = source_item.get("sha256")
            role = source_item.get("content_role")
            if not isinstance(size, int) or size < 0 or not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None or not isinstance(role, str):
                source_semantic_errors.append(f"invalid source file record: {source_relative}")
                continue
            source_by_path[source_relative] = source_item
            roles.add(role)
            declared_total += size
            if largest is None or size > largest["size_bytes"]:
                largest = {"path": source_relative, "size_bytes": size}
        if source_manifest.get("bundle_file_count") != len(source_by_path) or source_manifest.get("bundle_total_bytes") != declared_total or source_manifest.get("largest_file") != largest:
            source_semantic_errors.append("source inventory totals or largest-file record are invalid")
        missing_roles = sorted({"entry_html", "wasm", "javascript", "game_data"} - roles)
        if missing_roles:
            source_semantic_errors.append("required source roles are missing: " + ", ".join(missing_roles))
        source_entrypoint_semantic = safe_relative(source_manifest.get("entrypoint"))
        if source_entrypoint_semantic is None or source_entrypoint_semantic not in source_by_path or source_by_path.get(source_entrypoint_semantic, {}).get("content_role") != "entry_html":
            source_semantic_errors.append("source entrypoint is invalid or not an entry_html record")
    except (OSError, json.JSONDecodeError, ValueError):
        errors.append("source Web manifest provenance is unavailable")
    if source_semantic_errors:
        errors.append("embedded source Web manifest is not a valid GF-WEB-001 release: " + "; ".join(source_semantic_errors))
    if manifest.get("fixture_id") != source_manifest.get("fixture_id") or manifest.get("game_id") != source_manifest.get("game_id") or manifest.get("runtime_target") != source_manifest.get("target"):
        errors.append("hosting identity is not bound to the embedded source manifest")
    for item in files:
        if not isinstance(item, dict):
            errors.append("invalid file record")
            continue
        original = safe_relative(item.get("original_path"))
        deployment = safe_relative(item.get("deployment_path"))
        package = item.get("package")
        if original is None or deployment is None or package not in expected:
            errors.append("unsafe path or invalid package in file record")
            continue
        if original in seen_original:
            errors.append(f"duplicate original path: {original}")
        if deployment in seen_deployment:
            errors.append(f"duplicate deployment path: {deployment}")
        seen_original.add(original)
        seen_deployment.add(deployment)
        expected[package].add(deployment)
        location = root / package / deployment
        package_root = root / package
        try:
            resolved_location = location.resolve(strict=True)
            resolved_package_root = package_root.resolve(strict=True)
        except OSError:
            resolved_location = None
            resolved_package_root = None
        if not location.is_file() or location.is_symlink() or resolved_location is None or resolved_package_root not in resolved_location.parents:
            errors.append(f"missing {package} file: {deployment}")
            continue
        digest = sha256(location)
        if digest != item.get("sha256") or location.stat().st_size != item.get("size_bytes"):
            errors.append(f"hash or size mismatch: {package}/{deployment}")
        source_item = source_by_path.get(original)
        if source_item is None or source_item.get("sha256") != item.get("source_sha256"):
            errors.append(f"source provenance mismatch: {original}")
        if source_item is not None and source_item.get("content_role") != item.get("content_role"):
            errors.append(f"source content-role mismatch: {original}")
        if not item.get("transformed") and digest != item.get("source_sha256"):
            errors.append(f"untransformed file bytes changed: {original}")
        if item.get("mime") != mime_for(original):
            errors.append(f"invalid MIME contract: {original}")
        if item.get("cache_policy_class") != cache_policy_for(original, package):
            errors.append(f"invalid cache-policy class: {original}")
    if seen_original != set(source_by_path):
        missing_source = sorted(set(source_by_path) - seen_original)
        extra_source = sorted(seen_original - set(source_by_path))
        errors.append(f"hosting/source manifest path coverage mismatch: missing={missing_source} extra={extra_source}")
    transformations = manifest.get("transformations")
    if not isinstance(transformations, list):
        errors.append("transformations must be an array")
        transformations = []
    transformation_by_deployment: dict[str, dict[str, Any]] = {}
    expected_provenance: set[str] = set()
    for transformation in transformations:
        if not isinstance(transformation, dict):
            errors.append("invalid transformation record")
            continue
        deployment = safe_relative(transformation.get("deployment_path"))
        source_copy = safe_relative(transformation.get("source_copy"))
        if deployment is None or source_copy is None or not source_copy.startswith("provenance/"):
            errors.append("unsafe transformation or provenance path")
            continue
        if deployment in transformation_by_deployment:
            errors.append(f"duplicate transformation path: {deployment}")
        transformation_by_deployment[deployment] = transformation
        expected_provenance.add(source_copy.removeprefix("provenance/"))
    for item in files:
        if not isinstance(item, dict) or not isinstance(item.get("deployment_path"), str):
            continue
        transformation = transformation_by_deployment.get(item["deployment_path"])
        if bool(item.get("transformed")) != (transformation is not None):
            errors.append(f"transformation manifest mismatch: {item.get('original_path')}")
    try:
        if actual_files(root / "provenance") != expected_provenance:
            errors.append("transformation provenance file set mismatch")
    except ValueError as error:
        errors.append(str(error))
    try:
        for package in expected:
            extras = actual_files(root / package) - expected[package]
            missing = expected[package] - actual_files(root / package)
            if extras:
                errors.append(f"unmanifested {package} files: {', '.join(sorted(extras))}")
            if missing:
                errors.append(f"manifested {package} files missing: {', '.join(sorted(missing))}")
    except ValueError as error:
        errors.append(str(error))
    constraints = manifest.get("pages_constraints", {})
    maximum = profile.get("max_file_bytes")
    max_files = profile.get("max_files")
    page_records = [item for item in files if isinstance(item, dict) and item.get("package") == "pages"]
    if not isinstance(maximum, int) or not isinstance(max_files, int):
        errors.append("Pages constraints are incomplete")
    else:
        for item in page_records:
            if isinstance(item.get("size_bytes"), int) and item["size_bytes"] > maximum:
                errors.append(f"Pages file exceeds individual limit: {item.get('deployment_path')}")
        if len(page_records) > max_files:
            errors.append("Pages file count exceeds limit")
    expected_headers = {
        "wasm_content_type": "application/wasm",
        "pck_content_type": "application/octet-stream",
        "html_cache_control": "no-cache",
        "immutable_asset_cache_control": "public, max-age=31536000, immutable",
    }
    if manifest.get("required_headers") != expected_headers:
        errors.append("required MIME/cache header contract is incomplete or invalid")
    expected_placement = {
        "oversized_files": "r2",
        "godot_executable_derived_assets": "r2",
        "primary_loader_and_site_shell": "pages",
    }
    if manifest.get("placement_policy") != expected_placement:
        errors.append("release placement policy is incomplete or invalid")
    for source_relative, source_item in source_by_path.items():
        hosting_record = next((item for item in files if isinstance(item, dict) and item.get("original_path") == source_relative), None)
        source_bytes_path: Path | None = None
        if hosting_record:
            if hosting_record.get("transformed"):
                transformation = next((item for item in transformations if isinstance(item, dict) and item.get("original_path") == source_relative), None)
                source_copy = safe_relative(transformation.get("source_copy")) if transformation else None
                if source_copy:
                    source_bytes_path = root.joinpath(*PurePosixPath(source_copy).parts)
            elif hosting_record.get("package") in {"pages", "r2"}:
                deployment = safe_relative(hosting_record.get("deployment_path"))
                if deployment:
                    source_bytes_path = root / hosting_record["package"] / deployment
        try:
            if source_bytes_path is None or source_bytes_path.is_symlink() or not source_bytes_path.is_file() or root not in source_bytes_path.resolve(strict=True).parents:
                raise ValueError("source bytes are unavailable or escape the release")
            if source_bytes_path.stat().st_size != source_item.get("size_bytes") or sha256(source_bytes_path) != source_item.get("sha256"):
                raise ValueError("source bytes do not match the embedded inventory")
        except (OSError, ValueError) as error:
            errors.append(f"embedded source byte validation failed for {source_relative}: {error}")
    source_entrypoint = safe_relative(source_manifest.get("entrypoint"))
    source_stem = source_entrypoint[:-5] if source_entrypoint and source_entrypoint.endswith(".html") else ""
    route = manifest.get("site_route")
    slug = safe_relative(manifest.get("game_slug"))
    try:
        route_prefix = safe_route(route).lstrip("/").rstrip("/") if isinstance(route, str) else None
    except ValueError:
        route_prefix = None
    if slug is None or "/" in slug or route_prefix is None:
        errors.append("game slug or site route is unsafe")
    release_id = manifest.get("release_id")
    if release_id != str(manifest.get("source_web_manifest_sha256", ""))[:16]:
        errors.append("release ID is not bound to source provenance")
    split = manifest.get("hosting_profile") == profile.get("large_asset_recommendation")
    asset = manifest.get("asset_origin", {})
    asset_prefix = asset.get("asset_prefix") if isinstance(asset, dict) else None
    expected_asset_prefix = f"assets/{slug}/{release_id}" if slug and release_id else None
    if split and asset_prefix != expected_asset_prefix:
        errors.append("asset prefix is not bound to the game slug and release ID")
    for item in files:
        if not isinstance(item, dict):
            continue
        original = safe_relative(item.get("original_path"))
        source_record = source_by_path.get(original, {}) if original else {}
        should_r2 = bool(split and source_stem and source_record and isinstance(maximum, int) and is_r2_runtime_file(source_record, source_stem, maximum))
        expected_package = "r2" if should_r2 else "pages"
        if item.get("package") != expected_package:
            errors.append(f"file violates deterministic placement policy: {original}")
        expected_deployment = f"{expected_asset_prefix}/{original}" if should_r2 else (f"{route_prefix}/{original}" if route_prefix and original else None)
        if item.get("deployment_path") != expected_deployment:
            errors.append(f"deployment path violates route/prefix contract: {original}")
    entry_records = [item for item in files if isinstance(item, dict) and item.get("original_path") == source_entrypoint]
    if len(entry_records) != 1 or manifest.get("entrypoint_deployment_path") != entry_records[0].get("deployment_path"):
        errors.append("entrypoint deployment is not bound to the source entrypoint")
    if split:
        if not manifest.get("cross_origin_required") or not manifest.get("cors", {}).get("required"):
            errors.append("split release lacks cross-origin/CORS contract")
        allowed = manifest.get("cors", {}).get("allowed_origins")
        if not isinstance(allowed, list) or not allowed or "*" in allowed:
            errors.append("split release CORS allowed origins are incomplete or unsafe")
        mode = asset.get("mode")
        value = asset.get("value")
        if mode == "placeholder":
            if asset.get("placeholder") != ASSET_TOKEN or allowed != [SITE_TOKEN]:
                errors.append("placeholder asset-origin contract is invalid")
        elif mode == "fixed":
            local_site_origin = manifest.get("local_site_origin")
            if (
                not isinstance(value, str)
                or not valid_origin(value)
                or not isinstance(local_site_origin, str)
                or not valid_origin(local_site_origin)
                or allowed != [local_site_origin]
            ):
                errors.append("finalized asset/CORS origin is invalid")
        else:
            errors.append("split release asset origin mode is invalid")
        cors = manifest.get("cors", {})
        if cors.get("allowed_methods") != ["GET", "HEAD"]:
            errors.append("split release CORS methods must be exactly GET and HEAD")
        if cors.get("response_header") != "Access-Control-Allow-Origin":
            errors.append("split release CORS response-header contract is invalid")
        if cors.get("wildcard_forbidden") is not True:
            errors.append("split release must explicitly forbid wildcard CORS")
        if safe_relative(asset_prefix) is None:
            errors.append("asset prefix is unsafe")
        entry_transformations = [item for item in transformations if isinstance(item, dict) and item.get("original_path") == source_entrypoint]
        if len(entry_records) != 1 or len(entry_transformations) != 1:
            errors.append("split release requires exactly one transformed source entrypoint")
        elif (
            entry_records[0].get("package") != "pages"
            or entry_records[0].get("transformed") is not True
            or entry_transformations[0].get("deployment_path") != entry_records[0].get("deployment_path")
            or entry_transformations[0].get("source_copy") != f"provenance/{source_entrypoint}"
            or entry_transformations[0].get("source_sha256") != source_by_path.get(source_entrypoint, {}).get("sha256")
            or manifest.get("entrypoint_deployment_path") != entry_records[0].get("deployment_path")
        ):
            errors.append("split entrypoint transformation is not bound to source provenance and deployment")
        for transformation in transformations:
            if not isinstance(transformation, dict) or transformation.get("kind") != "godot_executable_asset_origin":
                errors.append("unsupported transformation kind")
                continue
            deployment = safe_relative(transformation.get("deployment_path"))
            original = safe_relative(transformation.get("original_path"))
            source_copy = safe_relative(transformation.get("source_copy"))
            if None in {deployment, original, source_copy}:
                continue
            source_file = root.joinpath(*PurePosixPath(source_copy).parts)
            deployed_file = root / "pages" / deployment
            try:
                source_text = source_file.read_text(encoding="utf-8")
                old = f'"executable":"{source_stem}"'
                template_value = f"{ASSET_TOKEN}/{asset_prefix}/{source_stem}"
                template_text = source_text.replace(old, f'"executable":"{template_value}"')
                template_hash = hashlib.sha256(template_text.encode("utf-8")).hexdigest()
                if source_text.count(old) != 1 or sha256(source_file) != transformation.get("source_sha256"):
                    errors.append(f"transformation source proof mismatch: {original}")
                if template_hash != transformation.get("output_sha256"):
                    errors.append(f"placeholder transformation hash mismatch: {original}")
                if mode == "placeholder":
                    expected_text = template_text
                    expected_hash = transformation.get("output_sha256")
                else:
                    expected_text = template_text.replace(ASSET_TOKEN, str(value).rstrip("/"))
                    expected_hash = transformation.get("finalized_sha256")
                if deployed_file.read_text(encoding="utf-8") != expected_text or sha256(deployed_file) != expected_hash:
                    errors.append(f"deterministic transformation mismatch: {original}")
            except (OSError, UnicodeDecodeError):
                errors.append(f"transformation evidence unreadable: {original}")
        for item in files:
            source_item = source_by_path.get(item.get("original_path"), {}) if isinstance(item, dict) else {}
            if isinstance(maximum, int) and source_item.get("size_bytes", 0) > maximum and item.get("package") != "r2":
                errors.append(f"oversized source asset leaked into Pages: {item.get('original_path')}")
            if isinstance(item, dict) and source_entrypoint:
                source_record = source_by_path.get(item.get("original_path"), {})
                should_r2 = is_r2_runtime_file(source_record, source_stem, int(maximum)) if isinstance(maximum, int) and source_record else False
                if should_r2 and item.get("package") != "r2":
                    errors.append(f"Godot executable-derived asset is not in R2: {item.get('original_path')}")
    else:
        if expected["r2"]:
            errors.append("Pages-only release contains R2 assets")
        cors = manifest.get("cors")
        if manifest.get("cross_origin_required") is not False or cors != {
            "required": False,
            "allowed_origins": [],
            "allowed_methods": [],
            "response_header": None,
            "wildcard_forbidden": True,
        }:
            errors.append("Pages-only release has an invalid same-origin/CORS contract")
        if not isinstance(asset, dict) or asset.get("mode") != "same_origin" or asset.get("placeholder") is not None or asset.get("asset_prefix") is not None:
            errors.append("Pages-only asset-origin contract is invalid")
        same_origin_value = asset.get("value") if isinstance(asset, dict) else None
        if same_origin_value is not None and (not isinstance(same_origin_value, str) or not valid_origin(same_origin_value)):
            errors.append("Pages-only finalized site origin is invalid")
        if same_origin_value is not None and manifest.get("local_site_origin") != same_origin_value:
            errors.append("Pages-only finalized origin is not bound to local_site_origin")
    source_entrypoint = safe_relative(source_manifest.get("entrypoint"))
    if source_entrypoint and source_entrypoint in source_by_path:
        entry_record = next((item for item in files if isinstance(item, dict) and item.get("original_path") == source_entrypoint), None)
        entry_source: Path | None = None
        if entry_record:
            if entry_record.get("transformed"):
                entry_source = root / "provenance" / source_entrypoint
            elif entry_record.get("package") in {"pages", "r2"} and safe_relative(entry_record.get("deployment_path")):
                entry_source = root / entry_record["package"] / entry_record["deployment_path"]
        try:
            if entry_source is None or entry_source.is_symlink() or root not in entry_source.resolve(strict=True).parents:
                raise ValueError("source entrypoint bytes are unavailable")
            entry_bytes = entry_source.read_bytes()
            source_item = source_by_path[source_entrypoint]
            if len(entry_bytes) != source_item.get("size_bytes") or hashlib.sha256(entry_bytes).hexdigest() != source_item.get("sha256"):
                raise ValueError("source entrypoint bytes do not match its inventory")
            html_text = entry_bytes.decode("utf-8")
            parser = ReferenceParser()
            parser.feed(html_text)
            for reference in parser.references + LOCAL_FILE_PATTERN.findall(html_text):
                if reference.startswith(("http://", "https://", "//")):
                    raise ValueError(f"external source dependency is forbidden: {reference}")
                if reference.startswith(("data:", "#")):
                    continue
                reference_path = safe_relative(reference.split("?", 1)[0].split("#", 1)[0])
                if reference_path is None or reference_path not in source_by_path:
                    raise ValueError(f"source entrypoint reference is unsafe or missing: {reference}")
            if re.search(r"const\s+GODOT_THREADS_ENABLED\s*=\s*false\s*;", html_text) is None:
                raise ValueError("source entrypoint does not prove GODOT_THREADS_ENABLED=false")
        except (OSError, UnicodeDecodeError, ValueError) as error:
            errors.append(f"embedded source Web entrypoint validation failed: {error}")
    return {
        "status": "pass" if not errors else "fail",
        "release": str(root),
        "hosting_profile": manifest.get("hosting_profile"),
        "file_count": len(files),
        "pages_file_count": len(expected["pages"]),
        "r2_file_count": len(expected["r2"]),
        "errors": errors,
    }


def finalize_release(args: argparse.Namespace) -> dict[str, Any]:
    source = args.release.resolve(strict=True)
    preflight = verify_release(source, args.profile)
    if preflight["status"] != "pass":
        raise ValueError("input hosting release verification failed: " + "; ".join(preflight["errors"]))
    output = args.output.resolve(strict=False)
    if output.exists():
        raise ValueError("finalized output directory already exists")
    if not valid_origin(args.site_origin):
        raise ValueError("site origin must be an http(s) origin without a path")
    manifest = load_object(source / "hosting-manifest.json")
    split = manifest.get("hosting_profile") == "cloudflare-pages-r2"
    if split and not valid_origin(args.asset_origin):
        raise ValueError("asset origin must be an http(s) origin without a path")
    shutil.copytree(source, output)
    manifest = load_object(output / "hosting-manifest.json")
    if split:
        for transformation in manifest.get("transformations", []):
            deployment = safe_relative(transformation.get("deployment_path"))
            if deployment is None:
                raise ValueError("unsafe transformation path")
            target = output / "pages" / deployment
            text = target.read_text(encoding="utf-8")
            if text.count(ASSET_TOKEN) != 1:
                raise ValueError("asset-origin placeholder was not found exactly once")
            target.write_text(text.replace(ASSET_TOKEN, args.asset_origin.rstrip("/")), encoding="utf-8")
            transformation["finalized_sha256"] = sha256(target)
            record = next(item for item in manifest["files"] if item["deployment_path"] == deployment and item["package"] == "pages")
            record["sha256"] = sha256(target)
            record["size_bytes"] = target.stat().st_size
        manifest["asset_origin"]["mode"] = "fixed"
        manifest["asset_origin"]["value"] = args.asset_origin.rstrip("/")
        manifest["cors"]["allowed_origins"] = [args.site_origin.rstrip("/")]
    else:
        manifest["asset_origin"]["value"] = args.site_origin.rstrip("/")
    manifest["local_site_origin"] = args.site_origin.rstrip("/")
    (output / "hosting-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    result = verify_release(output, args.profile)
    if result["status"] != "pass":
        raise ValueError("finalized hosting release verification failed: " + "; ".join(result["errors"]))
    return {"status": "pass", "output": str(output), "site_origin": args.site_origin.rstrip("/"), "asset_origin": args.asset_origin.rstrip("/") if split else None, "verification": result}


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    classify_parser = sub.add_parser("classify")
    classify_parser.add_argument("manifest", type=Path)
    classify_parser.add_argument("profile", type=Path)
    package_parser = sub.add_parser("package")
    package_parser.add_argument("manifest", type=Path)
    package_parser.add_argument("bundle", type=Path)
    package_parser.add_argument("output", type=Path)
    package_parser.add_argument("--profile", type=Path, required=True)
    package_parser.add_argument("--hosting-profile", default="auto", choices=["auto", "cloudflare-pages", "cloudflare-pages-r2"])
    package_parser.add_argument("--slug", required=True)
    package_parser.add_argument("--route", required=True)
    package_parser.add_argument("--skip-compression-analysis", action="store_true")
    verify_parser = sub.add_parser("verify")
    verify_parser.add_argument("release", type=Path)
    verify_parser.add_argument("--profile", type=Path, required=True)
    finalize_parser = sub.add_parser("finalize")
    finalize_parser.add_argument("release", type=Path)
    finalize_parser.add_argument("output", type=Path)
    finalize_parser.add_argument("--site-origin", required=True)
    finalize_parser.add_argument("--asset-origin", default="")
    finalize_parser.add_argument("--profile", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "classify":
            manifest = load_object(args.manifest.resolve(strict=True))
            result = classify(manifest, load_object(args.profile.resolve(strict=True)))
        elif args.command == "package":
            result = package_release(args)
        elif args.command == "verify":
            result = verify_release(args.release, args.profile)
        else:
            result = finalize_release(args)
        emit(result)
        return 0 if result.get("status") == "pass" or (args.command == "classify") else 1
    except (OSError, ValueError, json.JSONDecodeError, KeyError) as error:
        emit({"status": "fail", "command": args.command, "error": str(error)})
        return 1


if __name__ == "__main__":
    sys.exit(main())
