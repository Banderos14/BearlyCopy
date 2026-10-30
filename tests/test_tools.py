"""Phase 5 (stage 5.1/5.3): observed tool results and turn notifications.

The real turn in tests/fixtures/turns/real_desktop_tool_turn.json was
captured in a sandbox Claude Desktop session (HOOKS_RESEARCH §3, 2026-10-30)
and redacted.
"""

import json
import unittest

from helpers import FIXTURES, IsolatedTestCase

from prompt_relay import tools
from prompt_relay.correlation import STATUS_STOPPED, build_turns
from prompt_relay.events import from_record


def real_turn():
    return json.loads((FIXTURES / "turns" / "real_desktop_tool_turn.json").read_text(encoding="utf-8"))["events"]


class ReduceTests(unittest.TestCase):
    def test_classification(self):
        cases = {
            "swift test --filter X": "test", "cd macos && swift test": "test", "scripts/check.sh": "test",
            "PYTHONS=python3 scripts/check.sh": "test", "python3 -m unittest discover -s tests": "test",
            "swift test 2>&1 | tail -5": "test", "xcodebuild -scheme App build": "build", "make": "build",
            "git status --short": "git", "ls -la": "other", "echo pytest": "other", "makefile-lint": "other",
        }
        for command, kind in cases.items():
            with self.subTest(command):
                self.assertEqual(tools.command_kind(command), kind)

    def test_compound_commands_are_marked(self):
        self.assertTrue(tools.has_compound("swift test | tail -5"))
        self.assertTrue(tools.has_compound("pytest || true"))
        self.assertTrue(tools.has_compound("pytest; echo done"))
        self.assertFalse(tools.has_compound("cd x && swift test"))
        self.assertFalse(tools.has_compound("python3 -c 'print(1|2)'"))

    def test_real_payloads_keep_only_allowed_fields(self):
        allowed = {"hook_event_name", "tool_name", "reduced", "session_id", "prompt_id", "tool_use_id", "agent_id",
                   "agent_type", "cwd", "duration_ms", "outcome", "kind", "compound", "command", "command_withheld",
                   "background", "exit_code", "output_tail", "tail_withheld", "path", "paths", "artifact"}
        for payload in real_turn():
            if payload["hook_event_name"] not in tools.TOOL_EVENTS:
                continue
            reduced = tools.reduce(payload)
            with self.subTest(payload["tool_name"]):
                self.assertLessEqual(set(reduced), allowed)
                text = json.dumps(reduced)
                for forbidden in ("originalFile", "structuredPatch", "new_string", "old_string", "stdout", "content",
                                  "transcript_path", "__artifact"):
                    self.assertNotIn(forbidden, text)

    def test_real_bash_outcomes(self):
        reduced = [tools.reduce(p) for p in real_turn() if p.get("tool_name") == "Bash"]
        failed = [r for r in reduced if r["outcome"] == "failed"]
        self.assertEqual(len(failed), 1)
        self.assertEqual(failed[0]["exit_code"], 3)
        # `… exit(2) | cat` was reported as a success: the pipe's last process.
        piped = [r for r in reduced if "| cat" in (r.get("command") or "")]
        self.assertEqual((piped[0]["outcome"], piped[0]["exit_code"], piped[0].get("compound")), ("ok", 0, 1))
        self.assertEqual(sum(1 for r in reduced if r.get("background") == 1), 1)
        self.assertEqual(sum(1 for r in reduced if r.get("agent_id")), 1)

    def test_real_artifact_and_shown_files(self):
        by_tool = {p["tool_name"]: tools.reduce(p) for p in real_turn() if p.get("tool_name") in ("Artifact", "SendUserFile")}
        art = by_tool["Artifact"]["artifact"]
        self.assertEqual(set(art), {"title", "url", "audience", "path", "version", "source_path"})
        self.assertEqual(art["audience"], "owner")
        self.assertTrue(by_tool["SendUserFile"]["paths"][0].endswith("red.png"))

    def test_secret_command_and_tail_are_withheld(self):
        payload = {"hook_event_name": "PostToolUseFailure", "tool_name": "Bash",
                   "tool_input": {"command": "API_TOKEN=abcdefgh12345678 pytest"},
                   "error": "Exit code 1\nFAILED\nexport SECRET=supersecretvalue123"}
        reduced = tools.reduce(payload)
        self.assertEqual(reduced["command_withheld"], "possible_secret")
        self.assertNotIn("command", reduced)
        self.assertEqual(reduced["tail_withheld"], "possible_secret")
        self.assertNotIn("supersecret", json.dumps(reduced))

    def test_failed_test_keeps_a_short_tail_only(self):
        output = "\n".join(f"line {i}" for i in range(500))
        reduced = tools.reduce({"hook_event_name": "PostToolUseFailure", "tool_name": "Bash",
                                "tool_input": {"command": "swift test"}, "error": "Exit code 1\n" + output})
        self.assertEqual(reduced["exit_code"], 1)
        self.assertEqual(reduced["output_tail"].splitlines(), [f"line {i}" for i in range(488, 500)])
        other = tools.reduce({"hook_event_name": "PostToolUseFailure", "tool_name": "Bash",
                              "tool_input": {"command": "ls nope"}, "error": "Exit code 1\n" + output})
        self.assertNotIn("output_tail", other)

    def test_long_command_is_not_stored(self):
        reduced = tools.reduce({"hook_event_name": "PostToolUse", "tool_name": "Bash",
                                "tool_input": {"command": "echo " + "x" * 2000}, "tool_response": {}})
        self.assertEqual(reduced["command_withheld"], "too_long")


