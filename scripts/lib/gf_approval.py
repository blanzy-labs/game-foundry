#!/usr/bin/env python3
"""Candidate-bound human approval, adoption, integration, and reconciliation."""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from typing import Any


STATES = {
    "PENDING_HUMAN", "APPROVED", "INTEGRATION_PRECHECK", "INTEGRATING",
    "INTEGRATION_VALIDATING", "PUSHING", "REMOTE_VERIFYING", "INTEGRATED",
    "INTEGRATION_FAILED", "HUMAN_REQUIRED", "REVOKED",
}


class ApprovalError(Exception):
    def __init__(self, message: str, failure_class: str = "INVALID_APPROVAL", human: bool = True):
        super().__init__(message)
        self.failure_class = failure_class
        self.human = human


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def run(args: list[str], cwd: pathlib.Path, *, check: bool = True, env: dict[str, str] | None = None, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    merged = os.environ.copy()
    if env:
        merged.update(env)
    result = subprocess.run(args, cwd=cwd, env=merged, input=input_text, text=True, capture_output=True)
    if check and result.returncode != 0:
        raise ApprovalError(f"command failed: {' '.join(args)}: {(result.stderr or result.stdout).strip()}", "GIT_OPERATION_FAILED")
    return result


def git(repo: pathlib.Path, *args: str, check: bool = True, env: dict[str, str] | None = None, input_text: str | None = None) -> str:
    return run(["git", *args], repo, check=check, env=env, input_text=input_text).stdout.strip()


def atomic_json(path: pathlib.Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def atomic_text(path: pathlib.Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    temporary.write_text(value, encoding="utf-8")
    os.replace(temporary, path)


def atomic_bytes(path: pathlib.Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    temporary.write_bytes(value)
    os.replace(temporary, path)


def control_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[2]


def state_root() -> pathlib.Path:
    return pathlib.Path(os.environ.get("GF_APPROVAL_STATE_ROOT", control_root() / "state" / "approvals")).resolve()


def artifact_root() -> pathlib.Path:
    return pathlib.Path(os.environ.get("GF_APPROVAL_ARTIFACT_ROOT", control_root() / "artifacts" / "approvals")).resolve()


def milestone_root() -> pathlib.Path:
    return pathlib.Path(os.environ.get("GF_MILESTONE_STATE_ROOT", control_root() / "state")).resolve()


def policy_path() -> pathlib.Path:
    return pathlib.Path(os.environ.get("GF_APPROVAL_POLICY_CONFIG", control_root() / "config" / "integration.json")).resolve()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def milestone_state_path(milestone_id: str) -> pathlib.Path:
    if not milestone_id or any(character not in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-" for character in milestone_id):
        raise ApprovalError("unsafe milestone id", "MILESTONE_GATE_INVALID")
    return milestone_root() / milestone_id / "state.json"


def snapshot_milestone_gates(manifest: dict[str, Any]) -> list[dict[str, Any]]:
    snapshots = []
    for gate in manifest.get("milestone_gates", []):
        milestone_id = gate.get("milestone_id")
        path = milestone_state_path(milestone_id)
        if not path.is_file() or path.is_symlink():
            raise ApprovalError(f"milestone gate state unavailable: {milestone_id}", "MILESTONE_GATE_INVALID")
        value = json.loads(path.read_text(encoding="utf-8"))
        task_ids = sorted(gate.get("task_ids", []))
        if value.get("milestone_id") != milestone_id or value.get("completion_gate") != "human_review" or value.get("status") != "pending_human" or value.get("human_gate_satisfaction") or not task_ids:
            raise ApprovalError(f"milestone is not at its human gate: {milestone_id}", "MILESTONE_GATE_INVALID")
        if any(value.get("tasks", {}).get(task_id, {}).get("status") != "pass" for task_id in task_ids):
            raise ApprovalError(f"milestone tasks are not all accepted: {milestone_id}", "MILESTONE_GATE_INVALID")
        snapshots.append({"milestone_id": milestone_id, "task_ids": task_ids, "state_path": str(path), "state_sha256": sha256_file(path)})
    return snapshots


@contextmanager
def transaction_locks(approval_id: str, target_key: str | None = None):
    lock_root = state_root() / ".locks"
    lock_root.mkdir(parents=True, exist_ok=True)
    names = [f"approval-{approval_id}"]
    if target_key:
        names.append(f"target-{hashlib.sha256(target_key.encode()).hexdigest()}")
    handles = []
    try:
        for name in sorted(names):
            handle = (lock_root / f"{name}.lock").open("a+")
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                handle.close()
                raise ApprovalError("approval or integration target is busy", "TRANSACTION_BUSY", human=False) from exc
            handles.append(handle)
        yield
    finally:
        for handle in reversed(handles):
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            handle.close()


def record_path(approval_id: str) -> pathlib.Path:
    if not approval_id or any(character not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_" for character in approval_id):
        raise ApprovalError("unsafe approval id")
    return state_root() / f"{approval_id}.json"


def load_record(approval_id: str) -> dict[str, Any]:
    path = record_path(approval_id)
    if not path.is_file() or path.is_symlink():
        raise ApprovalError(f"approval record not found: {approval_id}", "MISSING_APPROVAL")
    value = json.loads(path.read_text(encoding="utf-8"))
    if value.get("schema_version") != 1 or value.get("approval_id") != approval_id or value.get("integration_status") not in STATES:
        raise ApprovalError("approval record is corrupt", "CORRUPT_APPROVAL")
    return value


def save_record(record: dict[str, Any], checkpoint: str | None = None) -> None:
    if checkpoint:
        record.setdefault("checkpoints", []).append({"name": checkpoint, "at": now()})
    record["updated_at"] = now()
    atomic_json(record_path(record["approval_id"]), record)


def status_paths(repo: pathlib.Path) -> list[str]:
    output = run(["git", "status", "--porcelain=v1", "--untracked-files=all", "-z"], repo).stdout
    if not output:
        return []
    entries = output.split("\0")
    paths: list[str] = []
    index = 0
    while index < len(entries):
        entry = entries[index]
        if not entry:
            break
        paths.append(entry[3:])
        if entry[:2] in {"R ", "C ", "RM", "CM"}:
            index += 1
            if index < len(entries) and entries[index]:
                paths.append(entries[index])
        index += 1
    return sorted(set(paths))


def safe_path(repo: pathlib.Path, relative: str) -> pathlib.Path:
    if not relative or relative.startswith("/") or ".." in pathlib.PurePosixPath(relative).parts:
        raise ApprovalError(f"unsafe candidate path: {relative}", "ADOPTION_AMBIGUITY")
    target = repo / relative
    if target.is_symlink():
        raise ApprovalError(f"candidate symlink rejected: {relative}", "ADOPTION_AMBIGUITY")
    return target


def path_identity(repo: pathlib.Path, relative: str) -> str:
    target = safe_path(repo, relative)
    if not target.exists():
        return "absent"
    if not target.is_file():
        raise ApprovalError(f"candidate path is not a file: {relative}", "ADOPTION_AMBIGUITY")
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    return f"file:{target.stat().st_mode & 0o777:o}:{digest}"


def workspace_fingerprint(repo: pathlib.Path, paths: list[str], base_sha: str) -> tuple[str, dict[str, str]]:
    identities = {path: path_identity(repo, path) for path in sorted(paths)}
    canonical = json.dumps({"paths": identities}, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(canonical).hexdigest(), identities


def evidence_file(repo: pathlib.Path, value: str | None) -> pathlib.Path:
    path = pathlib.Path(value or "")
    if not path.is_absolute():
        path = repo / path
    return path.resolve()


def validate_evidence(repo: pathlib.Path, units: list[dict[str, Any]], candidates: list[dict[str, Any]], approval_type: str, bindings: list[dict[str, Any]], approval_id: str) -> list[dict[str, Any]]:
    if not units:
        raise ApprovalError("approval bundle has no units")
    binding_by_unit = {item.get("unit_id"): item for item in bindings}
    if sorted(binding_by_unit) != sorted(unit.get("id") for unit in units):
        raise ApprovalError("evidence bindings do not exactly cover bundle units", "EVIDENCE_MISMATCH")
    snapshots = []
    snapshot_root = artifact_root() / approval_id / "bound-evidence"
    for index, unit in enumerate(units, 1):
        binding = binding_by_unit[unit.get("id")]
        evidence = unit.get("validation_evidence")
        if not evidence:
            raise ApprovalError(f"validation evidence missing for {unit.get('id')}")
        evidence_path = evidence_file(repo, evidence)
        if not evidence_path.is_file() or evidence_path.is_symlink():
            raise ApprovalError(f"validation evidence unavailable for {unit.get('id')}")
        value = json.loads(evidence_path.read_text(encoding="utf-8"))
        if value.get("status") not in {"pass", "pass_with_warnings"}:
            raise ApprovalError(f"validation did not pass for {unit.get('id')}")
        if binding.get("validation_sha256") != sha256_file(evidence_path):
            raise ApprovalError(f"trusted validation digest mismatch for {unit.get('id')}", "EVIDENCE_MISMATCH")
        if value.get("unit_id", value.get("slice")) != unit.get("id"):
            raise ApprovalError(f"validation evidence is not bound to unit {unit.get('id')}", "EVIDENCE_MISMATCH")
        owned_candidates = [candidate for candidate in candidates if unit.get("id") in candidate.get("unit_ids", [])]
        if approval_type == "candidate_bundle":
            declared = value.get("candidate_sha")
            expected = owned_candidates[-1]["sha"] if len(owned_candidates) == 1 else [item["sha"] for item in owned_candidates]
            if declared != expected:
                raise ApprovalError(f"validation evidence is not bound to candidate for {unit.get('id')}", "EVIDENCE_MISMATCH")
        snapshot = {
            "unit_id": unit.get("id"),
            "validation_path": str(evidence_path),
            "validation_sha256": sha256_file(evidence_path),
            "validation_status": value.get("status"),
            "critic_required": bool(unit.get("critic_required")),
            "candidate_binding": [{"sha": item["sha"], "tree_sha": item["tree_sha"], "paths": item["paths"]} for item in owned_candidates],
        }
        validation_snapshot = snapshot_root / f"{index:03d}-validation.json"
        atomic_bytes(validation_snapshot, evidence_path.read_bytes())
        snapshot["validation_snapshot_path"] = str(validation_snapshot)
        if unit.get("critic_required"):
            critic = unit.get("critic_evidence")
            critic_path = evidence_file(repo, critic)
            if not critic_path.is_file() or critic_path.is_symlink():
                raise ApprovalError(f"critic PASS evidence missing for {unit.get('id')}")
            critic_value = json.loads(critic_path.read_text(encoding="utf-8"))
            decision = str(critic_value.get("decision", critic_value.get("verdict", ""))).lower()
            if decision != "pass":
                raise ApprovalError(f"critic PASS evidence missing for {unit.get('id')}")
            if binding.get("critic_sha256") != sha256_file(critic_path):
                raise ApprovalError(f"trusted critic digest mismatch for {unit.get('id')}", "EVIDENCE_MISMATCH")
            critic_snapshot = snapshot_root / f"{index:03d}-critic.json"
            atomic_bytes(critic_snapshot, critic_path.read_bytes())
            snapshot.update({"critic_path": str(critic_path), "critic_snapshot_path": str(critic_snapshot), "critic_sha256": sha256_file(critic_path), "critic_decision": decision})
        snapshots.append(snapshot)
    return snapshots


def verify_evidence_binding(record: dict[str, Any], *, allow_preserved: bool = False) -> None:
    for snapshot in record.get("evidence_snapshots", []):
        preserved_validation = pathlib.Path(snapshot["validation_snapshot_path"])
        if not preserved_validation.is_file() or preserved_validation.is_symlink() or sha256_file(preserved_validation) != snapshot["validation_sha256"]:
            raise ApprovalError(f"preserved validation evidence changed for {snapshot['unit_id']}", "EVIDENCE_CHANGED")
        validation = pathlib.Path(snapshot["validation_path"])
        if not allow_preserved and (not validation.is_file() or validation.is_symlink() or sha256_file(validation) != snapshot["validation_sha256"]):
            raise ApprovalError(f"validation evidence changed for {snapshot['unit_id']}", "EVIDENCE_CHANGED")
        value = json.loads(preserved_validation.read_text(encoding="utf-8"))
        if value.get("status") != snapshot["validation_status"] or value.get("status") not in {"pass", "pass_with_warnings"}:
            raise ApprovalError(f"validation evidence no longer passes for {snapshot['unit_id']}", "EVIDENCE_CHANGED")
        expected_binding = [{"sha": item["sha"], "tree_sha": item["tree_sha"], "paths": item["paths"]} for item in record["candidate_commits"] if snapshot["unit_id"] in item.get("unit_ids", [])]
        if snapshot.get("candidate_binding") != expected_binding:
            raise ApprovalError(f"candidate/evidence binding changed for {snapshot['unit_id']}", "EVIDENCE_CHANGED")
        if snapshot.get("critic_required"):
            preserved_critic = pathlib.Path(snapshot["critic_snapshot_path"])
            if not preserved_critic.is_file() or preserved_critic.is_symlink() or sha256_file(preserved_critic) != snapshot["critic_sha256"]:
                raise ApprovalError(f"preserved critic evidence changed for {snapshot['unit_id']}", "EVIDENCE_CHANGED")
            critic = pathlib.Path(snapshot["critic_path"])
            if not allow_preserved and (not critic.is_file() or critic.is_symlink() or sha256_file(critic) != snapshot["critic_sha256"]):
                raise ApprovalError(f"critic evidence changed for {snapshot['unit_id']}", "EVIDENCE_CHANGED")
            critic_value = json.loads(preserved_critic.read_text(encoding="utf-8"))
            if str(critic_value.get("decision", critic_value.get("verdict", ""))).lower() != "pass":
                raise ApprovalError(f"critic evidence no longer passes for {snapshot['unit_id']}", "EVIDENCE_CHANGED")


def load_policy(project_id: str, repo: pathlib.Path) -> dict[str, Any]:
    path = policy_path()
    if not path.is_file() or path.is_symlink():
        raise ApprovalError("trusted integration policy is unavailable", "INTEGRATION_POLICY_INVALID")
    config = json.loads(path.read_text(encoding="utf-8"))
    policy = config.get("repositories", {}).get(project_id)
    if not isinstance(policy, dict):
        raise ApprovalError(f"no trusted integration policy for {project_id}", "INTEGRATION_POLICY_INVALID")
    configured_repo = pathlib.Path(policy.get("repository", ""))
    if not configured_repo.is_absolute():
        configured_repo = (path.parent.parent / configured_repo).resolve()
    if configured_repo != repo:
        raise ApprovalError("manifest repository does not match trusted policy", "INTEGRATION_POLICY_MISMATCH")
    required = {"remote", "target_branch", "mode", "allow_force_push", "verify_remote", "validation_commands"}
    if required - set(policy) or policy.get("allow_force_push") is not False or policy.get("verify_remote") is not True:
        raise ApprovalError("trusted integration policy is incomplete or unsafe", "INTEGRATION_POLICY_INVALID")
    if policy.get("validation_dependency_mode", "none") not in {"none", "shared_locked_node_modules"}:
        raise ApprovalError("trusted validation dependency mode is invalid", "INTEGRATION_POLICY_INVALID")
    return policy


def enforce_policy(manifest: dict[str, Any], repo: pathlib.Path, manifest_path: pathlib.Path, *, classification_only: bool = False) -> tuple[dict[str, Any], list[list[str]], str, str]:
    policy = load_policy(manifest["project_id"], repo)
    resolved_manifest = manifest_path.resolve()
    roots = []
    for value in policy.get("manifest_roots", []):
        root = pathlib.Path(value)
        roots.append(root.resolve() if root.is_absolute() else (repo / root).resolve())
    if not roots or not any(resolved_manifest == root or root in resolved_manifest.parents for root in roots):
        raise ApprovalError("approval manifest is outside trusted policy roots", "INTEGRATION_POLICY_MISMATCH")
    if not classification_only and not policy.get("allow_untracked_manifests_for_fixtures", False):
        relative = str(resolved_manifest.relative_to(repo))
        if run(["git", "ls-files", "--error-unmatch", "--", relative], repo, check=False).returncode != 0 or run(["git", "diff", "--quiet", "HEAD", "--", relative], repo, check=False).returncode != 0:
            raise ApprovalError("approval manifest must be tracked and unchanged from HEAD", "INTEGRATION_POLICY_MISMATCH")
    integration = manifest["integration"]
    for key in ("remote", "target_branch"):
        if manifest.get(key) != policy.get(key):
            raise ApprovalError(f"manifest {key} does not match trusted policy", "INTEGRATION_POLICY_MISMATCH")
    for key in ("mode", "allow_force_push", "verify_remote"):
        if integration.get(key) != policy.get(key):
            raise ApprovalError(f"manifest integration.{key} does not match trusted policy", "INTEGRATION_POLICY_MISMATCH")
    for key in ("pr_adapter", "github_repository", "external_reviewer_required", "merge_method", "required_checks", "require_strict_base_checks"):
        if key in integration and integration.get(key) != policy.get(key):
            raise ApprovalError(f"manifest integration.{key} does not match trusted policy", "INTEGRATION_POLICY_MISMATCH")
    if manifest["validation_commands"] != policy["validation_commands"]:
        raise ApprovalError("manifest validation commands do not match trusted policy", "INTEGRATION_POLICY_MISMATCH")
    expected_url = policy.get("remote_url")
    expected_push_url = policy.get("push_url")
    if not expected_url or not expected_push_url:
        raise ApprovalError("trusted fetch and push remote identities are required", "INTEGRATION_POLICY_INVALID")
    remote_url = git(repo, "remote", "get-url", policy["remote"])
    push_url = git(repo, "remote", "get-url", "--push", policy["remote"])
    if remote_url != expected_url or push_url != expected_push_url:
        raise ApprovalError("configured fetch/push remote identity does not match trusted policy", "INTEGRATION_POLICY_MISMATCH")
    normalized = {key: policy[key] for key in policy if key not in {"repository", "manifest_roots", "allow_untracked_manifests_for_fixtures", "remote", "target_branch", "validation_commands", "remote_url"}}
    normalized.pop("push_url", None)
    return normalized, policy["validation_commands"], expected_url, expected_push_url


def verify_remote_identity(record: dict[str, Any]) -> None:
    repo = pathlib.Path(record["repository"])
    fetch_url = git(repo, "remote", "get-url", record["remote"])
    push_url = git(repo, "remote", "get-url", "--push", record["remote"])
    if fetch_url != record["remote_url"] or push_url != record["push_url"]:
        raise ApprovalError("remote fetch/push identity changed after approval bundle creation", "REMOTE_IDENTITY_CHANGED")


def create_adoption_commits(repo: pathlib.Path, approval_id: str, base_sha: str, groups: list[dict[str, Any]], approved_at_seed: str) -> list[dict[str, Any]]:
    parent = base_sha
    created: list[dict[str, Any]] = []
    for index, group in enumerate(groups, 1):
        paths = sorted(group.get("paths", []))
        if not paths:
            raise ApprovalError("adoption group has no paths")
        with tempfile.TemporaryDirectory(prefix="gf010-index-") as temporary:
            index_path = pathlib.Path(temporary) / "index"
            env = {"GIT_INDEX_FILE": str(index_path)}
            git(repo, "read-tree", parent, env=env)
            for relative in paths:
                target = safe_path(repo, relative)
                if target.exists():
                    git(repo, "add", "--", relative, env=env)
                else:
                    git(repo, "rm", "--cached", "--ignore-unmatch", "--", relative, env=env)
            tree = git(repo, "write-tree", env=env)
        commit_env = {
            "GIT_AUTHOR_NAME": "Game Foundry",
            "GIT_AUTHOR_EMAIL": "game-foundry@local.invalid",
            "GIT_COMMITTER_NAME": "Game Foundry",
            "GIT_COMMITTER_EMAIL": "game-foundry@local.invalid",
            "GIT_AUTHOR_DATE": approved_at_seed,
            "GIT_COMMITTER_DATE": approved_at_seed,
        }
        message = group.get("commit_message") or group.get("id") or approval_id
        body = f"{message}\n\nApproval-Bundle: {approval_id}\n"
        commit = git(repo, "commit-tree", tree, "-p", parent, env=commit_env, input_text=body)
        ref = f"refs/gf/approvals/{approval_id}/{index:02d}"
        git(repo, "update-ref", ref, commit)
        created.append({"unit_ids": group.get("unit_ids", []), "sha": commit, "tree_sha": tree, "parent_sha": parent, "message": message, "paths": paths, "preservation_ref": ref})
        parent = commit
    return created


def commit_paths(repo: pathlib.Path, sha: str) -> list[str]:
    return sorted(filter(None, git(repo, "diff-tree", "--no-commit-id", "--name-only", "-r", sha).splitlines()))


def normalize_candidates(repo: pathlib.Path, base_sha: str, candidates: list[dict[str, Any]], unit_ids: list[str]) -> tuple[list[dict[str, Any]], str, list[str]]:
    if not candidates:
        raise ApprovalError("candidate approval requires candidate commits")
    parent = base_sha
    covered: list[str] = []
    normalized = []
    for candidate in candidates:
        sha = candidate.get("sha")
        git(repo, "cat-file", "-e", f"{sha}^{{commit}}")
        actual_parent = git(repo, "rev-parse", f"{sha}^")
        if actual_parent != parent:
            raise ApprovalError("candidate commit order/base is not exact", "CANDIDATE_MISMATCH")
        tree = git(repo, "rev-parse", f"{sha}^{{tree}}")
        if candidate.get("tree_sha") not in {None, tree}:
            raise ApprovalError("candidate tree does not match", "CANDIDATE_MISMATCH")
        paths = commit_paths(repo, sha)
        declared_paths = sorted(candidate.get("paths", paths))
        if declared_paths != paths:
            raise ApprovalError("candidate path ownership does not match commit", "CANDIDATE_MISMATCH")
        mapped_units = candidate.get("unit_ids") or ([unit_ids[len(normalized)]] if len(candidates) == len(unit_ids) else unit_ids)
        if not mapped_units or any(unit not in unit_ids for unit in mapped_units):
            raise ApprovalError("candidate unit ownership is invalid", "CANDIDATE_MISMATCH")
        covered.extend(mapped_units)
        normalized.append({**candidate, "sha": sha, "tree_sha": tree, "parent_sha": parent, "paths": paths, "unit_ids": mapped_units})
        parent = sha
    if sorted(set(covered)) != sorted(set(unit_ids)):
        raise ApprovalError("candidate commits do not cover every bundle unit", "CANDIDATE_MISMATCH")
    allowed = sorted({path for candidate in normalized for path in candidate["paths"]})
    fingerprint = canonical_digest([{"sha": item["sha"], "tree_sha": item["tree_sha"], "parent_sha": item["parent_sha"], "paths": item["paths"], "unit_ids": item["unit_ids"]} for item in normalized])
    return normalized, fingerprint, allowed


def validate_manifest(value: dict[str, Any]) -> None:
    required = {"schema_version", "approval_id", "approval_type", "project_id", "repository", "units", "evidence_bindings", "remote", "target_branch", "integration", "validation_commands"}
    missing = sorted(required - set(value))
    if missing or value.get("schema_version") != 1:
        raise ApprovalError(f"approval manifest invalid; missing={missing}")
    if value["integration"].get("allow_force_push") is not False:
        raise ApprovalError("force push must be explicitly forbidden", "FORCE_PUSH_FORBIDDEN")
    if value["integration"].get("mode") not in {"direct", "pull_request"}:
        raise ApprovalError("integration mode must be direct or pull_request")
    if value.get("approval_type") == "adoption_bundle" and not value.get("candidate_patch_sha256"):
        raise ApprovalError("adoption manifest requires exact candidate fingerprint", "CANDIDATE_MISMATCH")
    for command in value["validation_commands"]:
        if not isinstance(command, list) or not command or not all(isinstance(part, str) and part for part in command):
            raise ApprovalError("validation commands must be nonempty argv arrays")


def create_manifest(manifest_path: pathlib.Path) -> dict[str, Any]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    validate_manifest(manifest)
    approval_id = manifest["approval_id"]
    path = record_path(approval_id)
    if path.exists():
        existing = load_record(approval_id)
        print(json.dumps(existing, indent=2))
        return existing
    repo = pathlib.Path(manifest["repository"]).resolve()
    if git(repo, "rev-parse", "--show-toplevel") != str(repo):
        raise ApprovalError("repository path must be the Git root")
    trusted_integration, trusted_validation, trusted_remote_url, trusted_push_url = enforce_policy(manifest, repo, manifest_path)
    base_sha = manifest.get("base_sha") or git(repo, "rev-parse", "HEAD")
    git(repo, "cat-file", "-e", f"{base_sha}^{{commit}}")
    created_at = now()
    candidates = manifest.get("candidate_commits", [])
    allowed: list[str] = []
    identities: dict[str, str] = {}
    fingerprint = None
    classification: dict[str, Any] | None = None
    if manifest["approval_type"] == "adoption_bundle":
        groups = manifest.get("adoption", {}).get("groups", [])
        allowed = sorted({path for group in groups for path in group.get("paths", [])})
        dirty = status_paths(repo)
        unexpected = sorted(set(dirty) - set(allowed))
        missing_dirty = sorted(set(allowed) - set(dirty))
        expected = sorted(set(dirty) & set(allowed))
        classification = {
            "expected_slice_work": [path for path in expected if not path.endswith(".gd.uid") and not path.startswith("reports/")],
            "expected_generated_metadata": [path for path in expected if path.endswith(".gd.uid")],
            "acceptance_evidence": [path for path in expected if path.startswith("reports/")],
            "unrelated": unexpected,
            "ambiguous": missing_dirty,
            "status": "pass" if not unexpected and not missing_dirty else "reject",
        }
        if unexpected or missing_dirty:
            raise ApprovalError(f"adoption rejected; unrelated={unexpected}; ambiguous={missing_dirty}", "ADOPTION_AMBIGUITY")
        fingerprint, identities = workspace_fingerprint(repo, allowed, base_sha)
        if manifest.get("candidate_patch_sha256") != fingerprint:
            raise ApprovalError("adoption manifest is not bound to the exact workspace fingerprint", "CANDIDATE_MISMATCH")
        candidates = create_adoption_commits(repo, approval_id, base_sha, groups, created_at)
    unit_ids = [unit["id"] for unit in manifest["units"]]
    candidates, commit_fingerprint, committed_paths = normalize_candidates(repo, base_sha, candidates, unit_ids)
    evidence_snapshots = validate_evidence(repo, manifest["units"], candidates, manifest["approval_type"], manifest.get("evidence_bindings", []), approval_id)
    milestone_gates = snapshot_milestone_gates(manifest)
    if len({gate["milestone_id"] for gate in milestone_gates}) != len(milestone_gates) or any(not set(gate["task_ids"]).issubset(set(unit_ids)) for gate in milestone_gates):
        raise ApprovalError("milestone gate mapping is ambiguous or outside the approval bundle", "MILESTONE_GATE_INVALID")
    if manifest["approval_type"] != "adoption_bundle":
        fingerprint = commit_fingerprint
        allowed = committed_paths
    record = {
        "schema_version": 1,
        "approval_id": approval_id,
        "approval_type": manifest["approval_type"],
        "project_id": manifest["project_id"],
        "repository": str(repo),
        "milestone_id": manifest.get("milestone_id"),
        "milestone_gates": milestone_gates,
        "milestone_gate_results": [],
        "task_ids": [unit["id"] for unit in manifest["units"]],
        "bundle_id": manifest.get("bundle_id", approval_id),
        "units": manifest["units"],
        "evidence_snapshots": evidence_snapshots,
        "candidate_commits": candidates,
        "candidate_sha": candidates[-1]["sha"],
        "candidate_tree_sha": candidates[-1]["tree_sha"],
        "candidate_patch_sha256": fingerprint,
        "candidate_path_identities": identities,
        "allowed_files": allowed,
        "base_sha": base_sha,
        "remote": manifest["remote"],
        "remote_url": trusted_remote_url,
        "push_url": trusted_push_url,
        "target_branch": manifest["target_branch"],
        "integration": trusted_integration,
        "validation_commands": trusted_validation,
        "integration_policy_path": str(policy_path()),
        "integration_policy_sha256": sha256_file(policy_path()),
        "validation_status": "pass",
        "validation_evidence": [unit["validation_evidence"] for unit in manifest["units"]],
        "critic_status": "pass" if any(unit.get("critic_required") for unit in manifest["units"]) else "not_required",
        "critic_evidence": [unit.get("critic_evidence") for unit in manifest["units"] if unit.get("critic_evidence")],
        "human_qa_status": "pending",
        "human_qa_artifact": manifest.get("human_qa_artifact"),
        "approval_status": "pending",
        "approved_at": None,
        "approval_source": None,
        "integration_status": "PENDING_HUMAN",
        "integration_started_at": None,
        "integration_finished_at": None,
        "remote_head_before": None,
        "remote_head_after": None,
        "integration_commit": None,
        "pr_number": None,
        "merge_commit": None,
        "integration_tree_sha": None,
        "expected_remote_head": None,
        "worktree_path": None,
        "pr_branch": None,
        "push_outcome": None,
        "failure_class": None,
        "failure_reason": None,
        "human_action_required": True,
        "classification": classification,
        "created_at": created_at,
        "checkpoints": [],
    }
    save_record(record, "APPROVAL_BUNDLE_CREATED")
    print(json.dumps(record, indent=2))
    return record


def verify_immutable_binding(record: dict[str, Any], *, allow_preserved_evidence: bool = False) -> None:
    repo = pathlib.Path(record["repository"])
    verify_remote_identity(record)
    trusted_policy = pathlib.Path(record["integration_policy_path"])
    if not trusted_policy.is_file() or trusted_policy.is_symlink() or sha256_file(trusted_policy) != record["integration_policy_sha256"]:
        raise ApprovalError("trusted integration policy changed after bundle creation", "INTEGRATION_POLICY_CHANGED")
    verify_evidence_binding(record, allow_preserved=allow_preserved_evidence)
    for gate in record.get("milestone_gates", []):
        path = pathlib.Path(gate["state_path"])
        if not path.is_file() or path.is_symlink():
            raise ApprovalError(f"milestone gate disappeared: {gate['milestone_id']}", "MILESTONE_GATE_CHANGED")
        value = json.loads(path.read_text(encoding="utf-8"))
        already_satisfied = value.get("status") == "complete" and value.get("human_gate_satisfaction", {}).get("approval_id") == record["approval_id"]
        if not already_satisfied and sha256_file(path) != gate["state_sha256"]:
            raise ApprovalError(f"milestone gate changed: {gate['milestone_id']}", "MILESTONE_GATE_CHANGED")
    candidates, fingerprint, paths = normalize_candidates(repo, record["base_sha"], record["candidate_commits"], record["task_ids"])
    if candidates != record["candidate_commits"] or paths != sorted(record["allowed_files"]):
        raise ApprovalError("candidate commit binding changed", "CANDIDATE_MISMATCH")
    if record["approval_type"] != "adoption_bundle" and fingerprint != record["candidate_patch_sha256"]:
        raise ApprovalError("candidate bundle fingerprint changed", "CANDIDATE_MISMATCH")


def verify_candidate_binding(record: dict[str, Any]) -> None:
    verify_immutable_binding(record)
    repo = pathlib.Path(record["repository"])
    if record["approval_type"] == "adoption_bundle":
        current, identities = workspace_fingerprint(repo, record["allowed_files"], record["base_sha"])
        if current != record["candidate_patch_sha256"] or identities != record["candidate_path_identities"]:
            raise ApprovalError("candidate changed after approval", "CANDIDATE_CHANGED_AFTER_APPROVAL")
        dirty = status_paths(repo)
        if dirty != sorted(record["allowed_files"]):
            raise ApprovalError("dirty path inventory changed after approval", "ADOPTION_AMBIGUITY")


def set_failure(record: dict[str, Any], error: ApprovalError) -> None:
    record["integration_status"] = "HUMAN_REQUIRED" if error.human else "INTEGRATION_FAILED"
    record["failure_class"] = error.failure_class
    record["failure_reason"] = str(error)
    record["human_action_required"] = error.human
    save_record(record, record["integration_status"])
    write_receipt(record)


def write_receipt(record: dict[str, Any]) -> None:
    finished = record.get("integration_finished_at") or now()
    duration = None
    if record.get("integration_started_at"):
        try:
            start_value = dt.datetime.fromisoformat(record["integration_started_at"].replace("Z", "+00:00"))
            finish_value = dt.datetime.fromisoformat(finished.replace("Z", "+00:00"))
            duration = max(0.0, (finish_value - start_value).total_seconds())
        except ValueError:
            duration = None
    validation_path = artifact_root() / record["approval_id"] / "validation.json"
    remote_path = artifact_root() / record["approval_id"] / "remote-verification.json"
    checkpoints = [item.get("name") for item in record.get("checkpoints", [])]
    receipt = {
        "schema_version": 1,
        "approval_id": record["approval_id"],
        "status": record["integration_status"],
        "approval_status": record["approval_status"],
        "integration_status": record["integration_status"],
        "candidates": record.get("candidate_commits", []),
        "candidate_commits": record.get("candidate_commits", []),
        "base": record.get("base_sha"),
        "integration_head": record.get("integration_commit"),
        "integration_commit": record.get("integration_commit"),
        "integration_method": record.get("integration", {}).get("mode"),
        "merge_commit": record.get("merge_commit"),
        "remote": record.get("remote"),
        "remote_url": record.get("remote_url"),
        "target_branch": record.get("target_branch"),
        "remote_head_before": record.get("remote_head_before"),
        "remote_head_after": record.get("remote_head_after"),
        "validation": {"status": "pass" if "INTEGRATION_VALIDATED" in checkpoints else "not_passed", "evidence": str(validation_path) if validation_path.is_file() else None},
        "push": {"status": record.get("push_outcome") or "not_started", "stdout": str(artifact_root() / record["approval_id"] / "push.stdout") if (artifact_root() / record["approval_id"] / "push.stdout").is_file() else None, "stderr": str(artifact_root() / record["approval_id"] / "push.stderr") if (artifact_root() / record["approval_id"] / "push.stderr").is_file() else None},
        "remote_verification": {"status": "pass" if "REMOTE_VERIFIED" in checkpoints else "not_passed", "expected_head": record.get("expected_remote_head"), "actual_head": record.get("remote_head_after"), "evidence": str(remote_path) if remote_path.is_file() else None},
        "pr_number": record.get("pr_number"),
        "failure_class": record.get("failure_class"),
        "failure_reason": record.get("failure_reason"),
        "cleanup": record.get("cleanup"),
        "milestone_gates": record.get("milestone_gate_results", []),
        "human_action_required": record.get("human_action_required"),
        "duration_seconds": duration,
        "finished_at": finished,
    }
    atomic_json(artifact_root() / record["approval_id"] / "result.json", receipt)


def remote_head(repo: pathlib.Path, remote: str, branch: str) -> str:
    git(repo, "fetch", "--prune", remote)
    return git(repo, "rev-parse", f"refs/remotes/{remote}/{branch}")


def validate_integration(record: dict[str, Any], worktree: pathlib.Path, evidence: pathlib.Path) -> None:
    record["integration_status"] = "INTEGRATION_VALIDATING"
    save_record(record, "INTEGRATION_VALIDATING")
    results = []
    expected_head = record.get("integration_commit")
    expected_tree = record.get("integration_tree_sha")
    if git(worktree, "status", "--porcelain=v1", "--untracked-files=all") or git(worktree, "rev-parse", "HEAD") != expected_head or git(worktree, "rev-parse", "HEAD^{tree}") != expected_tree:
        raise ApprovalError("integration worktree is not the clean expected commit before validation", "INTEGRATION_VALIDATION_SCOPE_FAILED")
    if os.environ.get("GF_GF010_ENABLE_TEST_HOOKS") == "1" and os.environ.get("GF_GF010_FAULT") == "validation_failure":
        raise ApprovalError("controlled post-integration validation failure", "INTEGRATION_VALIDATION_FAILED")
    dependency_link = None
    dependency_evidence = {"mode": record["integration"].get("validation_dependency_mode", "none")}
    if dependency_evidence["mode"] == "shared_locked_node_modules":
        source_repo = pathlib.Path(record["repository"])
        source_lock = source_repo / "package-lock.json"
        worktree_lock = worktree / "package-lock.json"
        source_modules = source_repo / "node_modules"
        dependency_link = worktree / "node_modules"
        if not source_lock.is_file() or source_lock.is_symlink() or not worktree_lock.is_file() or worktree_lock.is_symlink() or sha256_file(source_lock) != sha256_file(worktree_lock):
            raise ApprovalError("shared validation dependencies do not match the integrated lockfile", "INTEGRATION_VALIDATION_DEPENDENCY_INVALID")
        if not source_modules.is_dir() or source_modules.is_symlink() or dependency_link.exists() or dependency_link.is_symlink():
            raise ApprovalError("shared validation dependency directory is unavailable or unsafe", "INTEGRATION_VALIDATION_DEPENDENCY_INVALID")
        dependency_link.symlink_to(source_modules, target_is_directory=True)
        dependency_evidence.update({"package_lock_sha256": sha256_file(worktree_lock), "source": str(source_modules)})
    elif dependency_evidence["mode"] != "none":
        raise ApprovalError("validation dependency mode changed after approval", "INTEGRATION_POLICY_CHANGED")
    try:
        for index, command in enumerate(record["validation_commands"], 1):
            result = run(command, worktree, check=False)
            entry = {"index": index, "argv": command, "exit_code": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
            results.append(entry)
            if result.returncode != 0:
                atomic_json(evidence / "validation.json", {"status": "fail", "dependency": dependency_evidence, "commands": results})
                raise ApprovalError(f"integration validation command {index} failed", "INTEGRATION_VALIDATION_FAILED")
    finally:
        if dependency_link is not None:
            source_modules = pathlib.Path(dependency_evidence["source"])
            if not dependency_link.is_symlink() or dependency_link.resolve() != source_modules.resolve():
                raise ApprovalError("shared validation dependency link changed during validation", "INTEGRATION_VALIDATION_SCOPE_FAILED")
            dependency_link.unlink()
    if os.environ.get("GF_GF010_ENABLE_TEST_HOOKS") == "1" and os.environ.get("GF_GF010_FAULT") == "validation_dirty_worktree":
        (worktree / "base.txt").write_text("validator mutation\n", encoding="utf-8")
    final_status = git(worktree, "status", "--porcelain=v1", "--untracked-files=all")
    final_head = git(worktree, "rev-parse", "HEAD")
    final_tree = git(worktree, "rev-parse", "HEAD^{tree}")
    if final_status or final_head != expected_head or final_tree != expected_tree:
        atomic_json(evidence / "validation.json", {"status": "fail", "failure_class": "INTEGRATION_VALIDATION_SCOPE_FAILED", "worktree_status": final_status, "expected_head": expected_head, "actual_head": final_head, "expected_tree": expected_tree, "actual_tree": final_tree, "commands": results})
        raise ApprovalError("validation changed or dirtied the committed integration tree", "INTEGRATION_VALIDATION_SCOPE_FAILED")
    atomic_json(evidence / "validation.json", {"status": "pass", "dependency": dependency_evidence, "commands": results})


def cleanup_worktree(record: dict[str, Any]) -> bool:
    value = record.get("worktree_path")
    if not value:
        record.setdefault("cleanup", {})["temporary_worktree_removed"] = True
        return True
    path = pathlib.Path(value)
    expected_prefix = f"gf010-{record['approval_id']}-"
    if not path.is_absolute() or not path.name.startswith(expected_prefix) or path == pathlib.Path(record["repository"]):
        raise ApprovalError("persisted worktree path is unsafe", "CLEANUP_FAILED")
    repo = pathlib.Path(record["repository"])
    run(["git", "worktree", "remove", "--force", str(path)], repo, check=False)
    if path.exists():
        shutil.rmtree(path, ignore_errors=True)
    removed = not path.exists()
    record.setdefault("cleanup", {})["temporary_worktree_removed"] = removed
    if removed:
        record["worktree_path"] = None
    return removed


def cleanup_adoption_source(record: dict[str, Any]) -> bool:
    if record["approval_type"] != "adoption_bundle":
        record.setdefault("cleanup", {})["source_worktree_clean"] = not status_paths(pathlib.Path(record["repository"]))
        return record["cleanup"]["source_worktree_clean"]
    repo = pathlib.Path(record["repository"])
    dirty = status_paths(repo)
    if not set(dirty).issubset(set(record["allowed_files"])):
        raise ApprovalError("unrelated source change appeared during adoption cleanup", "ADOPTION_AMBIGUITY")
    for relative in record["allowed_files"]:
        tracked = run(["git", "cat-file", "-e", f"HEAD:{relative}"], repo, check=False).returncode == 0
        if tracked:
            mode_and_blob = git(repo, "ls-tree", "HEAD", "--", relative).split()
            blob = subprocess.run(["git", "cat-file", "blob", f"HEAD:{relative}"], cwd=repo, capture_output=True, check=True).stdout
            baseline = f"file:{int(mode_and_blob[0], 8) & 0o777:o}:{hashlib.sha256(blob).hexdigest()}"
        else:
            baseline = "absent"
        current = path_identity(repo, relative)
        if current not in {record["candidate_path_identities"][relative], baseline}:
            raise ApprovalError(f"adoption source path changed during cleanup: {relative}", "CANDIDATE_CHANGED_AFTER_APPROVAL")
        record.setdefault("adoption_cleanup", {})[relative] = "pending"
        save_record(record, "ADOPTION_CLEANUP_PATH_PENDING")
        if tracked:
            git(repo, "restore", "--source=HEAD", "--staged", "--worktree", "--", relative)
        else:
            target = safe_path(repo, relative)
            if target.exists() and target.is_file():
                target.unlink()
        if os.environ.get("GF_GF010_ENABLE_TEST_HOOKS") == "1" and os.environ.get("GF_GF010_FAULT") == "crash_during_adoption_cleanup" and not record.get("adoption_cleanup_fault_used"):
            record["adoption_cleanup_fault_used"] = True
            os._exit(95)
        record["adoption_cleanup"][relative] = "complete"
        save_record(record, "ADOPTION_CLEANUP_PATH_COMPLETE")
    clean = not status_paths(repo)
    record.setdefault("cleanup", {})["source_worktree_clean"] = clean
    return clean


def cleanup_pr_branch(record: dict[str, Any]) -> bool:
    branch = record.get("pr_branch")
    if not branch:
        record.setdefault("cleanup", {})["temporary_branch_removed"] = True
        return True
    repo = pathlib.Path(record["repository"])
    verify_remote_identity(record)
    reference = f"refs/heads/{branch}"
    observed = run(["git", "ls-remote", "--heads", record["remote"], reference], repo, check=False)
    if observed.returncode != 0:
        raise ApprovalError("temporary PR branch presence is ambiguous", "PR_BRANCH_CLEANUP_AMBIGUOUS")
    lines = [line.split() for line in observed.stdout.splitlines() if line.strip()]
    if len(lines) > 1 or (lines and (len(lines[0]) != 2 or lines[0][1] != reference)):
        raise ApprovalError("temporary PR branch lookup was ambiguous", "PR_BRANCH_CLEANUP_AMBIGUOUS")
    if lines:
        if lines[0][0] != record.get("integration_commit"):
            raise ApprovalError("temporary PR branch contains unexpected work and was preserved", "PR_BRANCH_MOVED")
        deletion = run(["git", "push", f"--force-with-lease={reference}:{record['integration_commit']}", record["remote"], f":{reference}"], repo, check=False)
        if deletion.returncode != 0:
            raise ApprovalError("temporary PR branch deletion result is ambiguous", "PR_BRANCH_CLEANUP_AMBIGUOUS")
    verified = run(["git", "ls-remote", "--heads", record["remote"], reference], repo, check=False)
    if verified.returncode != 0:
        raise ApprovalError("temporary PR branch cleanup could not be verified", "PR_BRANCH_CLEANUP_AMBIGUOUS")
    removed = not bool(verified.stdout.strip())
    record.setdefault("cleanup", {})["temporary_branch_removed"] = removed
    return removed


def ensure_milestone_history(path: pathlib.Path, event: dict[str, Any]) -> None:
    history_path = path.parent / "history.jsonl"
    raw = history_path.read_text(encoding="utf-8") if history_path.is_file() else ""
    entries = []
    try:
        entries = [json.loads(line) for line in raw.splitlines() if line]
    except json.JSONDecodeError as exc:
        raise ApprovalError(f"milestone history is corrupt: {path.parent.name}", "MILESTONE_GATE_CHANGED") from exc
    matches = [entry for entry in entries if entry.get("event_id") == event["event_id"]]
    if len(matches) > 1 or (matches and matches[0] != event):
        raise ApprovalError(f"milestone history conflicts with approval: {path.parent.name}", "MILESTONE_GATE_CHANGED")
    if not matches:
        prefix = raw if not raw or raw.endswith("\n") else raw + "\n"
        atomic_text(history_path, prefix + json.dumps(event, sort_keys=True) + "\n")


def complete_milestone_gates(record: dict[str, Any]) -> None:
    results = []
    for gate in record.get("milestone_gates", []):
        path = pathlib.Path(gate["state_path"])
        lock_path = path.parent / ".state.lock"
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        with lock_path.open("a+") as handle:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise ApprovalError(f"milestone state is busy: {gate['milestone_id']}", "TRANSACTION_BUSY", human=False) from exc
            value = json.loads(path.read_text(encoding="utf-8"))
            existing = value.get("human_gate_satisfaction", {})
            if value.get("status") == "complete" and existing.get("approval_id") == record["approval_id"]:
                event = {"event_id": existing.get("history_event_id"), "timestamp": existing.get("satisfied_at"), "task": None, "from": "pending_human", "to": "complete", "reason": "gf010_human_approval_integration", "approval_id": record["approval_id"], "milestone_id": gate["milestone_id"], "integration_commit": record["integration_commit"]}
                if not event["event_id"]:
                    raise ApprovalError(f"milestone satisfaction provenance is incomplete: {gate['milestone_id']}", "MILESTONE_GATE_CHANGED")
                ensure_milestone_history(path, event)
                results.append({"milestone_id": gate["milestone_id"], "status": "already_satisfied"})
            else:
                if sha256_file(path) != gate["state_sha256"] or value.get("status") != "pending_human" or value.get("completion_gate") != "human_review":
                    raise ApprovalError(f"milestone gate changed before satisfaction: {gate['milestone_id']}", "MILESTONE_GATE_CHANGED")
                if any(value.get("tasks", {}).get(task_id, {}).get("status") != "pass" for task_id in gate["task_ids"]):
                    raise ApprovalError(f"milestone gate tasks no longer pass: {gate['milestone_id']}", "MILESTONE_GATE_CHANGED")
                satisfied_at = now()
                event_id = canonical_digest({"approval_id": record["approval_id"], "milestone_id": gate["milestone_id"], "integration_commit": record["integration_commit"]})
                value["status"] = "complete"
                value["human_gate_satisfaction"] = {"approval_id": record["approval_id"], "bundle_id": record["bundle_id"], "approved_at": record["approved_at"], "satisfied_at": satisfied_at, "integration_commit": record["integration_commit"], "task_ids": gate["task_ids"], "history_event_id": event_id}
                atomic_json(path, value)
                event = {"event_id": event_id, "timestamp": satisfied_at, "task": None, "from": "pending_human", "to": "complete", "reason": "gf010_human_approval_integration", "approval_id": record["approval_id"], "milestone_id": gate["milestone_id"], "integration_commit": record["integration_commit"]}
                if os.environ.get("GF_GF010_ENABLE_TEST_HOOKS") == "1" and os.environ.get("GF_GF010_FAULT") == "crash_after_milestone_state_before_history":
                    os._exit(92)
                ensure_milestone_history(path, event)
                results.append({"milestone_id": gate["milestone_id"], "status": "satisfied"})
                if os.environ.get("GF_GF010_ENABLE_TEST_HOOKS") == "1" and os.environ.get("GF_GF010_FAULT") == "crash_during_milestone_gates" and len(results) == 1:
                    os._exit(93)
        record["milestone_gate_results"] = results
        save_record(record, "MILESTONE_GATE_SATISFIED")


def complete_integration(record: dict[str, Any], head: str) -> None:
    repo = pathlib.Path(record["repository"])
    expected = record.get("expected_remote_head")
    if not expected or head != expected:
        raise ApprovalError("remote target HEAD is not the exact expected result", "REMOTE_MOVED_AFTER_PUSH")
    if git(repo, "rev-parse", f"{head}^{{tree}}") != record.get("integration_tree_sha"):
        raise ApprovalError("remote target tree is not the validated integration tree", "REMOTE_VERIFICATION_FAILED")
    record["remote_head_after"] = head
    record["integration_status"] = "REMOTE_VERIFYING"
    save_record(record, "REMOTE_VERIFIED")
    if not cleanup_worktree(record):
        raise ApprovalError("integration worktree cleanup did not complete", "CLEANUP_FAILED")
    save_record(record, "WORKTREE_CLEANUP_COMPLETE")
    if not cleanup_adoption_source(record) or not cleanup_pr_branch(record):
        raise ApprovalError("integration cleanup did not complete", "CLEANUP_FAILED")
    save_record(record, "CLEANUP_COMPLETE")
    complete_milestone_gates(record)
    record["integration_status"] = "INTEGRATED"
    record["approval_status"] = "integrated"
    record["integration_finished_at"] = now()
    record["human_action_required"] = False
    record["failure_class"] = None
    record["failure_reason"] = None
    record["push_outcome"] = "verified"
    save_record(record, "INTEGRATED")
    write_receipt(record)


def reconcile_pushed(record: dict[str, Any]) -> bool:
    if not record.get("integration_commit"):
        return False
    repo = pathlib.Path(record["repository"])
    try:
        allow_preserved = record["approval_type"] == "adoption_bundle" and bool(record.get("adoption_cleanup"))
        verify_immutable_binding(record, allow_preserved_evidence=allow_preserved)
    except ApprovalError:
        cleanup_worktree(record)
        save_record(record, "RECOVERY_CLEANUP_COMPLETE")
        raise
    head = remote_head(repo, record["remote"], record["target_branch"])
    atomic_json(artifact_root() / record["approval_id"] / "remote-verification.json", {"fetched_at": now(), "expected_head": record.get("expected_remote_head"), "actual_head": head, "integration_commit": record["integration_commit"]})
    if head == record.get("expected_remote_head"):
        complete_integration(record, head)
        return True
    ancestor = run(["git", "merge-base", "--is-ancestor", record["integration_commit"], head], repo, check=False).returncode == 0
    if ancestor:
        cleanup_worktree(record)
        save_record(record, "RECOVERY_CLEANUP_COMPLETE")
        raise ApprovalError("remote advanced unexpectedly after integration mutation", "REMOTE_MOVED_AFTER_PUSH")
    if record.get("push_outcome") == "ambiguous" and head == record.get("remote_head_before"):
        record["push_outcome"] = "absent_proven"
        save_record(record, "PUSH_ABSENCE_PROVEN")
        return False
    if record.get("push_outcome") == "ambiguous":
        raise ApprovalError("ambiguous push cannot be reconciled to exact presence or absence", "PUSH_AMBIGUOUS")
    if record.get("push_outcome") == "reported_success":
        cleanup_worktree(record)
        save_record(record, "RECOVERY_CLEANUP_COMPLETE")
        raise ApprovalError("reported-success push no longer has an exact reconcilable remote result", "REMOTE_MOVED_AFTER_PUSH")
    return False


def push_exact(record: dict[str, Any], worktree: pathlib.Path, evidence: pathlib.Path) -> None:
    verify_remote_identity(record)
    if git(worktree, "status", "--porcelain=v1", "--untracked-files=all") or git(worktree, "rev-parse", "HEAD") != record["integration_commit"] or git(worktree, "rev-parse", "HEAD^{tree}") != record["integration_tree_sha"]:
        raise ApprovalError("refusing to push a dirty or unexpected integration worktree", "INTEGRATION_VALIDATION_SCOPE_FAILED")
    for _attempt in range(3):
        latest = remote_head(pathlib.Path(record["repository"]), record["remote"], record["target_branch"])
        if latest == record["remote_head_before"]:
            break
        old_base_is_ancestor = run(["git", "merge-base", "--is-ancestor", record["remote_head_before"], latest], pathlib.Path(record["repository"]), check=False).returncode == 0
        if not old_base_is_ancestor:
            raise ApprovalError("remote target was reset or rewritten after validation", "REMOTE_REWRITTEN_BEFORE_PUSH")
        result = run(["git", "merge", "--no-edit", latest], worktree, check=False)
        if result.returncode != 0:
            run(["git", "merge", "--abort"], worktree, check=False)
            raise ApprovalError("approved candidate conflicts with remote movement before push", "INTEGRATION_CONFLICT")
        record["remote_head_before"] = latest
        record["integration_commit"] = git(worktree, "rev-parse", "HEAD")
        record["integration_tree_sha"] = git(worktree, "rev-parse", "HEAD^{tree}")
        record["merge_commit"] = record["integration_commit"]
        save_record(record, "DIRECT_TARGET_REFRESHED")
        validate_integration(record, worktree, evidence)
        save_record(record, "DIRECT_REVALIDATED")
    else:
        raise ApprovalError("remote target kept moving before direct push", "REMOTE_MOVED_BEFORE_PUSH")
    record["integration_status"] = "PUSHING"
    record["expected_remote_head"] = record["integration_commit"]
    save_record(record, "PUSH_STARTED")
    fault = os.environ.get("GF_GF010_FAULT") if os.environ.get("GF_GF010_ENABLE_TEST_HOOKS") == "1" else ""
    if fault == "push_failure_before_remote":
        raise ApprovalError("controlled push failure before remote mutation", "PUSH_FAILED_BEFORE_REMOTE", human=False)
    if fault == "ambiguous_push_absent":
        record["push_outcome"] = "ambiguous"
        save_record(record, "PUSH_OUTCOME_AMBIGUOUS")
        raise ApprovalError("controlled ambiguous transport before remote mutation", "PUSH_AMBIGUOUS", human=False)
    push = run(["git", "push", record["remote"], f"HEAD:refs/heads/{record['target_branch']}"], worktree, check=False)
    (evidence / "push.stdout").write_text(push.stdout, encoding="utf-8")
    (evidence / "push.stderr").write_text(push.stderr, encoding="utf-8")
    if fault == "ambiguous_push_arrived":
        record["push_outcome"] = "ambiguous"
        save_record(record, "PUSH_OUTCOME_AMBIGUOUS")
        raise ApprovalError("controlled ambiguous transport after remote mutation", "PUSH_AMBIGUOUS", human=False)
    if push.returncode != 0:
        record["push_outcome"] = "ambiguous"
        save_record(record, "PUSH_OUTCOME_AMBIGUOUS")
        if reconcile_pushed(record):
            return
        raise ApprovalError("non-force push failed after remote reconciliation", "PUSH_REJECTED")
    record["push_outcome"] = "reported_success"
    save_record(record, "PUSH_CONFIRMED")
    if fault == "crash_after_push":
        os._exit(97)
    record["integration_status"] = "REMOTE_VERIFYING"
    save_record(record, "REMOTE_VERIFYING")
    if not reconcile_pushed(record):
        raise ApprovalError("remote does not contain exact integration result", "REMOTE_VERIFICATION_FAILED")


def push_pr_branch(record: dict[str, Any], worktree: pathlib.Path) -> None:
    branch = record["pr_branch"]
    repo = pathlib.Path(record["repository"])
    verify_remote_identity(record)
    existing = git(repo, "ls-remote", "--heads", record["remote"], f"refs/heads/{branch}", check=False)
    if existing:
        existing_sha = existing.split()[0]
        if existing_sha != record["integration_commit"]:
            fast_forward = run(["git", "merge-base", "--is-ancestor", existing_sha, record["integration_commit"]], repo, check=False).returncode == 0
            if not fast_forward:
                raise ApprovalError("existing approval branch has unexpected non-fast-forward content", "PR_BRANCH_MISMATCH")
            git(worktree, "push", record["remote"], f"HEAD:refs/heads/{branch}")
            save_record(record, "PR_BRANCH_UPDATED")
        return
    git(worktree, "push", record["remote"], f"HEAD:refs/heads/{branch}")
    save_record(record, "PR_BRANCH_PUSHED")


def refresh_pr_against_target(record: dict[str, Any], worktree: pathlib.Path, evidence: pathlib.Path) -> bool:
    repo = pathlib.Path(record["repository"])
    latest = remote_head(repo, record["remote"], record["target_branch"])
    if latest == record["remote_head_before"]:
        return False
    old_base_is_ancestor = run(["git", "merge-base", "--is-ancestor", record["remote_head_before"], latest], repo, check=False).returncode == 0
    if not old_base_is_ancestor:
        raise ApprovalError("PR target was reset or rewritten after validation", "REMOTE_REWRITTEN_BEFORE_PR_MERGE")
    result = run(["git", "merge", "--no-edit", latest], worktree, check=False)
    if result.returncode != 0:
        run(["git", "merge", "--abort"], worktree, check=False)
        raise ApprovalError("approved PR candidate conflicts with advanced remote target", "INTEGRATION_CONFLICT")
    record["remote_head_before"] = latest
    record["integration_commit"] = git(worktree, "rev-parse", "HEAD")
    record["integration_tree_sha"] = git(worktree, "rev-parse", "HEAD^{tree}")
    record["merge_commit"] = None
    record["expected_remote_head"] = None
    save_record(record, "PR_TARGET_REFRESHED")
    validate_integration(record, worktree, evidence)
    save_record(record, "PR_REVALIDATED")
    push_pr_branch(record, worktree)
    if record["integration"].get("pr_adapter") == "fixture" and record.get("pr_number"):
        atomic_json(evidence / "pr.json", {"adapter": "fixture", "number": record["pr_number"], "head": record["integration_commit"], "base": record["target_branch"], "state": "OPEN"})
    return True


def wait_pr_checks_on_stable_base(record: dict[str, Any], worktree: pathlib.Path, evidence: pathlib.Path, github_repo: str | None) -> None:
    for _attempt in range(3):
        refreshed = refresh_pr_against_target(record, worktree, evidence)
        if not refreshed:
            validate_integration(record, worktree, evidence)
            save_record(record, "PR_REVALIDATED")
        if record["integration"].get("pr_adapter") == "github" and record["integration"].get("required_checks"):
            checks = run(["gh", "pr", "checks", str(record["pr_number"]), "--repo", github_repo or "", "--required", "--watch"], worktree, check=False)
            if checks.returncode != 0:
                raise ApprovalError("required PR checks did not pass", "HUMAN_REQUIRED_EXTERNAL_POLICY")
        latest_after_checks = remote_head(pathlib.Path(record["repository"]), record["remote"], record["target_branch"])
        if latest_after_checks == record["remote_head_before"]:
            record["required_checks_status"] = "pass"
            save_record(record, "REQUIRED_CHECKS_PASS")
            return
    raise ApprovalError("remote target kept moving during PR validation/checks", "REMOTE_MOVED_DURING_PR_CHECKS")


def integrate_pr(record: dict[str, Any], worktree: pathlib.Path, evidence: pathlib.Path) -> None:
    record["pr_branch"] = record.get("pr_branch") or f"gf-approval/{record['approval_id']}"
    adapter = record["integration"].get("pr_adapter")
    github_repo = record["integration"].get("github_repository")
    fixture_receipt = evidence / "pr.json"
    if adapter == "fixture" and record.get("pr_number") and fixture_receipt.is_file():
        prior_value = json.loads(fixture_receipt.read_text(encoding="utf-8"))
        if prior_value.get("state") == "MERGED":
            merge_commit = prior_value.get("merge_commit")
            if prior_value.get("head") != record["integration_commit"] or prior_value.get("base") != record["target_branch"] or not merge_commit:
                raise ApprovalError("existing fixture PR merge does not match approval", "REMOTE_VERIFICATION_FAILED")
            record["merge_commit"] = merge_commit
            record["expected_remote_head"] = merge_commit
            save_record(record, "PR_MERGE_RECONCILED")
            if not reconcile_pushed(record):
                raise ApprovalError("reconciled fixture PR target is not exact", "REMOTE_VERIFICATION_FAILED")
            return
    if adapter == "github" and record.get("pr_number") and github_repo:
        prior = run(["gh", "pr", "view", str(record["pr_number"]), "--repo", github_repo, "--json", "state,mergeCommit,headRefOid,baseRefName,reviewDecision"], worktree, check=False)
        if prior.returncode == 0:
            prior_value = json.loads(prior.stdout)
            if prior_value.get("state") == "MERGED":
                merge_commit = (prior_value.get("mergeCommit") or {}).get("oid")
                if prior_value.get("headRefOid") != record["integration_commit"] or prior_value.get("baseRefName") != record["target_branch"] or not merge_commit:
                    raise ApprovalError("existing merged PR does not match approval", "REMOTE_VERIFICATION_FAILED")
                record["merge_commit"] = merge_commit
                record["expected_remote_head"] = merge_commit
                save_record(record, "PR_MERGE_RECONCILED")
                if not reconcile_pushed(record):
                    raise ApprovalError("reconciled PR target is not exact", "REMOTE_VERIFICATION_FAILED")
                return
    push_pr_branch(record, worktree)
    if adapter == "fixture":
        if not record.get("pr_number"):
            record["pr_number"] = int(hashlib.sha256(record["approval_id"].encode()).hexdigest()[:6], 16)
            atomic_json(evidence / "pr.json", {"adapter": "fixture", "number": record["pr_number"], "head": record["integration_commit"], "base": record["target_branch"], "state": "OPEN"})
            save_record(record, "PR_CREATED")
            if os.environ.get("GF_GF010_ENABLE_TEST_HOOKS") == "1" and os.environ.get("GF_GF010_FAULT") == "crash_after_pr_created":
                os._exit(98)
        review_satisfied = not record["integration"].get("external_reviewer_required") or (os.environ.get("GF_GF010_ENABLE_TEST_HOOKS") == "1" and os.environ.get("GF_GF010_EXTERNAL_REVIEW_APPROVED") == "1")
        if not review_satisfied:
            raise ApprovalError("remote policy requires a distinct human reviewer", "HUMAN_REQUIRED_EXTERNAL_POLICY")
        wait_pr_checks_on_stable_base(record, worktree, evidence, None)
        merge_env = {"GIT_AUTHOR_NAME":"Game Foundry","GIT_AUTHOR_EMAIL":"game-foundry@local.invalid","GIT_COMMITTER_NAME":"Game Foundry","GIT_COMMITTER_EMAIL":"game-foundry@local.invalid"}
        record["merge_commit"] = git(pathlib.Path(record["repository"]), "commit-tree", record["integration_tree_sha"], "-p", record["remote_head_before"], "-p", record["integration_commit"], env=merge_env, input_text=f"Merge approval {record['approval_id']}\n")
        record["expected_remote_head"] = record["merge_commit"]
        save_record(record, "PR_MERGE_STARTED")
        verify_remote_identity(record)
        push = run(["git", "push", record["remote"], f"{record['merge_commit']}:refs/heads/{record['target_branch']}"], worktree, check=False)
        if push.returncode != 0:
            raise ApprovalError("fixture PR merge was rejected", "PR_MERGE_FAILED")
        atomic_json(evidence / "pr.json", {"adapter": "fixture", "number": record["pr_number"], "head": record["integration_commit"], "base": record["target_branch"], "state": "MERGED", "merge_commit": record["merge_commit"], "required_checks": "pass"})
        if os.environ.get("GF_GF010_ENABLE_TEST_HOOKS") == "1" and os.environ.get("GF_GF010_FAULT") == "crash_after_pr_merge":
            os._exit(99)
        if os.environ.get("GF_GF010_ENABLE_TEST_HOOKS") == "1" and os.environ.get("GF_GF010_FAULT") == "crash_after_pr_merge_unknown":
            record["merge_commit"] = None; record["expected_remote_head"] = None; save_record(record, "PR_MERGE_RESULT_UNKNOWN"); os._exit(100)
        save_record(record, "PR_MERGED")
    elif adapter == "github":
        if not github_repo or shutil.which("gh") is None:
            raise ApprovalError("GitHub PR policy is configured but gh/repository is unavailable", "HUMAN_REQUIRED_POLICY")
        if not record.get("pr_number"):
            found = run(["gh", "pr", "list", "--repo", github_repo, "--head", record["pr_branch"], "--base", record["target_branch"], "--state", "open", "--json", "number,headRefOid,baseRefName,state", "--limit", "2"], worktree, check=False)
            matches = json.loads(found.stdout or "[]") if found.returncode == 0 else []
            matches = [item for item in matches if item.get("headRefOid") == record["integration_commit"] and item.get("baseRefName") == record["target_branch"] and item.get("state") == "OPEN"]
            if len(matches) > 1:
                raise ApprovalError("multiple existing PRs match approval branch", "PR_AMBIGUOUS")
            if matches:
                record["pr_number"] = matches[0]["number"]
            else:
                title = record["candidate_commits"][-1].get("message", record["approval_id"])
                created = run(["gh", "pr", "create", "--repo", github_repo, "--base", record["target_branch"], "--head", record["pr_branch"], "--title", title, "--body", f"Game Foundry approval: {record['approval_id']}"], worktree, check=False)
                if created.returncode != 0:
                    raise ApprovalError("GitHub PR creation failed", "PR_CREATION_FAILED")
                record["pr_number"] = int(created.stdout.strip().splitlines()[-1].rstrip("/").split("/")[-1])
            save_record(record, "PR_CREATED")
        identity = run(["gh", "pr", "view", str(record["pr_number"]), "--repo", github_repo, "--json", "state,headRefOid,baseRefName"], worktree, check=False)
        if identity.returncode != 0:
            raise ApprovalError("GitHub PR identity is unavailable", "PR_IDENTITY_CHANGED")
        identity_value = json.loads(identity.stdout)
        if identity_value.get("state") != "OPEN" or identity_value.get("headRefOid") != record["integration_commit"] or identity_value.get("baseRefName") != record["target_branch"]:
            raise ApprovalError("GitHub PR head or base does not match the approved transaction", "PR_IDENTITY_CHANGED")
        review_satisfied = True
        if record["integration"].get("external_reviewer_required"):
            review = run(["gh", "pr", "view", str(record["pr_number"]), "--repo", github_repo, "--json", "reviewDecision"], worktree, check=False)
            review_satisfied = review.returncode == 0 and json.loads(review.stdout).get("reviewDecision") == "APPROVED"
        if not review_satisfied:
            raise ApprovalError("remote policy requires a distinct human reviewer", "HUMAN_REQUIRED_EXTERNAL_POLICY")
        wait_pr_checks_on_stable_base(record, worktree, evidence, github_repo)
        method = record["integration"].get("merge_method", "merge")
        if not record["integration"].get("require_strict_base_checks"):
            raise ApprovalError("GitHub PR policy must require strict up-to-date base checks", "INTEGRATION_POLICY_INVALID")
        strict = run(["gh", "api", f"repos/{github_repo}/branches/{record['target_branch']}/protection/required_status_checks", "--jq", ".strict"], worktree, check=False)
        if strict.returncode != 0 or strict.stdout.strip() != "true":
            raise ApprovalError("GitHub target does not enforce strict up-to-date required checks", "HUMAN_REQUIRED_EXTERNAL_POLICY")
        final_base = remote_head(pathlib.Path(record["repository"]), record["remote"], record["target_branch"])
        if final_base != record["remote_head_before"]:
            raise ApprovalError("GitHub target moved after required checks", "REMOTE_MOVED_DURING_PR_CHECKS", human=False)
        final_identity = run(["gh", "pr", "view", str(record["pr_number"]), "--repo", github_repo, "--json", "state,headRefOid,baseRefName"], worktree, check=False)
        if final_identity.returncode != 0:
            raise ApprovalError("GitHub PR identity is unavailable before merge", "PR_IDENTITY_CHANGED")
        final_identity_value = json.loads(final_identity.stdout)
        if final_identity_value.get("state") != "OPEN" or final_identity_value.get("headRefOid") != record["integration_commit"] or final_identity_value.get("baseRefName") != record["target_branch"]:
            raise ApprovalError("GitHub PR changed head or base before merge", "PR_IDENTITY_CHANGED")
        save_record(record, "PR_MERGE_STARTED")
        merged = run(["gh", "pr", "merge", str(record["pr_number"]), "--repo", github_repo, f"--{method}", "--match-head-commit", record["integration_commit"]], worktree, check=False)
        if merged.returncode != 0:
            raise ApprovalError("GitHub PR merge failed or required policy is unsatisfied", "HUMAN_REQUIRED_EXTERNAL_POLICY")
        if os.environ.get("GF_GF010_ENABLE_TEST_HOOKS") == "1" and os.environ.get("GF_GF010_FAULT") == "crash_after_pr_merge":
            os._exit(99)
        view = run(["gh", "pr", "view", str(record["pr_number"]), "--repo", github_repo, "--json", "state,mergeCommit,headRefOid,baseRefName"], worktree, check=False)
        if view.returncode != 0:
            raise ApprovalError("GitHub PR merge result is unavailable", "REMOTE_VERIFICATION_FAILED")
        value = json.loads(view.stdout)
        merge_commit = (value.get("mergeCommit") or {}).get("oid")
        if value.get("state") != "MERGED" or value.get("headRefOid") != record["integration_commit"] or value.get("baseRefName") != record["target_branch"] or not merge_commit:
            raise ApprovalError("GitHub PR merge result does not match approval", "REMOTE_VERIFICATION_FAILED")
        record["merge_commit"] = merge_commit
        record["expected_remote_head"] = merge_commit
        save_record(record, "PR_MERGED")
    else:
        raise ApprovalError("trusted PR adapter is invalid", "INTEGRATION_POLICY_INVALID")
    record["integration_status"] = "REMOTE_VERIFYING"
    save_record(record, "REMOTE_VERIFYING")
    if not reconcile_pushed(record):
        raise ApprovalError("PR target does not contain exact merged result", "REMOTE_VERIFICATION_FAILED")


def resume_absent_push(record: dict[str, Any]) -> dict[str, Any]:
    repo = pathlib.Path(record["repository"])
    evidence = artifact_root() / record["approval_id"]
    try:
        verify_candidate_binding(record)
    except ApprovalError:
        cleanup_worktree(record)
        save_record(record, "RECOVERY_CLEANUP_COMPLETE")
        raise
    if record.get("worktree_path"):
        cleanup_worktree(record)
        save_record(record, "RECOVERY_CLEANUP_COMPLETE")
    worktree = pathlib.Path(tempfile.mkdtemp(prefix=f"gf010-{record['approval_id']}-"))
    record["worktree_path"] = str(worktree)
    save_record(record, "WORKTREE_PATH_RESERVED")
    worktree.rmdir()
    git(repo, "worktree", "add", "--detach", str(worktree), record["integration_commit"])
    save_record(record, "INTEGRATION_WORKTREE_RESTORED")
    try:
        push_exact(record, worktree, evidence)
        return record
    finally:
        if record["integration_status"] != "INTEGRATED":
            cleanup_worktree(record)
            save_record(record, "CLEANUP_COMPLETE")


def resume_pr(record: dict[str, Any]) -> dict[str, Any]:
    verify_candidate_binding(record)
    repo = pathlib.Path(record["repository"])
    evidence = artifact_root() / record["approval_id"]
    if record.get("worktree_path"):
        cleanup_worktree(record)
        save_record(record, "RECOVERY_CLEANUP_COMPLETE")
    worktree = pathlib.Path(tempfile.mkdtemp(prefix=f"gf010-{record['approval_id']}-"))
    record["worktree_path"] = str(worktree)
    save_record(record, "WORKTREE_PATH_RESERVED")
    worktree.rmdir()
    git(repo, "worktree", "add", "--detach", str(worktree), record["integration_commit"])
    save_record(record, "INTEGRATION_WORKTREE_RESTORED")
    try:
        integrate_pr(record, worktree, evidence)
        return record
    finally:
        if record["integration_status"] != "INTEGRATED":
            cleanup_worktree(record)
            save_record(record, "CLEANUP_COMPLETE")


def integrate(record: dict[str, Any]) -> dict[str, Any]:
    if record["integration_status"] == "INTEGRATED":
        return record
    if record["approval_status"] != "approved":
        raise ApprovalError("human approval is required", "APPROVAL_REQUIRED")
    if record.get("integration_commit") and record.get("push_outcome") == "absent_proven" and record["integration"]["mode"] == "direct":
        return resume_absent_push(record)
    if record.get("integration_commit") and record.get("push_outcome") in {"ambiguous", "reported_success"}:
        if reconcile_pushed(record):
            return record
        if record.get("push_outcome") == "absent_proven" and record["integration"]["mode"] == "direct":
            return resume_absent_push(record)
    checkpoints = [item.get("name") for item in record.get("checkpoints", [])]
    if record["integration"]["mode"] == "pull_request" and record.get("integration_commit") and "INTEGRATION_VALIDATED" in checkpoints:
        cleanup_worktree(record)
        save_record(record, "RECOVERY_CLEANUP_COMPLETE")
        return resume_pr(record)
    repo = pathlib.Path(record["repository"])
    evidence = artifact_root() / record["approval_id"]
    evidence.mkdir(parents=True, exist_ok=True)
    if record.get("worktree_path"):
        cleanup_worktree(record)
        save_record(record, "RECOVERY_CLEANUP_COMPLETE")
    worktree = pathlib.Path(tempfile.mkdtemp(prefix=f"gf010-{record['approval_id']}-"))
    record["worktree_path"] = str(worktree)
    save_record(record, "WORKTREE_PATH_RESERVED")
    worktree_created = False
    try:
        record["integration_started_at"] = record.get("integration_started_at") or now()
        record["integration_status"] = "INTEGRATION_PRECHECK"
        save_record(record, "INTEGRATION_PRECHECK")
        verify_candidate_binding(record)
        before = remote_head(repo, record["remote"], record["target_branch"])
        record["remote_head_before"] = before
        save_record(record, "REMOTE_FETCHED")
        worktree.rmdir()
        git(repo, "worktree", "add", "--detach", str(worktree), before)
        worktree_created = True
        if os.environ.get("GF_GF010_ENABLE_TEST_HOOKS") == "1" and os.environ.get("GF_GF010_FAULT") == "crash_after_worktree_add_before_checkpoint":
            os._exit(94)
        record["integration_status"] = "INTEGRATING"
        save_record(record, "INTEGRATION_WORKTREE_CREATED")
        if os.environ.get("GF_GF010_ENABLE_TEST_HOOKS") == "1" and os.environ.get("GF_GF010_FAULT") == "crash_after_worktree_created":
            os._exit(96)
        for candidate in record["candidate_commits"]:
            result = run(["git", "cherry-pick", candidate["sha"]], worktree, check=False)
            if result.returncode != 0:
                run(["git", "cherry-pick", "--abort"], worktree, check=False)
                raise ApprovalError("approved candidate conflicts with remote target", "INTEGRATION_CONFLICT")
        integration_head = git(worktree, "rev-parse", "HEAD")
        record["integration_commit"] = integration_head
        record["integration_tree_sha"] = git(worktree, "rev-parse", "HEAD^{tree}")
        if record["integration"]["mode"] == "direct":
            record["merge_commit"] = integration_head
        save_record(record, "CANDIDATE_APPLIED")
        validate_integration(record, worktree, evidence)
        save_record(record, "INTEGRATION_VALIDATED")
        if record["integration"]["mode"] == "pull_request":
            integrate_pr(record, worktree, evidence)
        else:
            push_exact(record, worktree, evidence)
        return record
    finally:
        if record["integration_status"] != "INTEGRATED":
            if worktree_created or worktree.exists():
                cleanup_worktree(record)
            try:
                save_record(record, "CLEANUP_COMPLETE" if not worktree.exists() else "CLEANUP_FAILED")
            except Exception:
                pass


def approve(approval_id: str, source: str) -> dict[str, Any]:
    if os.environ.get("GF_UNATTENDED_RUN") == "1" or os.environ.get("GF_SCHEDULED_RUN") == "1":
        raise ApprovalError("scheduled or unattended execution cannot create approval", "SCHEDULER_APPROVAL_FORBIDDEN")
    if source not in {"operator_agent_explicit_human", "operator_cli_explicit_human"}:
        raise ApprovalError("approval source must attest explicit current human approval", "APPROVAL_SOURCE_INVALID")
    record = load_record(approval_id)
    if record["integration_status"] == "INTEGRATED":
        return record
    if record["integration_status"] != "PENDING_HUMAN":
        raise ApprovalError(f"approval is not pending: {record['integration_status']}")
    verify_candidate_binding(record)
    record["approval_status"] = "approved"
    record["approved_at"] = now()
    record["approval_source"] = source
    record["human_qa_status"] = "approved"
    record["integration_status"] = "APPROVED"
    record["human_action_required"] = False
    save_record(record, "APPROVAL_RECORDED")
    return integrate(record)


def target_key(record: dict[str, Any]) -> str:
    return "\0".join([record["repository"], record["remote"], record["target_branch"]])


def list_records() -> list[dict[str, Any]]:
    records = []
    state_root().mkdir(parents=True, exist_ok=True)
    for path in sorted(state_root().glob("*.json")):
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            records.append({key: value.get(key) for key in ["approval_id", "bundle_id", "project_id", "approval_status", "integration_status", "human_action_required"]})
        except Exception:
            records.append({"approval_id": path.stem, "integration_status": "CORRUPT", "human_action_required": True})
    return records


def resolve_current() -> str:
    pending = [record["approval_id"] for record in list_records() if record.get("integration_status") == "PENDING_HUMAN"]
    if len(pending) != 1:
        raise ApprovalError(f"--current requires exactly one pending approval; found {len(pending)}", "MULTIPLE_PENDING_APPROVALS")
    return pending[0]


def operator_result(record: dict[str, Any]) -> str:
    return "\n".join([
        f"APPROVAL INTEGRATION: {'COMPLETE' if record['integration_status']=='INTEGRATED' else record['integration_status']}",
        "",
        f"Approval: {record['approval_id']}",
        f"Approved candidate: {record.get('candidate_sha')}",
        f"Integrated commit: {record.get('integration_commit')}",
        f"Remote: {record['remote']}/{record['target_branch']}",
        f"Validation: {record.get('validation_status', 'unknown').upper()}",
        f"Remote verification: {'PASS' if record['integration_status']=='INTEGRATED' else 'NOT COMPLETE'}",
        f"Cleanup: {'PASS' if record.get('cleanup',{}).get('temporary_worktree_removed') else 'NOT COMPLETE'}",
        "",
        f"Human action required: {'YES' if record.get('human_action_required') else 'NO'}",
    ])


def main() -> int:
    parser = argparse.ArgumentParser(prog="gf-approve.sh")
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("create"); create.add_argument("manifest", type=pathlib.Path)
    classify = sub.add_parser("classify"); classify.add_argument("manifest", type=pathlib.Path)
    approve_parser = sub.add_parser("approve"); approve_parser.add_argument("approval_id", nargs="?"); approve_parser.add_argument("--current", action="store_true"); approve_parser.add_argument("--source", required=True)
    integrate_parser = sub.add_parser("integrate"); integrate_parser.add_argument("approval_id")
    reconcile = sub.add_parser("reconcile"); reconcile.add_argument("approval_id")
    status = sub.add_parser("status"); status.add_argument("approval_id"); status.add_argument("--json", action="store_true")
    listing = sub.add_parser("list"); listing.add_argument("--json", action="store_true")
    revoke = sub.add_parser("revoke"); revoke.add_argument("approval_id")
    doctor = sub.add_parser("doctor"); doctor.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "create":
            manifest_value = json.loads(args.manifest.read_text(encoding="utf-8"))
            approval_id = manifest_value.get("approval_id", "invalid")
            with transaction_locks(approval_id):
                create_manifest(args.manifest)
        elif args.command == "classify":
            manifest = json.loads(args.manifest.read_text(encoding="utf-8")); validate_manifest(manifest)
            repo = pathlib.Path(manifest["repository"]).resolve(); enforce_policy(manifest, repo, args.manifest, classification_only=True); allowed = sorted({path for group in manifest.get("adoption", {}).get("groups", []) for path in group.get("paths", [])}); dirty = status_paths(repo)
            expected=sorted(set(dirty)&set(allowed)); result = {"status": "pass" if set(dirty) == set(allowed) else "reject", "expected_slice_work":[path for path in expected if not path.endswith(".gd.uid") and not path.startswith("reports/")], "expected_generated_metadata":[path for path in expected if path.endswith(".gd.uid")], "acceptance_evidence":[path for path in expected if path.startswith("reports/")], "unrelated": sorted(set(dirty)-set(allowed)), "ambiguous": sorted(set(allowed)-set(dirty))}
            print(json.dumps(result, indent=2)); return 0 if result["status"] == "pass" else 3
        elif args.command == "approve":
            approval_id = resolve_current() if args.current else args.approval_id
            if not approval_id: raise ApprovalError("approval id or --current is required")
            initial = load_record(approval_id)
            with transaction_locks(approval_id, target_key(initial)):
                if os.environ.get("GF_GF010_ENABLE_TEST_HOOKS") == "1" and os.environ.get("GF_GF010_HOLD_LOCK_MS"):
                    time.sleep(int(os.environ["GF_GF010_HOLD_LOCK_MS"]) / 1000)
                try:
                    record = approve(approval_id, args.source)
                except ApprovalError as error:
                    if error.failure_class not in {"APPROVAL_REQUIRED", "SCHEDULER_APPROVAL_FORBIDDEN", "APPROVAL_SOURCE_INVALID", "TRANSACTION_BUSY"}:
                        set_failure(load_record(approval_id), error); error.recorded = True
                    raise
            print(operator_result(record))
        elif args.command in {"integrate", "reconcile"}:
            initial = load_record(args.approval_id)
            with transaction_locks(args.approval_id, target_key(initial)):
                record = load_record(args.approval_id)
                try:
                    if record["integration_status"] == "INTEGRATED":
                        pass
                    elif args.command == "reconcile" and record["integration"].get("mode") == "pull_request" and record.get("pr_number") and not record.get("expected_remote_head"):
                        record = integrate(record)
                    elif args.command == "reconcile" and reconcile_pushed(record): pass
                    else: record = integrate(record)
                except ApprovalError as error:
                    if error.failure_class not in {"APPROVAL_REQUIRED", "TRANSACTION_BUSY"}:
                        set_failure(load_record(args.approval_id), error); error.recorded = True
                    raise
            print(operator_result(record))
        elif args.command == "status":
            record = load_record(args.approval_id); print(json.dumps(record, indent=2) if args.json else operator_result(record))
        elif args.command == "list":
            records = list_records(); print(json.dumps(records, indent=2) if args.json else "\n".join(f"{item['approval_id']}\t{item['integration_status']}" for item in records))
        elif args.command == "revoke":
            initial = load_record(args.approval_id)
            with transaction_locks(args.approval_id, target_key(initial)):
                record = load_record(args.approval_id)
                if record["integration_status"] != "PENDING_HUMAN": raise ApprovalError("only pending approval can be revoked")
                record["integration_status"] = "REVOKED"; record["approval_status"] = "revoked"; record["human_action_required"] = False; save_record(record, "REVOKED"); write_receipt(record)
            print(operator_result(record))
        elif args.command == "doctor":
            root = control_root(); config_path = policy_path(); config = json.loads(config_path.read_text(encoding="utf-8")); checks = []
            checks.append({"id":"git_repository","status":"pass" if run(["git","rev-parse","--git-dir"],root,check=False).returncode==0 else "fail"})
            for project, policy in config.get("repositories", {}).items():
                configured_repo = pathlib.Path(policy.get("repository", ".")); configured_repo = configured_repo if configured_repo.is_absolute() else (config_path.parent.parent / configured_repo).resolve()
                remote_ok = run(["git","remote","get-url",policy["remote"]],configured_repo,check=False).returncode==0
                branch_ok = run(["git","ls-remote","--exit-code",policy["remote"],f"refs/heads/{policy['target_branch']}"],configured_repo,check=False).returncode==0
                checks.append({"id":f"{project}_remote","status":"pass" if remote_ok else "fail"})
                checks.append({"id":f"{project}_target_branch","status":"pass" if branch_ok else "fail"})
                if policy.get("mode")=="pull_request": checks.append({"id":f"{project}_gh","status":"pass" if shutil.which("gh") else "fail"})
            result={"status":"ready" if all(check["status"]=="pass" for check in checks) else "not_ready","checks":checks}
            print(json.dumps(result,indent=2) if args.json else "\n".join(f"{item['id']}: {item['status'].upper()}" for item in checks)); return 0 if result["status"]=="ready" else 1
        return 0
    except ApprovalError as error:
        approval_id = getattr(args, "approval_id", None)
        non_mutating = {"INVALID_APPROVAL", "APPROVAL_REQUIRED", "MULTIPLE_PENDING_APPROVALS", "FORCE_PUSH_FORBIDDEN", "SCHEDULER_APPROVAL_FORBIDDEN", "APPROVAL_SOURCE_INVALID", "TRANSACTION_BUSY", "INTEGRATION_POLICY_INVALID", "INTEGRATION_POLICY_MISMATCH"}
        if approval_id and error.failure_class not in non_mutating and not getattr(error, "recorded", False):
            try: set_failure(load_record(approval_id), error)
            except Exception: pass
        print(json.dumps({"status": "error", "failure_class": error.failure_class, "failure_reason": str(error), "human_action_required": error.human}), file=sys.stderr)
        return 20 if error.human else 70


if __name__ == "__main__":
    raise SystemExit(main())
