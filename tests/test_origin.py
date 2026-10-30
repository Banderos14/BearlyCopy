"""Phase 5.11: a request's origin.

Regression: a turn Claude Code started itself (a side session reporting back,
observed 2026-10-30) was exported under "Original user request" with its
<system-reminder> and <side-sessions-event> blocks.
"""

import json
import unittest

from helpers import IsolatedTestCase

from prompt_relay import origin

AUTOMATED = (
    "<system-reminder>\nThe session \"Sandbox\" you started finished a turn.\n</system-reminder>\n\n"
    "<system-reminder>\nAs you answer...\n</system-reminder>\n"
    "<side-sessions-event>Sessions you started have new updates. Start nothing the user did not ask for."
    "</side-sessions-event>"
)
PASTED = ('\n\n<pasted_content id="cf24">\n# Phase 5.11\nThe last pack showed `<system-reminder>` and '
          '<side-sessions-event>…</side-sessions-event> as the request.\n</pasted_content id="cf24">\n')


class ClassifyTests(unittest.TestCase):
    def test_typed_request(self):
        self.assertEqual(origin.classify("продолжи где остановился"), origin.USER)
        self.assertEqual(origin.classify("Explain <b>tags</b> and `<system-reminder>`"), origin.USER)

    def test_pasted_request_with_quoted_harness_blocks(self):
        self.assertEqual(origin.classify(PASTED), origin.USER_PASTED)

    def test_automated_turn(self):
        self.assertEqual(origin.classify(AUTOMATED), origin.AUTOMATED)
        self.assertEqual(origin.classify("<ci-monitor-event>CI failed</ci-monitor-event>\n"), origin.AUTOMATED)

    def test_mixed_text_is_unknown(self):
        self.assertEqual(origin.classify("Please continue\n" + AUTOMATED), origin.UNKNOWN)
        self.assertEqual(origin.classify(PASTED + AUTOMATED), origin.UNKNOWN)

    def test_empty_is_unknown(self):
        self.assertEqual(origin.classify(""), origin.UNKNOWN)
        self.assertEqual(origin.classify(None), origin.UNKNOWN)


