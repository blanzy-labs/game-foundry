from __future__ import annotations

import json
import subprocess
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from dashboard import server as dashboard


def project(
    project_id: str = "example-game",
    name: str = "Example Game",
    platforms: list[object] | None = None,
    active_milestone: str | None = None,
) -> dict[str, object]:
    return {
        "id": project_id,
        "name": name,
        "platforms": ["Web"] if platforms is None else platforms,
        "active_milestone": active_milestone,
    }


def milestone_payload(
    milestone_id: str = "GF-TEST-001",
    passed: int = 2,
    total: int = 3,
    status: str = "active",
) -> dict[str, object]:
    states = {
        f"TASK-{index + 1}": {"status": "pass" if index < passed else "ready", "attempts": 0}
        for index in range(total)
    }
    return {
        "milestone_id": milestone_id,
        "title": "Fixture Milestone",
        "status": status,
        "tasks": states,
        "progress": {"passed": passed, "total": total},
        "next": "MILESTONE_COMPLETE" if passed == total else "NEXT_TASK=TASK-3",
        "unknown_future_field": True,
    }


class RegistryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.registry = Path(self.temporary_directory.name) / "projects.json"

    def write_registry(self, projects: list[object], **extra: object) -> None:
        payload = {"schema_version": 1, "projects": projects, **extra}
        self.registry.write_text(json.dumps(payload), encoding="utf-8")

    def test_valid_project_registry_parsing_ignores_unknown_fields(self) -> None:
        entry = {**project(), "unknown": "allowed"}
        self.write_registry([entry], top_level_unknown=True)

        projects, errors = dashboard.load_registry(self.registry)

        self.assertEqual(errors, [])
        self.assertEqual(projects[0]["name"], "Example Game")
        self.assertNotIn("unknown", projects[0])

    def test_duplicate_project_ids_are_reported_and_skipped(self) -> None:
        self.write_registry([project(), project(name="Duplicate")])

        projects, errors = dashboard.load_registry(self.registry)

        self.assertEqual(len(projects), 1)
        self.assertEqual(len(errors), 1)
        self.assertIn("duplicates", errors[0])

    def test_invalid_platform_values_are_reported_and_skipped(self) -> None:
        self.write_registry([project(platforms=["Linux", ""]), project("valid", "Valid", ["Web"])])

        projects, errors = dashboard.load_registry(self.registry)

        self.assertEqual([item["id"] for item in projects], ["valid"])
        self.assertIn("invalid platforms", errors[0])

    def test_multiple_projects_and_multiple_platforms(self) -> None:
        self.write_registry(
            [
                project("desktop", "Desktop Game", ["Linux", "Windows"]),
                project("browser", "Browser Game", ["Web"]),
            ]
        )

        projects, errors = dashboard.load_registry(self.registry)

        self.assertEqual(errors, [])
        self.assertEqual(len(projects), 2)
        self.assertEqual(projects[0]["platforms"], ["Linux", "Windows"])


class ServiceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.registry = Path(self.temporary_directory.name) / "projects.json"

    def write_registry(self, entries: list[dict[str, object]]) -> None:
        self.registry.write_text(json.dumps({"schema_version": 1, "projects": entries}), encoding="utf-8")

    def test_project_without_active_milestone_is_not_initialized(self) -> None:
        self.write_registry([project()])

        payload = dashboard.DashboardService(self.registry, runner=lambda *args, **kwargs: self.fail("runner called")).projects_payload()

        self.assertEqual(payload["projects"][0]["state"], "not_initialized")
        self.assertIsNone(payload["projects"][0]["milestone"])
        self.assertNotEqual(payload["projects"][0]["state"], "pass")

    def test_successful_milestone_status_uses_argument_array(self) -> None:
        self.write_registry([project(active_milestone="GF-TEST-001")])
        calls: list[tuple[object, dict[str, object]]] = []

        def runner(arguments: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
            calls.append((arguments, kwargs))
            return subprocess.CompletedProcess(arguments, 0, json.dumps(milestone_payload()), "")

        payload = dashboard.DashboardService(self.registry, runner=runner).projects_payload()
        result = payload["projects"][0]

        self.assertEqual(result["milestone"]["passed"], 2)
        self.assertEqual(result["milestone"]["total"], 3)
        self.assertEqual(result["milestone"]["tasks"]["TASK-1"], "pass")
        self.assertIsInstance(calls[0][0], list)
        self.assertEqual(calls[0][0][1:], ["status", "GF-TEST-001", "--json"])
        self.assertEqual(calls[0][1]["timeout"], dashboard.STATUS_TIMEOUT_SECONDS)

    def test_missing_milestone_state_is_not_pass(self) -> None:
        self.write_registry([project(active_milestone="GF-MISSING-001")])

        def runner(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
            return subprocess.CompletedProcess([], 1, "", "MILESTONE STATE MISSING: GF-MISSING-001")

        result = dashboard.DashboardService(self.registry, runner=runner).projects_payload()["projects"][0]

        self.assertEqual(result["state"], "not_initialized")
        self.assertEqual(result["classification"], "attention")
        self.assertIsNone(result["milestone"])

    def test_malformed_game_foundry_json_is_unavailable(self) -> None:
        self.write_registry([project(active_milestone="GF-BAD-001")])
        runner = lambda *args, **kwargs: subprocess.CompletedProcess([], 0, "{not-json", "")

        result = dashboard.DashboardService(self.registry, runner=runner).projects_payload()["projects"][0]

        self.assertEqual(result["state"], "state_unavailable")
        self.assertIn("Invalid milestone status", result["error"])

    def test_milestone_command_timeout_is_unavailable(self) -> None:
        self.write_registry([project(active_milestone="GF-SLOW-001")])

        def runner(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
            raise subprocess.TimeoutExpired(cmd=args[0], timeout=5)

        result = dashboard.DashboardService(self.registry, runner=runner).projects_payload()["projects"][0]

        self.assertEqual(result["state"], "state_unavailable")
        self.assertIn("timed out", result["error"])

    def test_percentage_calculation_rounds_half_up(self) -> None:
        self.assertEqual(dashboard.calculate_percent(5, 8), 63)
        self.assertEqual(dashboard.calculate_percent(3, 4), 75)

    def test_zero_total_tasks_has_unavailable_percentage(self) -> None:
        normalized = dashboard.normalize_milestone(milestone_payload(passed=0, total=0), "GF-TEST-001")

        self.assertEqual(normalized["passed"], 0)
        self.assertEqual(normalized["total"], 0)
        self.assertIsNone(normalized["percent"])

    def test_multiple_project_statuses_are_normalized_independently(self) -> None:
        self.write_registry(
            [
                project("one", "One", ["Linux"], "GF-ONE-001"),
                project("two", "Two", ["Web", "Windows"], None),
            ]
        )

        def runner(arguments: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
            return subprocess.CompletedProcess(arguments, 0, json.dumps(milestone_payload("GF-ONE-001", 1, 2)), "")

        payload = dashboard.DashboardService(self.registry, runner=runner).projects_payload()

        self.assertEqual(len(payload["projects"]), 2)
        self.assertEqual(payload["summary"], {"projects": 2, "active": 1, "attention": 1, "complete": 0})


class HttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary_directory = tempfile.TemporaryDirectory()
        registry = Path(cls.temporary_directory.name) / "projects.json"
        registry.write_text(json.dumps({"schema_version": 1, "projects": [project()]}), encoding="utf-8")
        service = dashboard.DashboardService(registry, runner=lambda *args, **kwargs: None)
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), dashboard.make_handler(service))
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.httpd.server_port}"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.thread.join(timeout=2)
        cls.temporary_directory.cleanup()

    def get(self, path: str) -> tuple[int, str, bytes]:
        with urlopen(f"{self.base_url}{path}", timeout=2) as response:
            return response.status, response.headers.get_content_type(), response.read()

    def test_api_health_response(self) -> None:
        status, content_type, body = self.get("/api/health")
        payload = json.loads(body)

        self.assertEqual(status, 200)
        self.assertEqual(content_type, "application/json")
        self.assertEqual(payload, {"status": "ok", "schema_version": 1, "read_only": True})

    def test_static_dashboard_responses(self) -> None:
        for path, expected_type, marker in [
            ("/", "text/html", b"Game Foundry"),
            ("/app.js", "text/javascript", b"REFRESH_INTERVAL_MS"),
            ("/styles.css", "text/css", b"--copper"),
        ]:
            with self.subTest(path=path):
                status, content_type, body = self.get(path)
                self.assertEqual(status, 200)
                self.assertEqual(content_type, expected_type)
                self.assertIn(marker, body)

    def test_projects_api_response(self) -> None:
        status, _, body = self.get("/api/projects")
        payload = json.loads(body)

        self.assertEqual(status, 200)
        self.assertEqual(payload["schema_version"], 1)
        self.assertEqual(payload["projects"][0]["name"], "Example Game")

    def test_no_mutation_routes(self) -> None:
        for path in ["/transition", "/execute", "/approve", "/milestone", "/api/projects"]:
            with self.subTest(method="POST", path=path):
                request = Request(f"{self.base_url}{path}", method="POST", data=b"{}")
                with self.assertRaises(HTTPError) as error:
                    urlopen(request, timeout=2)
                self.assertEqual(error.exception.code, 405)
                error.exception.close()

        for path in ["/transition", "/execute", "/approve", "/milestone"]:
            with self.subTest(method="GET", path=path):
                with self.assertRaises(HTTPError) as error:
                    urlopen(f"{self.base_url}{path}", timeout=2)
                self.assertEqual(error.exception.code, 404)
                error.exception.close()


if __name__ == "__main__":
    unittest.main()
