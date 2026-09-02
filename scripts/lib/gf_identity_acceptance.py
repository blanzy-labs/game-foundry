#!/usr/bin/env python3
"""Git-round-trip and fail-closed acceptance for candidate identity v2."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import subprocess
import tempfile

from gf_approval import ApprovalError, CANDIDATE_IDENTITY_VERSION, git_blob_identity, normalize_candidates, path_identity, status_paths, validate_manifest, workspace_fingerprint


def run(args: list[str], cwd: pathlib.Path) -> str:
    return subprocess.run(args, cwd=cwd, text=True, capture_output=True, check=True).stdout.strip()


def git(repo: pathlib.Path, *args: str) -> str:
    return run(["git", *args], repo)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> int:
    results: dict[str, str] = {}
    with tempfile.TemporaryDirectory(prefix="gf-identity-v2-") as temporary:
        root = pathlib.Path(temporary)
        remote = root / "remote.git"
        source = root / "source"
        run(["git", "init", "--bare", "-q", str(remote)], root)
        run(["git", "init", "-q", "-b", "main", str(source)], root)
        git(source, "config", "user.name", "Identity Test")
        git(source, "config", "user.email", "identity@test.invalid")
        bound = source / "bound.txt"
        bound.write_text("base\n", encoding="utf-8")
        os.chmod(bound, 0o644)
        git(source, "add", "bound.txt")
        git(source, "commit", "-q", "-m", "base")
        base = git(source, "rev-parse", "HEAD")
        git(source, "remote", "add", "origin", str(remote))
        git(source, "push", "-q", "-u", "origin", "main")
        bound.write_text("candidate\n", encoding="utf-8")
        dirty_fingerprint, _ = workspace_fingerprint(source, ["bound.txt"], base)
        git(source, "add", "bound.txt")
        git(source, "commit", "-q", "-m", "preserved candidate")
        candidate = git(source, "rev-parse", "HEAD")
        git(source, "push", "-q", "origin", "HEAD:refs/heads/preserved")

        reconstructions = {"canonical": workspace_fingerprint(source, ["bound.txt"], base)[0]}
        worktree = root / "worktree"
        git(source, "worktree", "add", "-q", "--detach", str(worktree), candidate)
        reconstructions["clean_worktree"] = workspace_fingerprint(worktree, ["bound.txt"], base)[0]
        detached = root / "detached"
        git(source, "worktree", "add", "-q", "--detach", str(detached), candidate)
        reconstructions["detached_checkout"] = workspace_fingerprint(detached, ["bound.txt"], base)[0]
        clone = root / "clone"
        run(["git", "clone", "-q", "--branch", "preserved", str(remote), str(clone)], root)
        reconstructions["clean_clone"] = workspace_fingerprint(clone, ["bound.txt"], base)[0]
        remote_clone = root / "remote-preserved"
        run(["git", "clone", "-q", "--branch", "preserved", str(remote), str(remote_clone)], root)
        reconstructions["remote_preservation"] = workspace_fingerprint(remote_clone, ["bound.txt"], base)[0]
        require(set(reconstructions.values()) == {dirty_fingerprint}, "Git reconstructions changed identity")
        results["git_reconstructions"] = "pass"

        os.chmod(bound, 0o664)
        require(not git(source, "diff", "--summary"), "non-Git permission appeared in diff")
        require(workspace_fingerprint(source, ["bound.txt"], base)[0] == dirty_fingerprint, "non-Git permission changed identity")
        os.chmod(bound, 0o644)
        results["non_git_permission"] = "pass"

        os.chmod(bound, 0o755)
        git(source, "add", "bound.txt")
        require("mode change 100644 => 100755" in git(source, "diff", "--cached", "--summary"), "Git mode change not represented")
        require(workspace_fingerprint(source, ["bound.txt"], base)[0] != dirty_fingerprint, "Git executable bit did not change identity")
        git(source, "restore", "--staged", "--worktree", "bound.txt")
        results["git_executable_mode"] = "pass"

        bound.write_text("changed\n", encoding="utf-8")
        require(workspace_fingerprint(source, ["bound.txt"], base)[0] != dirty_fingerprint, "content did not change identity")
        git(source, "restore", "bound.txt")
        results["content_change"] = "pass"

        bound.rename(source / "renamed.txt")
        require(workspace_fingerprint(source, ["bound.txt"], base)[0] != dirty_fingerprint, "bound rename did not change identity")
        (source / "renamed.txt").rename(bound)
        results["bound_path_change"] = "pass"

        bound.unlink()
        require(workspace_fingerprint(source, ["bound.txt"], base)[0] != dirty_fingerprint, "missing file did not fail binding")
        git(source, "restore", "bound.txt")
        results["required_missing"] = "pass"

        (source / "extra.txt").write_text("unbound\n", encoding="utf-8")
        require(workspace_fingerprint(source, ["bound.txt"], base)[0] == dirty_fingerprint, "unbound file entered fingerprint")
        require("extra.txt" in status_paths(source), "unbound file escaped dirty-inventory rejection")
        (source / "extra.txt").unlink()
        results["unbound_file"] = "pass"

        old = hashlib.sha256(json.dumps({"paths": {"bound.txt": path_identity(source, "bound.txt")}}, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        require(old != dirty_fingerprint, "old and v2 identities were not distinguished")
        stale_manifest = {"schema_version": 1, "approval_id": "stale", "approval_type": "adoption_bundle", "project_id": "fixture", "repository": str(source), "units": [{}], "evidence_bindings": [{}], "remote": "origin", "target_branch": "main", "integration": {"mode": "direct", "allow_force_push": False, "verify_remote": True}, "validation_commands": [["true"]], "candidate_patch_sha256": old}
        try:
            validate_manifest(stale_manifest)
        except ApprovalError as error:
            require(error.failure_class == "CANDIDATE_IDENTITY_VERSION_MISMATCH", "old identity failed for wrong reason")
        else:
            raise RuntimeError("old identity version was accepted")
        results["old_identity_rejected"] = "pass"

        git(source, "commit", "--allow-empty", "-q", "-m", "incompatible base")
        incompatible_base = git(source, "rev-parse", "HEAD")
        require(workspace_fingerprint(source, ["bound.txt"], incompatible_base)[0] == dirty_fingerprint, "file identity unexpectedly depends on base")
        candidate_descriptor = {"sha": candidate, "tree_sha": git(source, "rev-parse", f"{candidate}^{{tree}}"), "unit_ids": ["UNIT"], "paths": ["bound.txt"]}
        try:
            normalize_candidates(source, incompatible_base, [candidate_descriptor], ["UNIT"])
        except ApprovalError:
            pass
        else:
            raise RuntimeError("candidate approval crossed an incompatible base")
        results["base_revision"] = "pass"

        bound.unlink()
        bound.symlink_to("elsewhere")
        try:
            path_identity(source, "bound.txt")
        except ApprovalError:
            pass
        else:
            raise RuntimeError("candidate symlink was accepted")
        bound.unlink()
        git(source, "restore", "bound.txt")
        results["symlink_rejected"] = "pass"

        fields = git(source, "ls-tree", "HEAD", "--", "bound.txt").split()
        blob = subprocess.check_output(["git", "cat-file", "blob", "HEAD:bound.txt"], cwd=source)
        require(git_blob_identity(fields[0], hashlib.sha256(blob).hexdigest()) == path_identity(source, "bound.txt"), "cleanup baseline identity differs")
        results["cleanup_identity"] = "pass"

    print(json.dumps({"status": "pass", "candidate_identity_version": CANDIDATE_IDENTITY_VERSION, "tests": results}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
