#!/usr/bin/env python3
"""Deterministic validation and manifest tooling for Game Foundry Web releases."""

from __future__ import annotations

import argparse
import configparser
import hashlib
import html.parser
import json
import mimetypes
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any


SCHEMA_VERSION = "1"
REQUIRED_RENDERER = "gl_compatibility"
REQUIRED_TARGET = "web"
LOCAL_FILE_PATTERN = re.compile(r"[A-Za-z0-9_.-]+\.(?:html|js|wasm|pck|png|svg|webp|jpg|jpeg|ico)")


def emit(value: dict[str, Any]) -> None:
    print(json.dumps(value, indent=2, sort_keys=True))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_relative(value: Any) -> str | None:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        return None
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        return None
    return path.as_posix()


def source_fingerprint(project: Path) -> tuple[str, int]:
    project = project.resolve(strict=True)
    records: list[bytes] = []
    count = 0
    for path in sorted(project.rglob("*"), key=lambda item: item.relative_to(project).as_posix()):
        rel = path.relative_to(project)
        if rel.parts and rel.parts[0] == ".godot":
            continue
        info = path.lstat()
        rel_bytes = rel.as_posix().encode("utf-8", errors="surrogateescape")
        if stat.S_ISLNK(info.st_mode):
            payload = os.readlink(path).encode("utf-8", errors="surrogateescape")
            records.append(b"L\0" + rel_bytes + b"\0" + payload + b"\0")
            count += 1
        elif stat.S_ISREG(info.st_mode):
            records.append(b"F\0" + rel_bytes + b"\0" + str(info.st_size).encode() + b"\0" + sha256(path).encode() + b"\0")
            count += 1
        elif stat.S_ISDIR(info.st_mode):
            records.append(b"D\0" + rel_bytes + b"\0")
    digest = hashlib.sha256(b"".join(records)).hexdigest()
    return digest, count


def read_godot_config(path: Path) -> configparser.ConfigParser:
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    text = path.read_text(encoding="utf-8")
    # project.godot has a top-level config_version assignment before sections.
    parser.read_string("[__root__]\n" + text, source=str(path))
    return parser


def unquote(value: str | None) -> str:
    if value is None:
        return ""
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return value[1:-1]
    return value


def parse_bool(value: str | None) -> bool | None:
    value = unquote(value).lower()
    if value == "true":
        return True
    if value == "false":
        return False
    return None


def validate_project(project: Path, preset_name: str) -> dict[str, Any]:
    failures: list[str] = []
    project_file = project / "project.godot"
    preset_file = project / "export_presets.cfg"
    renderer = ""
    renderer_mobile = ""
    preset_index = ""
    thread_support: bool | None = None
    extensions_support: bool | None = None
    platform = ""

    if not project.is_dir():
        failures.append("project path is not a directory")
    if not project_file.is_file():
        failures.append("project.godot is missing")
    if not preset_file.is_file():
        failures.append("export_presets.cfg is missing")

    try:
        project_cfg = read_godot_config(project_file)
        renderer = unquote(project_cfg.get("rendering", "renderer/rendering_method", fallback=""))
        renderer_mobile = unquote(project_cfg.get("rendering", "renderer/rendering_method.mobile", fallback=""))
        if renderer != REQUIRED_RENDERER or renderer_mobile != REQUIRED_RENDERER:
            failures.append("Web target requires gl_compatibility for desktop and mobile rendering methods")
    except (OSError, configparser.Error) as error:
        failures.append(f"project.godot could not be parsed: {error}")

    try:
        preset_cfg = read_godot_config(preset_file)
        for section in preset_cfg.sections():
            match = re.fullmatch(r"preset\.(\d+)", section)
            if match and unquote(preset_cfg.get(section, "name", fallback="")) == preset_name:
                preset_index = match.group(1)
                platform = unquote(preset_cfg.get(section, "platform", fallback=""))
                break
        if not preset_index:
            failures.append(f"Web export preset not found: {preset_name}")
        else:
            options = f"preset.{preset_index}.options"
            if platform != "Web":
                failures.append("selected export preset platform is not Web")
            if not preset_cfg.has_section(options):
                failures.append("selected Web preset has no options section")
            else:
                thread_support = parse_bool(preset_cfg.get(options, "variant/thread_support", fallback=None))
                extensions_support = parse_bool(preset_cfg.get(options, "variant/extensions_support", fallback=None))
                if thread_support is not False:
                    failures.append("initial Game Foundry Web profile requires variant/thread_support=false")
                if extensions_support is not False:
                    failures.append("initial Game Foundry Web profile requires variant/extensions_support=false")
    except (OSError, configparser.Error) as error:
        failures.append(f"export_presets.cfg could not be parsed: {error}")

    native_files: list[str] = []
    if project.is_dir():
        for candidate in project.rglob("*"):
            try:
                rel = candidate.relative_to(project)
                if rel.parts and rel.parts[0] == ".godot":
                    continue
                if candidate.is_file() and candidate.suffix.lower() in {".gdextension", ".so", ".dll", ".dylib"}:
                    native_files.append(rel.as_posix())
            except OSError:
                failures.append("project contains an unreadable resource")
                break
    if native_files:
        failures.append("initial Web profile rejects native extension resources: " + ", ".join(sorted(native_files)))

    return {
        "status": "pass" if not failures else "fail",
        "target": REQUIRED_TARGET,
        "project": str(project.resolve(strict=False)),
        "preset": preset_name,
        "platform": platform or None,
        "renderer": renderer or None,
        "renderer_mobile": renderer_mobile or None,
        "threaded": thread_support,
        "extensions_support": extensions_support,
        "native_extension_files": sorted(native_files),
        "failures": failures,
    }