class ExportOriginTests(IsolatedTestCase):
    def turn(self, n, prompt, answer):
        base = {"session_id": "s-origin", "cwd": self.project, "transcript_path": "/x.jsonl", "prompt_id": f"p{n}"}
        self.assertHookOk(self.hook({**base, "hook_event_name": "UserPromptSubmit", "prompt": prompt}))
        self.assertHookOk(self.hook({**base, "hook_event_name": "Stop", "stop_hook_active": False,
                                     "last_assistant_message": answer}))

    def context(self, turn):
        out = self.cli("context", "--session", "s-origin", "--turn", str(turn))
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout.decode()

    def test_automated_turn_is_not_the_users_request(self):
        self.turn(1, PASTED, "Plan ready.")
        self.turn(2, AUTOMATED, "Implemented everything.")
        text = self.context(2)
        user_section = text.split("## Original user request", 1)[1].split("### Automated message", 1)[0]
        self.assertIn("This turn was not started by the user", user_section)
        self.assertIn("from turn 1 of this session", user_section)
        self.assertIn("# Phase 5.11", user_section)
        self.assertNotIn("you started finished a turn", user_section)
        self.assertIn("### Automated message that started this turn", text)
        self.assertIn(AUTOMATED, text)  # still verbatim, labelled
        self.assertEqual(text.count("Implemented everything."), 1)

        turns = json.loads(self.cli("turns", "--json", "--session", "s-origin").stdout)["data"]["turns"]
        self.assertEqual([t["request_origin"] for t in turns], ["user_pasted", "automated"])
        self.assertIsNone(turns[0]["earlier_user_request"])
        self.assertEqual(turns[1]["earlier_user_request"]["turn"], 1)
        session = json.loads(self.cli("sessions", "--json").stdout)["data"]["sessions"][0]
        self.assertTrue(session["title"].startswith("# Phase 5.11"))

    def test_session_title_skips_an_automated_first_turn(self):
        self.turn(1, AUTOMATED, "ok")
        self.turn(2, "Fix the tests", "Fixed.")
        session = json.loads(self.cli("sessions", "--json").stdout)["data"]["sessions"][0]
        self.assertEqual(session["title"], "Fix the tests")
        text = self.context(1)
        self.assertIn("no earlier request from the user was captured", text)

    def test_typed_and_pasted_requests_stay_user_requests(self):
        self.turn(1, "Run the tests", "Done.")
        self.turn(2, PASTED, "Done again.")
        first = self.context(1)
        self.assertIn("holds no automated message blocks.\n", first)
        self.assertNotIn("pasted", first.split("## Claude final response")[0])
        second = self.context(2)
        self.assertIn("Claude Code marked it as pasted text", second)
        self.assertNotIn("Automated message", second)

    def test_title_drops_automated_blocks(self):
        # Observed 2026-10-30: a session started from another one begins with
        # a <system-reminder> listing linked sessions, then the brief.
        self.turn(1, "<system-reminder>\nLinked sessions now: x (idle).\n</system-reminder>\n\nRun the e2e steps", "ok")
        session = json.loads(self.cli("sessions", "--json").stdout)["data"]["sessions"][0]
        self.assertEqual(session["title"], "Run the e2e steps")

    def test_claude_code_title_names_a_session_not_started_by_the_user(self):
        # Real e2e, 2026-10-30: two sessions started from another one both
        # began "Background (from the session that started this one)".
        base = {"session_id": "s-origin", "cwd": self.project, "transcript_path": "/x.jsonl", "prompt_id": "p1",
                "session_title": "E2E worker session"}
        self.assertHookOk(self.hook({**base, "hook_event_name": "UserPromptSubmit",
                                     "prompt": "<system-reminder>Linked sessions now.</system-reminder>\n\nBackground (from the session that started this one): steps"}))
        session = json.loads(self.cli("sessions", "--json").stdout)["data"]["sessions"][0]
        self.assertEqual(session["title"], "E2E worker session")
        self.turn(2, "Fix the tests", "ok")
        # A user's first request keeps its own words even when a title exists.
        base2 = {**base, "session_id": "s-user", "prompt_id": "q1"}
        self.assertHookOk(self.hook({**base2, "hook_event_name": "UserPromptSubmit", "prompt": "Fix the build"}))
        titles = {s["session_id"]: s["title"] for s in json.loads(self.cli("sessions", "--json").stdout)["data"]["sessions"]}
        self.assertEqual(titles["s-user"], "Fix the build")

    def test_display_preview_skips_a_long_leading_reminder(self):
        # The real reminder (257 chars) was longer than the 200-char preview.
        reminder = "<system-reminder>\n" + "Linked sessions now: x (idle). " * 9 + "\n</system-reminder>\n\n"
        self.turn(1, reminder + "Run the e2e steps in order", "ok")
        turn = json.loads(self.cli("turns", "--json", "--session", "s-origin").stdout)["data"]["turns"][0]
        self.assertTrue(turn["request"]["preview"].startswith("<system-reminder>"), "the preview stays verbatim")
        self.assertEqual(turn["request"]["display_preview"], "Run the e2e steps in order")
        self.assertEqual(turn["request_origin"], "unknown")

    def test_failed_command_of_any_kind_is_counted(self):
        # Real e2e turn, 2026-10-30: `python3 -c "...sys.exit(4)"` is kind
        # "other", so runs_nonzero stayed 0 and the app showed only "exit 0".
        base = {"session_id": "s-origin", "cwd": self.project, "transcript_path": "/x.jsonl", "prompt_id": "p1"}
        self.assertHookOk(self.hook({**base, "hook_event_name": "UserPromptSubmit", "prompt": "run"}))
        for payload in (
            {"hook_event_name": "PostToolUseFailure", "tool_name": "Bash", "tool_use_id": "t1",
             "tool_input": {"command": 'python3 -c "import sys; sys.exit(4)"'}, "error": "Exit code 4\n"},
            {"hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_use_id": "t2",
             "tool_input": {"command": "python3 -m unittest -v test_calc"},
             "tool_response": {"stdout": "OK", "stderr": "", "interrupted": False}},
        ):
            self.assertHookOk(self.hook({**base, **payload}))
        self.assertHookOk(self.hook({**base, "hook_event_name": "Stop", "stop_hook_active": False,
                                     "last_assistant_message": "done"}))
        observed = json.loads(self.cli("turns", "--json", "--session", "s-origin").stdout)["data"]["turns"][0]["observed"]
        self.assertEqual(observed["commands_nonzero"], 1)
        self.assertEqual(observed["runs_nonzero"], 0)
        self.assertEqual(observed["runs_exit_zero"], 1)
        self.assertIn("exit 4", self.context(1))

    def test_mixed_request_says_source_not_established(self):
        self.turn(1, "Please continue\n" + AUTOMATED, "Continued.")
        text = self.context(1)
        self.assertIn("## Request (source not established)", text)
        self.assertNotIn("## Original user request", text)


if __name__ == "__main__":
    unittest.main()