class TurnLinkingTests(unittest.TestCase):
    def events(self):
        out = []
        for i, payload in enumerate(real_turn()):
            payload = dict(payload)
            if payload["hook_event_name"] in tools.TOOL_EVENTS:
                payload = tools.reduce(payload)
            ev = from_record({"payload": payload, "received_at": f"2026-10-30T10:00:{i:02d}.000000Z",
                              "received_at_epoch": 1793354400.0 + i})
            self.assertIsNotNone(ev)
            out.append(ev)
        return out

    def test_notifications_with_the_same_prompt_id_do_not_create_turns(self):
        # Regression (stage 5.1): a task notification and a subagent hand-back
        # arrive as UserPromptSubmit with the turn's prompt_id. They used to
        # become extra turns "awaiting response" after Claude had stopped.
        turns = build_turns(self.events())
        self.assertEqual(len(turns), 1)
        turn = turns[0]
        self.assertEqual(turn.status, STATUS_STOPPED)
        self.assertFalse(turn.trailing)
        self.assertEqual(len(turn.notifications), 2)
        self.assertTrue(turn.prompt.text.startswith("Background"))

    def test_all_tool_events_join_the_turn(self):
        unlinked = []
        turns = build_turns(self.events(), unlinked_tools=unlinked)
        self.assertEqual(len(turns[0].tools), 18)
        self.assertEqual(unlinked, [])
        self.assertEqual([p["path"].rsplit("/", 1)[-1] for p in tools.unique_paths(turns[0].tools)],
                         ["notes.md", "hooktest.html"])

    def test_tool_event_of_an_unknown_prompt_is_unlinked(self):
        events = self.events()
        stray = from_record({"payload": tools.reduce({"hook_event_name": "PostToolUse", "tool_name": "Bash",
                                                      "prompt_id": "never-captured", "tool_input": {"command": "ls"}}),
                             "received_at": "2026-10-30T11:00:00.000000Z"})
        unlinked = []
        build_turns(events + [stray], unlinked_tools=unlinked)
        self.assertEqual(len(unlinked), 1)

    def test_raw_tool_payload_is_never_read(self):
        self.assertIsNone(from_record({"payload": {"hook_event_name": "PostToolUse", "tool_name": "Write",
                                                   "tool_response": {"originalFile": "secret"}}}))


class HookStorageTests(IsolatedTestCase):
    def test_hook_stores_only_the_reduced_record(self):
        for payload in real_turn():
            payload = dict(payload, cwd=self.project, session_id="tool-turn")
            self.assertHookOk(self.hook(payload))
        raw = b"".join(p.read_bytes() for p in (self.home / "events").glob("*.jsonl"))
        for forbidden in (b"originalFile", b"structuredPatch", b"old_string", b"\"stdout\"", b"__artifact"):
            self.assertNotIn(forbidden, raw)
        doc = json.loads(self.cli("turns", "--json", "--session", "tool-turn").stdout)
        turns = doc["data"]["turns"]
        self.assertEqual(len(turns), 1)
        self.assertEqual(turns[0]["notification_count"], 2)
        self.assertEqual(turns[0]["observed"]["runs_exit_zero"], 0)  # no test/build commands in this turn
        self.assertEqual(turns[0]["observed"]["files_changed"], 2)
        show = json.loads(self.cli("show", "--json", "--session", "tool-turn").stdout)
        detail = show["data"]["turn"]["observed_detail"]
        self.assertEqual(len(detail["commands"]), 8)
        self.assertEqual([c["exit_code"] for c in detail["commands"] if c["outcome"] == "failed"], [3])
        self.assertEqual(len(detail["artifacts"]), 1)
        session = json.loads(self.cli("sessions", "--json").stdout)["data"]["sessions"][0]
        self.assertEqual(session["answered_count"], 1)
        self.assertFalse(session["running"])
        self.assertTrue(session["title"].startswith("Background"))
        self.assertEqual(session["claude_code_title"], "Prompt Relay 5.1 hook payload test")


class SessionTitleTests(unittest.TestCase):
    def test_display_title(self):
        from prompt_relay.api import display_title
        self.assertEqual(display_title('<pasted_content id="x">\nFix   the\ntests\n</pasted_content id="x">'), "Fix the tests")
        self.assertEqual(len(display_title("a" * 300)), 80)
        self.assertIsNone(display_title("  \n "))


if __name__ == "__main__":
    unittest.main()