def role_for(path: str) -> str:
    suffix = PurePosixPath(path).suffix.lower()
    return {
        ".html": "entry_html",
        ".wasm": "wasm",
        ".js": "javascript",
        ".pck": "game_data",
        ".png": "icon",
        ".ico": "icon",
    }.get(suffix, "other")


def mime_for(path: str) -> str | None:
    suffix = PurePosixPath(path).suffix.lower()
    explicit = {
        ".html": "text/html; charset=utf-8",
        ".js": "text/javascript; charset=utf-8",
        ".wasm": "application/wasm",
        ".pck": "application/octet-stream",
    }
    return explicit.get(suffix) or mimetypes.guess_type(path)[0]


def bundle_files(bundle: Path) -> list[Path]:
    values: list[Path] = []
    for path in sorted(bundle.rglob("*"), key=lambda item: item.relative_to(bundle).as_posix()):
        if path.is_symlink():
            raise ValueError(f"bundle symlink is forbidden: {path.relative_to(bundle).as_posix()}")
        if path.is_file():
            values.append(path)
    return values


def create_manifest(args: argparse.Namespace) -> dict[str, Any]:
    bundle = args.bundle.resolve(strict=True)
    files: list[dict[str, Any]] = []
    total = 0
    for path in bundle_files(bundle):
        relative = path.relative_to(bundle).as_posix()
        size = path.stat().st_size
        item: dict[str, Any] = {
            "path": relative,
            "size_bytes": size,
            "sha256": sha256(path),
            "content_role": role_for(relative),
        }
        mime = mime_for(relative)
        if mime:
            item["content_type"] = mime
        files.append(item)
        total += size
    largest = max(files, key=lambda value: value["size_bytes"], default=None)
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "fixture_id": args.fixture_id,
        "game_id": None,
        "target": REQUIRED_TARGET,
        "godot_version": args.godot_version,
        "renderer": REQUIRED_RENDERER,
        "threaded": False,
        "entrypoint": args.entrypoint,
        "created_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "source_commit": args.source_commit or None,
        "source_fingerprint": args.source_fingerprint,
        "export_preset": args.preset,
        "bundle_file_count": len(files),
        "bundle_total_bytes": total,
        "largest_file": ({"path": largest["path"], "size_bytes": largest["size_bytes"]} if largest else None),
        "files": files,
    }
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return manifest


