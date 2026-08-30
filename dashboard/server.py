#!/usr/bin/env python3
"""Dependency-free, read-only HTTP dashboard for Game Foundry projects."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlsplit


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REGISTRY = REPOSITORY_ROOT / "config" / "projects.json"
DEFAULT_STATIC_ROOT = Path(__file__).resolve().parent / "static"
MILESTONE_COMMAND = REPOSITORY_ROOT / "scripts" / "gf-milestone.sh"
MILESTONE_ID_PATTERN = re.compile(r"^[A-Z0-9][A-Z0-9-]+$")
STATUS_TIMEOUT_SECONDS = 5
MAX_ERROR_LENGTH = 300


class RegistryError(ValueError):
    """Raised when the project registry cannot be read at all."""


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _clean_reason(value: object) -> str:
    text = " ".join(str(value).split())
    return text[:MAX_ERROR_LENGTH] or "No additional detail was returned."


def load_registry(path: Path) -> tuple[list[dict[str, Any]], list[str]]:
    """Load valid projects and return human-readable errors for skipped entries."""
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise RegistryError(f"Project registry not found: {path}") from exc
    except (OSError, UnicodeError) as exc:
        raise RegistryError(f"Project registry could not be read: {_clean_reason(exc)}") from exc
    except json.JSONDecodeError as exc:
        raise RegistryError(f"Project registry contains invalid JSON: line {exc.lineno}, column {exc.colno}") from exc

    if not isinstance(raw, dict):
        raise RegistryError("Project registry must be a JSON object.")
    if raw.get("schema_version") != 1:
        raise RegistryError("Project registry schema_version must be 1.")
    entries = raw.get("projects")
    if not isinstance(entries, list):
        raise RegistryError("Project registry projects must be an array.")

    projects: list[dict[str, Any]] = []
    errors: list[str] = []
    seen_ids: set[str] = set()

    for index, entry in enumerate(entries):
        label = f"Project at index {index}"
        if not isinstance(entry, dict):
            errors.append(f"{label} is not an object and was skipped.")
            continue

        project_id = entry.get("id")
        name = entry.get("name")
        platforms = entry.get("platforms")
        active_milestone = entry.get("active_milestone")

        if not isinstance(project_id, str) or not project_id.strip():
            errors.append(f"{label} has an invalid id and was skipped.")
            continue
        project_id = project_id.strip()
        label = f"Project '{project_id}'"
        if project_id in seen_ids:
            errors.append(f"{label} duplicates an earlier id and was skipped.")
            continue
        if not isinstance(name, str) or not name.strip():
            errors.append(f"{label} has an empty name and was skipped.")
            continue
        if (
            not isinstance(platforms, list)
            or not platforms
            or any(not isinstance(platform, str) or not platform.strip() for platform in platforms)
        ):
            errors.append(f"{label} has invalid platforms and was skipped.")
            continue
        if active_milestone is not None and (
            not isinstance(active_milestone, str)
            or MILESTONE_ID_PATTERN.fullmatch(active_milestone) is None
        ):
            errors.append(f"{label} has an invalid active_milestone and was skipped.")
            continue

        seen_ids.add(project_id)
        projects.append(
            {
                "id": project_id,
                "name": name.strip(),
                "platforms": [platform.strip() for platform in platforms],
                "active_milestone": active_milestone,
            }
        )

    return projects, errors


def calculate_percent(passed: int, total: int) -> int | None:
    if total <= 0:
        return None
    return int((passed * 100 / total) + 0.5)


def _unavailable_project(project: dict[str, Any], state: str, reason: str) -> dict[str, Any]:
    return {
        **project,
        "milestone": None,
        "state": state,
        "classification": "attention",
        "error": reason,
    }


def _classification(status: str, task_states: dict[str, str]) -> str:
    if status in {"automated_work_complete", "complete", "pass"}:
        return "complete"
    if status != "active" or any(value in {"fail", "failed", "escalated"} for value in task_states.values()):
        return "attention"
    return "active"


def normalize_milestone(raw: object, expected_id: str) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("status output must be a JSON object")

    milestone_id = raw.get("milestone_id")
    title = raw.get("title")
    status = raw.get("status")
    tasks = raw.get("tasks")
    progress = raw.get("progress")
    next_action = raw.get("next")

    if milestone_id != expected_id:
        raise ValueError("status output milestone ID does not match the configured milestone")
    if not isinstance(title, str) or not title.strip():
        raise ValueError("status output has no milestone title")
    if not isinstance(status, str) or not status.strip():
        raise ValueError("status output has no milestone state")
    if not isinstance(tasks, dict):
        raise ValueError("status output task states are invalid")
    if not isinstance(progress, dict):
        raise ValueError("status output progress is unavailable")
    if not isinstance(next_action, str) or not next_action.strip():
        raise ValueError("status output next action is unavailable")

    passed = progress.get("passed")
    total = progress.get("total")
    if (
        isinstance(passed, bool)
        or isinstance(total, bool)
        or not isinstance(passed, int)
        or not isinstance(total, int)
        or passed < 0
        or total < 0
        or passed > total
    ):
        raise ValueError("status output progress values are invalid")

    task_states: dict[str, str] = {}
    for task_id, task in tasks.items():
        if not isinstance(task_id, str) or not isinstance(task, dict) or not isinstance(task.get("status"), str):
            raise ValueError("status output contains an invalid task state")
        task_states[task_id] = task["status"]

    normalized_status = status.strip().lower()
    return {
        "id": milestone_id,
        "title": title.strip(),
        "status": normalized_status,
        "tasks": task_states,
        "passed": passed,
        "total": total,
        "percent": calculate_percent(passed, total),
        "next": next_action.strip(),
        "classification": _classification(normalized_status, task_states),
    }


class DashboardService:
    def __init__(
        self,
        registry_path: Path = DEFAULT_REGISTRY,
        milestone_command: Path = MILESTONE_COMMAND,
        timeout: int = STATUS_TIMEOUT_SECONDS,
        runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    ) -> None:
        self.registry_path = registry_path
        self.milestone_command = milestone_command
        self.timeout = timeout
        self.runner = runner

    def _status_for(self, project: dict[str, Any]) -> dict[str, Any]:
        milestone_id = project["active_milestone"]
        if milestone_id is None:
            return _unavailable_project(project, "not_initialized", "No active milestone is configured.")

        try:
            result = self.runner(
                [str(self.milestone_command), "status", milestone_id, "--json"],
                cwd=REPOSITORY_ROOT,
                capture_output=True,
                text=True,
                timeout=self.timeout,
                check=False,
            )
        except subprocess.TimeoutExpired:
            return _unavailable_project(
                project,
                "state_unavailable",
                f"Milestone status timed out after {self.timeout} seconds.",
            )
        except OSError as exc:
            return _unavailable_project(project, "state_unavailable", f"Milestone status could not run: {_clean_reason(exc)}")

        if result.returncode != 0:
            detail = _clean_reason(result.stderr or result.stdout)
            state = "not_initialized" if "MILESTONE STATE MISSING" in (result.stderr or result.stdout) else "state_unavailable"
            return _unavailable_project(project, state, detail)

        try:
            raw = json.loads(result.stdout)
            milestone = normalize_milestone(raw, milestone_id)
        except (json.JSONDecodeError, ValueError) as exc:
            return _unavailable_project(project, "state_unavailable", f"Invalid milestone status: {_clean_reason(exc)}")

        return {
            **project,
            "milestone": {key: value for key, value in milestone.items() if key != "classification"},
            "state": milestone["status"],
            "classification": milestone["classification"],
            "error": None,
        }

    def projects_payload(self) -> dict[str, Any]:
        try:
            projects, registry_errors = load_registry(self.registry_path)
        except RegistryError as exc:
            projects = []
            registry_errors = [f"CONFIGURATION ERROR: {exc}"]

        normalized = [self._status_for(project) for project in projects]
        summary = {
            "projects": len(normalized),
            "active": sum(item["classification"] == "active" for item in normalized),
            "attention": sum(item["classification"] == "attention" for item in normalized),
            "complete": sum(item["classification"] == "complete" for item in normalized),
        }
        return {
            "schema_version": 1,
            "generated_at": utc_now(),
            "summary": summary,
            "projects": normalized,
            "registry_errors": registry_errors,
        }


def make_handler(service: DashboardService, static_root: Path = DEFAULT_STATIC_ROOT) -> type[BaseHTTPRequestHandler]:
    class DashboardHandler(BaseHTTPRequestHandler):
        server_version = "GameFoundryDashboard/1"

        def _headers(self, status: HTTPStatus, content_type: str, length: int) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(length))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:")
            self.end_headers()

        def _send_bytes(self, status: HTTPStatus, content_type: str, body: bytes) -> None:
            self._headers(status, content_type, len(body))
            self.wfile.write(body)

        def _send_json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            self._send_bytes(status, "application/json; charset=utf-8", body)

        def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
            path = urlsplit(self.path).path
            if path == "/api/projects":
                self._send_json(HTTPStatus.OK, service.projects_payload())
                return
            if path == "/api/health":
                self._send_json(HTTPStatus.OK, {"status": "ok", "schema_version": 1, "read_only": True})
                return

            static_files = {
                "/": ("index.html", "text/html; charset=utf-8"),
                "/app.js": ("app.js", "text/javascript; charset=utf-8"),
                "/styles.css": ("styles.css", "text/css; charset=utf-8"),
            }
            target = static_files.get(path)
            if target is None:
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})
                return
            try:
                body = (static_root / target[0]).read_bytes()
            except OSError:
                self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "Dashboard asset unavailable"})
                return
            self._send_bytes(HTTPStatus.OK, target[1], body)

        def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
            self._send_json(HTTPStatus.METHOD_NOT_ALLOWED, {"error": "Dashboard is read-only"})

        do_PUT = do_POST
        do_PATCH = do_POST
        do_DELETE = do_POST

        def log_message(self, format: str, *args: object) -> None:
            print(f"{self.address_string()} - {format % args}")

    return DashboardHandler


def port_number(value: str) -> int:
    try:
        port = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("port must be an integer") from exc
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError("port must be between 1 and 65535")
    return port


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the local read-only Game Foundry dashboard.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8787, type=port_number)
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), make_handler(DashboardService()))
    print("GAME FOUNDRY DASHBOARD", flush=True)
    print(f"http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
