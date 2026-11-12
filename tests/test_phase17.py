"""Phase 17: the JSON API contract against the *current* schema.

The owner supplied an older ``api-v1.schema.json`` snapshot that lacks the
Global Capture additions (``settings.capture``, ``excluded``). The
repository's schema is the authoritative one: these tests validate the
Core's real output against it in every capture mode, and fail if the schema
ever loses those definitions (for example by being overwritten with an
older copy).
"""

from __future__ import annotations

import json
from pathlib import Path

from helpers import REPO, IsolatedTestCase
from jsonschema_lite import validate_response

from prompt_relay import __version__, api, integration

SCHEMA_PATH = REPO / "docs" / "api" / "api-v1.schema.json"
SCHEMA = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))


def prompt(session: str, cwd: str, pid: str) -> dict:
    return {"hook_event_name": "UserPromptSubmit", "session_id": session, "cwd": cwd, "prompt": "Задача 🐻", "prompt_id": pid}


def stop(session: str, cwd: str, text: str, pid: str) -> dict:
    return {"hook_event_name": "Stop", "session_id": session, "cwd": cwd, "prompt_id": pid,
            "last_assistant_message": text, "stop_hook_active": False}


class ApiContractTests(IsolatedTestCase):
    def mkrepo(self, name: str) -> str:
        path = self.tmp / "repos" / name
        (path / ".git").mkdir(parents=True)
        (path / ".git" / "HEAD").write_text("ref: refs/heads/main\n")
        return str(path.resolve())

    def doc(self, *args: str) -> dict:
        proc = self.cli(*args, "--json")
        self.assertEqual(proc.stderr, b"", args)
        doc = json.loads(proc.stdout)
        self.assertEqual(validate_response(doc, SCHEMA), [], args)
        self.assertEqual(doc["api_version"], 1)
        return doc

    def turn(self, session: str, cwd: str, text: str, pid: str = "p1") -> None:
        self.assertHookOk(self.hook(prompt(session, cwd, pid)))
        self.assertHookOk(self.hook(stop(session, cwd, text, pid)))

    def test_schema_is_the_current_one_with_global_capture(self) -> None:
        defs = SCHEMA["$defs"]
        self.assertEqual(SCHEMA["x-command-data"]["capture"], "capture_data")
        text = SCHEMA_PATH.read_text(encoding="utf-8")
        for needed in ('"capture_data"', '"excluded"', '"excluded_projects"', '"minimum_plugin_version"', '"resume_mode"'):
            self.assertIn(needed, text, "the schema lost a Global Capture definition (an older snapshot?)")
        self.assertIn("capture_data", defs)
        self.assertEqual(api.API_VERSION, 1)

    def test_real_output_validates_in_every_capture_mode(self) -> None:
        a, b, c = self.mkrepo("a"), self.mkrepo("b"), self.mkrepo("c")
        self.cli("enable", a)
        self.turn("sa", a, "A answer ✅")
        steps = [("selected", ()), ("global", ("capture", "--global")), ("excluded", ("capture", "--exclude", c)),
                 ("paused", ("capture", "--pause")), ("resumed", ("capture", "--resume"))]
        for name, change in steps:
            with self.subTest(mode=name):
                if change:
                    self.doc(*change)
                if name == "global":
                    self.turn("sb", b, "B answer")   # a repository never switched on
                    self.turn("sc", c, "C answer")
                projects = self.doc("projects")["data"]
                capture = projects["settings"]["capture"]
                self.assertEqual(set(capture) >= {"mode", "excluded_projects", "enabled_projects", "minimum_plugin_version"}, True)
                self.assertEqual(capture["minimum_plugin_version"], integration.MIN_POLICY_PLUGIN)
                for row in projects["projects"]:
                    self.assertIn("excluded", row)
                if name in ("excluded", "paused", "resumed"):
                    rows = {p["path"]: p for p in projects["projects"]}
                    self.assertTrue(rows[c]["excluded"])
                    self.assertFalse(rows[c]["capture_enabled"])
                    self.assertEqual(capture["excluded_projects"], [c])
                self.assertEqual(capture["mode"], {"selected": "selected", "global": "global", "excluded": "global",
                                                   "paused": "paused", "resumed": "global"}[name])
                for command in (("sessions",), ("results", "--limit", "20"), ("doctor", "--no-project"), ("capture",),
                                ("turns", "--session", "sa"), ("show", "--session", "sa"), ("context", "--session", "sa")):
                    self.doc(*command)
        # Paused stored nothing; resumed stores again; the excluded project never does.
        self.cli("capture", "--pause")
        self.turn("sa", a, "while paused", pid="p2")
        self.cli("capture", "--resume")
        self.turn("sa", a, "after resume", pid="p3")
        self.turn("sc", c, "excluded", pid="p2")
        turns = self.doc("turns", "--session", "sa")["data"]["turns"]
        self.assertEqual([t["final_response"]["preview"] for t in turns if t["final_response"]], ["A answer ✅", "after resume"])
        self.assertEqual(len(self.doc("turns", "--session", "sc")["data"]["turns"]), 1)

    def test_latest_answer_time_is_the_completion_time_not_the_last_event(self) -> None:
        """`last_turn.answered_at` is what the app orders Latest by: a later
        tool event moves `last_event_at`, never the answer's time."""
        a = self.mkrepo("a")
        self.cli("enable", a)
        self.turn("s", a, "final")
        before = {s["session_id"]: s for s in self.doc("sessions")["data"]["sessions"]}["s"]
        answered = before["last_turn"]["answered_at"]
        self.assertTrue(answered)
        self.assertHookOk(self.hook({"hook_event_name": "PostToolUse", "session_id": "s", "cwd": a, "prompt_id": "p1",
                                     "tool_name": "Bash", "tool_input": {"command": "true"}, "tool_response": {"exit_code": 0}}))
        after = {s["session_id"]: s for s in self.doc("sessions")["data"]["sessions"]}["s"]
        self.assertEqual(after["last_turn"]["answered_at"], answered)
        self.assertGreaterEqual(after["last_event_at"], before["last_event_at"])

    def test_versions_are_reported_consistently(self) -> None:
        plugin = json.loads((REPO / "plugin" / ".claude-plugin" / "plugin.json").read_text())
        doctor = self.doc("doctor", "--no-project")["data"]
        self.assertEqual(doctor["core"]["prompt_relay_version"], __version__)
        self.assertEqual(plugin["version"], __version__)
        self.assertEqual(self.doc("capture")["data"]["minimum_plugin_version"], "0.8.0",
                         "hooks are unchanged since 0.8.0: a 0.8.0 plugin still honors capture modes")