class ReferenceParser(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.references: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        for key, value in attrs:
            if key in {"src", "href"} and value:
                self.references.append(value)


def verify_manifest(manifest_path: Path, bundle: Path, max_file: int | None, max_bundle: int | None) -> tuple[dict[str, Any], int]:
    errors: list[str] = []
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return {"status": "fail", "manifest": str(manifest_path), "bundle": str(bundle), "errors": [f"manifest parse failed: {error}"]}, 1
    if not isinstance(manifest, dict):
        return {"status": "fail", "manifest": str(manifest_path), "bundle": str(bundle), "errors": ["manifest root must be an object"]}, 1
    if manifest.get("schema_version") != SCHEMA_VERSION:
        errors.append("unsupported schema_version")
    if manifest.get("target") != REQUIRED_TARGET:
        errors.append("manifest target must be web")
    if manifest.get("renderer") != REQUIRED_RENDERER:
        errors.append("manifest renderer must be gl_compatibility")
    if manifest.get("threaded") is not False:
        errors.append("manifest must identify a single-threaded release")
    entrypoint = safe_relative(manifest.get("entrypoint"))
    if entrypoint is None:
        errors.append("manifest entrypoint path is unsafe")

    raw_files = manifest.get("files")
    if not isinstance(raw_files, list) or not raw_files:
        errors.append("manifest files must be a non-empty array")
        raw_files = []
    bundle_root = bundle.resolve(strict=False)
    if not bundle.is_dir() or bundle.is_symlink():
        errors.append("bundle root is missing, not a directory, or a symlink")
    manifest_paths: set[str] = set()
    roles: set[str] = set()
    verified_total = 0
    largest_size = -1
    largest_path = ""
    for index, item in enumerate(raw_files):
        if not isinstance(item, dict):
            errors.append(f"file entry {index} is not an object")
            continue
        relative = safe_relative(item.get("path"))
        if relative is None:
            errors.append(f"file entry {index} has an unsafe path")
            continue
        if relative in manifest_paths:
            errors.append(f"duplicate manifest path: {relative}")
            continue
        manifest_paths.add(relative)
        role = item.get("content_role")
        if isinstance(role, str):
            roles.add(role)
        path = bundle / relative
        try:
            if path.is_symlink() or not path.is_file():
                errors.append(f"manifest file is missing or is a symlink: {relative}")
                continue
            resolved = path.resolve(strict=True)
            if resolved != bundle_root and bundle_root not in resolved.parents:
                errors.append(f"manifest file escapes bundle root: {relative}")
                continue
            size = path.stat().st_size
            verified_total += size
            if size > largest_size:
                largest_size, largest_path = size, relative
            if not isinstance(item.get("size_bytes"), int) or item["size_bytes"] != size:
                errors.append(f"size mismatch: {relative}")
            expected_hash = item.get("sha256")
            if not isinstance(expected_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_hash) or expected_hash != sha256(path):
                errors.append(f"SHA-256 mismatch: {relative}")
            if max_file is not None and size > max_file:
                errors.append(f"file exceeds configured max_file_bytes: {relative}")
        except OSError as error:
            errors.append(f"could not inspect {relative}: {error}")

    try:
        actual_paths = {path.relative_to(bundle).as_posix() for path in bundle_files(bundle)} if bundle.is_dir() else set()
        missing = sorted(manifest_paths - actual_paths)
        unexpected = sorted(actual_paths - manifest_paths)
        if missing:
            errors.append("missing bundle files: " + ", ".join(missing))
        if unexpected:
            errors.append("unmanifested bundle files: " + ", ".join(unexpected))
    except (OSError, ValueError) as error:
        errors.append(str(error))

    if manifest.get("bundle_file_count") != len(manifest_paths):
        errors.append("bundle_file_count mismatch")
    if manifest.get("bundle_total_bytes") != verified_total:
        errors.append("bundle_total_bytes mismatch")
    if max_bundle is not None and verified_total > max_bundle:
        errors.append("bundle exceeds configured max_bundle_bytes")
    expected_largest = {"path": largest_path, "size_bytes": largest_size} if largest_size >= 0 else None
    if manifest.get("largest_file") != expected_largest:
        errors.append("largest_file inventory mismatch")
    for required in {"entry_html", "wasm", "javascript", "game_data"}:
        if required not in roles:
            errors.append(f"required bundle role is missing: {required}")
    if entrypoint and entrypoint not in manifest_paths:
        errors.append("entrypoint is not inventoried")

    local_refs: list[str] = []
    if entrypoint:
        html_path = bundle / entrypoint
        try:
            html_text = html_path.read_text(encoding="utf-8")
            parser = ReferenceParser()
            parser.feed(html_text)
            refs = parser.references + LOCAL_FILE_PATTERN.findall(html_text)
            for ref in refs:
                if ref.startswith(("http://", "https://", "//")):
                    errors.append(f"external bundle dependency is forbidden: {ref}")
                    continue
                if ref.startswith(("data:", "#")):
                    continue
                ref_path = ref.split("?", 1)[0].split("#", 1)[0]
                safe = safe_relative(ref_path)
                if safe is None:
                    errors.append(f"entrypoint contains unsafe local reference: {ref}")
                elif safe not in manifest_paths:
                    errors.append(f"entrypoint local reference is missing: {safe}")
                else:
                    local_refs.append(safe)
            if not re.search(r"const\s+GODOT_THREADS_ENABLED\s*=\s*false\s*;", html_text):
                errors.append("entrypoint does not prove GODOT_THREADS_ENABLED=false")
        except (OSError, UnicodeDecodeError) as error:
            errors.append(f"entrypoint could not be inspected: {error}")

    result = {
        "status": "pass" if not errors else "fail",
        "manifest": str(manifest_path.resolve(strict=False)),
        "bundle": str(bundle_root),
        "target": manifest.get("target"),
        "entrypoint": entrypoint,
        "file_count": len(manifest_paths),
        "total_bytes": verified_total,
        "largest_file": expected_largest,
        "required_roles": sorted(roles),
        "local_references_verified": sorted(set(local_refs)),
        "hash_algorithm": "sha256",
        "errors": errors,
        "browser_runtime_acceptance": "not_tested",
    }
    return result, 0 if not errors else 1


def compare_manifests(first_path: Path, second_path: Path) -> tuple[dict[str, Any], int]:
    first = json.loads(first_path.read_text(encoding="utf-8"))
    second = json.loads(second_path.read_text(encoding="utf-8"))
    first_files = {item["path"]: item for item in first.get("files", [])}
    second_files = {item["path"]: item for item in second.get("files", [])}
    file_set_equal = set(first_files) == set(second_files)
    sizes_equal = file_set_equal and all(first_files[path].get("size_bytes") == second_files[path].get("size_bytes") for path in first_files)
    hashes_equal = file_set_equal and all(first_files[path].get("sha256") == second_files[path].get("sha256") for path in first_files)
    structure_equal = all(first.get(key) == second.get(key) for key in (
        "schema_version", "fixture_id", "target", "godot_version", "renderer", "threaded",
        "entrypoint", "source_fingerprint", "export_preset", "bundle_file_count", "bundle_total_bytes",
    )) and file_set_equal and sizes_equal
    changed = sorted(path for path in set(first_files) & set(second_files) if first_files[path].get("sha256") != second_files[path].get("sha256"))
    result = {
        "status": "pass" if structure_equal else "fail",
        "structurally_equivalent": structure_equal,
        "byte_identical": hashes_equal,
        "file_set_equal": file_set_equal,
        "sizes_equal": sizes_equal,
        "hashes_equal": hashes_equal,
        "changed_files": changed,
        "ignored_manifest_fields": ["created_at"],
    }
    return result, 0 if structure_equal else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    validate = sub.add_parser("validate-project")
    validate.add_argument("project", type=Path)
    validate.add_argument("--preset", default="Game Foundry Web")
    fingerprint = sub.add_parser("fingerprint")
    fingerprint.add_argument("project", type=Path)
    create = sub.add_parser("create-manifest")
    create.add_argument("manifest", type=Path)
    create.add_argument("bundle", type=Path)
    create.add_argument("--fixture-id", required=True)
    create.add_argument("--godot-version", required=True)
    create.add_argument("--source-fingerprint", required=True)
    create.add_argument("--source-commit", default="")
    create.add_argument("--preset", default="Game Foundry Web")
    create.add_argument("--entrypoint", default="index.html")
    verify = sub.add_parser("verify")
    verify.add_argument("manifest", type=Path)
    verify.add_argument("bundle", type=Path)
    verify.add_argument("--max-file-bytes", type=int)
    verify.add_argument("--max-bundle-bytes", type=int)
    compare = sub.add_parser("compare")
    compare.add_argument("first", type=Path)
    compare.add_argument("second", type=Path)
    args = parser.parse_args()

    try:
        if args.command == "validate-project":
            result = validate_project(args.project, args.preset)
            emit(result)
            return 0 if result["status"] == "pass" else 1
        if args.command == "fingerprint":
            digest, count = source_fingerprint(args.project)
            emit({"status": "pass", "source_fingerprint": digest, "source_entry_count": count})
            return 0
        if args.command == "create-manifest":
            result = create_manifest(args)
            emit({"status": "pass", "manifest": str(args.manifest), "file_count": result["bundle_file_count"], "total_bytes": result["bundle_total_bytes"]})
            return 0
        if args.command == "verify":
            result, code = verify_manifest(args.manifest, args.bundle, args.max_file_bytes, args.max_bundle_bytes)
            emit(result)
            return code
        result, code = compare_manifests(args.first, args.second)
        emit(result)
        return code
    except (OSError, ValueError, json.JSONDecodeError, subprocess.SubprocessError) as error:
        emit({"status": "fail", "error": str(error)})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
