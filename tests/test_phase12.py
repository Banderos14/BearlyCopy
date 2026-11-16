"""Phase 12: local agent profiles and the Results Inbox (Core side).

Profiles come from the agent's own config-home variable (CLAUDE_CONFIG_DIR,
CODEX_HOME), never from credentials; equal native session ids of two homes
never share a history; records written before Phase 12 keep working; the
``results`` command lists final results once each, newest first.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

from helpers import IsolatedTestCase

from prompt_relay import profiles

SHELL = [{"id": "b1", "type": "shell", "status": "running", "description": "swift test", "command": "swift test"}]
NOTE = "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>"


class ProfileTests(IsolatedTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.work = str(self.tmp / "home" / ".claude-work")
        self.personal_env = dict(self.env)                       # default ~/.claude
        self.work_env = dict(self.env, CLAUDE_CONFIG_DIR=self.work)

    def say(self, sid, pid, prompt, answer, env, project=None):
        project = project or self.project
        self.assertHookOk(self.hook({"hook_event_name": "UserPromptSubmit", "session_id": sid, "prompt_id": pid,
                                     "cwd": project, "prompt": prompt}, env=env))
        if answer is not None:
            self.assertHookOk(self.hook({"hook_event_name": "Stop", "session_id": sid, "prompt_id": pid, "cwd": project,
                                         "stop_hook_active": False, "last_assistant_message": answer}, env=env))

    def sessions(self):
        return json.loads(self.cli("sessions", "--json").stdout)["data"]["sessions"]

    def results(self, *extra):
        doc = json.loads(self.cli("results", "--json", *extra).stdout)
        self.assertTrue(doc["ok"], doc)
        return doc["data"]

    # -- identity -------------------------------------------------------------

    def test_default_home_profile_is_stable_and_has_no_user_name(self) -> None:
        p = profiles.from_env("claude_code", {"HOME": "/Users/someone"})
        self.assertEqual((p["id"], p["basis"], p["default"], p["hint"]), ("cc-default", "default_home", True, "~/.claude"))
        same = profiles.from_env("claude_code", {"HOME": "/Users/someone", "CLAUDE_CONFIG_DIR": "/Users/someone/.claude"})
        self.assertEqual(same["id"], "cc-default", "naming the default folder is still the default profile")
        other = profiles.from_env("claude_code", {"HOME": "/Users/someone", "CLAUDE_CONFIG_DIR": "/Users/someone/.claude-work"})
        self.assertTrue(other["id"].startswith("cc-") and len(other["id"]) == 19)
        self.assertEqual(other["hint"], "~/.claude-work")
        outside = profiles.from_env("codex", {"HOME": "/Users/someone", "CODEX_HOME": "/Volumes/x/agents/codex-qa"})
        self.assertEqual(outside["hint"], "codex-qa", "outside the home folder only the last component is kept")
        for p in (other, outside):
            self.assertNotIn("someone", json.dumps(p))

    def test_relative_or_empty_home_variable_is_not_a_profile_claim(self) -> None:
        for raw in ("", "   ", "relative/dir"):
            self.assertEqual(profiles.from_env("claude_code", {"HOME": "/Users/x", "CLAUDE_CONFIG_DIR": raw})["id"], "cc-default")

    def test_two_claude_profiles_in_one_project_stay_apart(self) -> None:
        self.say("same-uuid", "p1", "Fix the login bug", "Personal answer", self.personal_env)
        self.say("same-uuid", "p1", "Fix the login bug", "Work answer", self.work_env)
        rows = self.sessions()
        self.assertEqual(len(rows), 2, "an equal native id from another config home is another conversation")
        by_profile = {r["profile"]["id"]: r for r in rows}
        self.assertIn("cc-default", by_profile)
        work = next(r for pid, r in by_profile.items() if pid != "cc-default")
        self.assertEqual(by_profile["cc-default"]["session_key"], "same-uuid", "the default home keeps its plain key")
        self.assertNotEqual(work["session_key"], "same-uuid")
        self.assertEqual(work["native_session_id"], "same-uuid")
        self.assertEqual(work["profile"]["hint"], "~/.claude-work")
        # Same title, different profile: still two results, each with its own text.
        answers = {r["profile"]["id"]: r["response"]["preview"] for r in self.results()["results"]}
        self.assertEqual(answers["cc-default"], "Personal answer")
        self.assertEqual(answers[work["profile"]["id"]], "Work answer")
        shown = json.loads(self.cli("show", "--session", work["session_key"], "--json").stdout)["data"]["turn"]
        self.assertEqual(shown["final_response"]["text"], "Work answer")

    def test_copy_with_context_of_a_work_profile_result_is_that_result(self) -> None:
        self.say("same-uuid", "p1", "Fix the login bug", "Personal answer", self.personal_env)
        self.say("same-uuid", "p1", "Fix the login bug", "Work answer", self.work_env)
        work = next(r for r in self.results()["results"] if r["profile"]["id"] != "cc-default")
        doc = json.loads(self.cli("context", "--session", work["session_key"], "--turn", str(work["turn"]), "--json").stdout)
        self.assertTrue(doc["ok"], doc)
        self.assertIn("Work answer", doc["data"]["text"])
        self.assertNotIn("Personal answer", doc["data"]["text"], "never another profile's answer")
        self.assertEqual(self.cli("copy-context", "--session", work["session_key"], "--turn", "1").returncode, 0)
        self.assertIn(b"Work answer", self.clip.read_bytes())
        self.assertNotIn(b"Personal answer", self.clip.read_bytes())

    def test_payload_is_stored_verbatim_and_profile_lives_in_the_envelope(self) -> None:
        self.say("sid-1", "p1", "Q", "A", self.work_env)
        key = self.sessions()[0]["session_key"]
        rec = self.records(key)[0]
        self.assertEqual(rec["payload"]["session_id"], "sid-1", "the agent's payload is never rewritten")
        self.assertNotIn("agent_profile", rec["payload"])
        self.assertEqual(rec["agent_profile"]["basis"], "config_dir")
        self.assertEqual(rec["native_session_id"], "sid-1")

    def test_records_without_a_profile_still_read_as_unassigned(self) -> None:
        # A pre-Phase 12 record: no agent_profile in the envelope.
        events = self.home / "events"
        events.mkdir(parents=True, exist_ok=True)
        now = time.time()
        lines = []
        for i, (event, field, text) in enumerate([("UserPromptSubmit", "prompt", "Old request"),
                                                  ("Stop", "last_assistant_message", "Old answer")]):
            payload = {"hook_event_name": event, "session_id": "legacy", "prompt_id": "p", "cwd": self.project, field: text}
            lines.append(json.dumps({"schema": 1, "record_id": f"r{i}", "received_at": "2026-10-01T10:00:0%d.000000Z" % i,
                                     "received_at_epoch": now - 100 + i, "hook_event_name": event, "session_id": "legacy",
                                     "fingerprint": f"sha256:{i}", "context": {}, "payload": payload}))
        (events / "legacy.jsonl").write_text("\n".join(lines) + "\n")
        os.chmod(events / "legacy.jsonl", 0o600)
        row = self.sessions()[0]
        self.assertNotIn("profile", row)
        self.assertEqual(row["session_key"], "legacy", "migration rewrites nothing")
        data = self.results("--profile", "unassigned")
        self.assertEqual([r["response"]["preview"] for r in data["results"]], ["Old answer"])
        # A new default-profile answer in another session lands next to it; nothing is lost.
        self.say("new", "p1", "New request", "New answer", self.personal_env)
        self.assertEqual(self.results()["total"], 2)
        self.assertEqual(self.results("--profile", "cc-default")["total"], 1)

    def test_codex_profile_from_codex_home_and_from_older_installation_id(self) -> None:
        xcode = str(self.tmp / "home" / "Library" / "Developer" / "Xcode" / "CodingAssistant" / "codex")
        env = dict(self.env, PROMPT_RELAY_PROVIDER="codex", PROMPT_RELAY_HOST="xcode", CODEX_HOME=xcode)
        self.assertHookOk(self.hook({"hook_event_name": "UserPromptSubmit", "session_id": "n1", "turn_id": "t1",
                                     "cwd": self.project, "prompt": "Build it"}, env=env))
        self.assertHookOk(self.hook({"hook_event_name": "Stop", "session_id": "n1", "turn_id": "t1", "cwd": self.project,
                                     "last_assistant_message": "Built."}, env=env))
        row = self.sessions()[0]
        self.assertEqual(row["profile"]["hint"], "~/Library/Developer/Xcode/CodingAssistant/codex")
        expected = row["profile"]["id"]
        # The same session read without the envelope field maps through installation_id.
        legacy = profiles.from_installation(row["source"]["installation_id"], {"HOME": self.env["HOME"]})
        self.assertEqual(legacy["id"], expected)
        default = profiles.from_installation(profiles.digest(profiles.default_real("codex", {"HOME": self.env["HOME"]})),
                                             {"HOME": self.env["HOME"]})
        self.assertEqual(default["id"], "cx-default")

    def test_forged_profile_fields_are_not_read(self) -> None:
        self.assertIsNone(profiles.valid({"id": "cc-../../etc", "provider": "claude_code"}))
        self.assertIsNone(profiles.valid({"id": "cx-default", "provider": "claude_code"}))
        self.assertIsNone(profiles.valid("cc-default"))
        self.assertEqual(profiles.valid({"id": "cc-default", "provider": "claude_code", "basis": "evil"})["basis"], "config_dir")

    # -- results --------------------------------------------------------------

    def test_codex_and_claude_in_one_list_newest_first(self) -> None:
        self.say("c1", "p1", "Claude task", "Claude done", self.personal_env)
        time.sleep(0.01)
        env = dict(self.env, PROMPT_RELAY_PROVIDER="codex", PROMPT_RELAY_HOST="terminal")
        self.assertHookOk(self.hook({"hook_event_name": "UserPromptSubmit", "session_id": "x1", "turn_id": "t1",
                                     "cwd": self.project_b, "prompt": "Codex task"}, env=env))
        self.assertHookOk(self.hook({"hook_event_name": "Stop", "session_id": "x1", "turn_id": "t1", "cwd": self.project_b,
                                     "last_assistant_message": "Codex done"}, env=env))
        time.sleep(0.01)
        self.say("w1", "p1", "Work task", "Work done", self.work_env)
        data = self.results()
        self.assertEqual([r["response"]["preview"] for r in data["results"]], ["Work done", "Codex done", "Claude done"])
        self.assertEqual(data["results"][1]["source"]["provider"], "codex")
        self.assertEqual(data["results"][1]["profile"]["id"], "cx-default")
        self.assertEqual([r["response"]["preview"] for r in self.results("--provider", "codex")["results"]], ["Codex done"])
        self.assertEqual(self.results("--limit", "1")["total"], 3)
        self.assertEqual(len(self.results("--limit", "1")["results"]), 1)

    def test_technical_turns_make_one_result_and_redelivery_none(self) -> None:
        env = self.personal_env
        self.assertHookOk(self.hook({"hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt_id": "p0",
                                     "cwd": self.project, "prompt": "Run the tests"}, env=env))
        stop = {"hook_event_name": "Stop", "session_id": "s", "prompt_id": "p0", "cwd": self.project,
                "stop_hook_active": False, "last_assistant_message": "Running in background", "background_tasks": SHELL}
        self.assertHookOk(self.hook(stop, env=env))
        self.assertHookOk(self.hook(stop, env=env))            # redelivered
        self.assertHookOk(self.hook({"hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt_id": "p1",
                                     "cwd": self.project, "prompt": NOTE}, env=env))
        final = {"hook_event_name": "Stop", "session_id": "s", "prompt_id": "p1", "cwd": self.project,
                 "stop_hook_active": False, "last_assistant_message": "All tests passed", "background_tasks": []}
        self.assertHookOk(self.hook(final, env=env))
        self.assertHookOk(self.hook(final, env=env))           # redelivered
        rows = self.results()["results"]
        self.assertEqual(len(rows), 1, "an intermediate Stop is not a result; a redelivery is not a second one")
        self.assertEqual(rows[0]["response"]["preview"], "All tests passed")
        self.assertEqual(rows[0]["request"], {"turn": 1, "own": False, "display_preview": "Run the tests", "char_count": 13},
                         "a background follow-up is named by the request that started the task")

    def test_usage_errors(self) -> None:
        for bad in ("0", "10001"):
            doc = json.loads(self.cli("results", "--json", "--limit", bad).stdout)
            self.assertEqual(doc["error"]["code"], "usage_error")

    def test_results_scale_to_three_thousand(self) -> None:
        # Synthetic, isolated: 60 sessions × 50 final answers written directly
        # (no hooks, no AI). One `results` call must stay well under a second
        # or two on this Mac; the bound is generous to avoid flakiness.
        events = self.home / "events"
        events.mkdir(parents=True, exist_ok=True)
        base = time.time() - 86_400
        n = 0
        for s in range(60):
            lines = []
            for t in range(50):
                n += 1
                for kind, field, text in (("UserPromptSubmit", "prompt", f"task {s}-{t}"),
                                          ("Stop", "last_assistant_message", "x" * 2000)):
                    payload = {"hook_event_name": kind, "session_id": f"s{s}", "prompt_id": f"p{t}",
                               "cwd": self.project, field: text}
                    epoch = base + n + (0.5 if kind == "Stop" else 0)
                    lines.append(json.dumps({"schema": 1, "record_id": f"{s}-{t}-{kind}",
                                             "received_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(epoch)) + ".%06dZ" % int((epoch % 1) * 1e6),
                                             "received_at_epoch": epoch, "hook_event_name": kind, "session_id": f"s{s}",
                                             "fingerprint": f"sha256:{s}-{t}-{kind}", "context": {}, "payload": payload}))
            p = Path(events / f"s{s}.jsonl")
            p.write_text("\n".join(lines) + "\n")
            os.chmod(p, 0o600)
        started = time.perf_counter()
        data = self.results("--limit", "200")
        elapsed = time.perf_counter() - started
        self.assertEqual(data["total"], 3000)
        self.assertEqual(len(data["results"]), 200)
        self.assertEqual(data["results"][0]["response"]["char_count"], 2000)
        self.assertEqual(data["results"][0]["session_key"], "s59")
        stamps = [r["answered_at"] for r in data["results"]]
        self.assertEqual(stamps, sorted(stamps, reverse=True))
        self.assertLess(elapsed, 8.0, f"results took {elapsed:.2f}s")


class VersionTests(IsolatedTestCase):
    """0.4.0 (Phase 12): one version everywhere; the JSON API stays v1."""

    def test_core_plugin_and_xcode_versions_agree_and_api_stays_v1(self) -> None:
        import re
        from prompt_relay import __version__, api
        repo = Path(__file__).resolve().parent.parent
        plugin = json.loads((repo / "plugin" / ".claude-plugin" / "plugin.json").read_text())
        pbx = (repo / "macos" / "Xcode" / "PromptRelay.xcodeproj" / "project.pbxproj").read_text()
        self.assertEqual(__version__, "0.9.3")   # 0.9.3: tour second chance (0.9.2: screenshot mode picker, Quick Tour bear (0.9.0: JSON-form secret pattern); hooks, config schema, API v1 and Context Pack v1 unchanged since 0.8.0
        self.assertEqual(plugin["version"], __version__)
        self.assertEqual(set(re.findall(r"MARKETING_VERSION = ([0-9.]+);", pbx)), {__version__})
        self.assertEqual(set(re.findall(r"CURRENT_PROJECT_VERSION = ([0-9.]+);", pbx)), {__version__})
        self.assertEqual(api.API_VERSION, 1)
        out = self.cli("--version")
        self.assertIn(b"prompt-relay 0.9.3", out.stdout + out.stderr)
        # The Context Pack format is versioned apart from the app (ADR-026).
        from prompt_relay import context_pack
        self.assertEqual((context_pack.FORMAT, context_pack.FORMAT_VERSION), ("prompt-relay-context-pack", 1))
        swift = (repo / "macos" / "Sources" / "PromptRelayKit" / "Models" / "ContextPackModels.swift").read_text()
        self.assertIn('static let name = "prompt-relay-context-pack"', swift)
        self.assertIn("static let version = 1", swift)
        doc = json.loads(self.cli("results", "--json").stdout)
        self.assertEqual(doc["api_version"], 1)
