"""Phase 9.4: a Stop with work in flight is not the final result.

The sequence mirrors what Claude Code 2.1.268 delivered on this Mac (event
names, prompt_id reuse, task types only; no captured text): the user's
request, a Stop with text and running ``shell`` tasks, a ``<task-notification>``
turn the harness started with a new prompt_id, another such Stop, and the
final answer.
"""

from __future__ import annotations

import json

from helpers import IsolatedTestCase

SHELL = [{"id": "b1", "type": "shell", "status": "running", "description": "swift test", "command": "swift test"}]
MONITOR = [{"id": "m1", "type": "monitor", "status": "running", "description": "artifact live updates"}]
NOTE = "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>"


class CompletionTests(IsolatedTestCase):
    def prompt(self, sid: str, pid: str, text: str) -> None:
        self.assertHookOk(self.hook({"hook_event_name": "UserPromptSubmit", "session_id": sid, "prompt_id": pid,
                                     "cwd": self.project, "prompt": text}))

    def stop(self, sid: str, pid: str, text, tasks=None, crons=None) -> None:
        payload = {"hook_event_name": "Stop", "session_id": sid, "prompt_id": pid, "cwd": self.project,
                   "stop_hook_active": False}
        if text is not None:
            payload["last_assistant_message"] = text
        if tasks is not None:
            payload["background_tasks"] = tasks
        if crons is not None:
            payload["session_crons"] = crons
        self.assertHookOk(self.hook(payload))

    def turns(self, sid: str):
        return json.loads(self.cli("turns", "--session", sid, "--json").stdout)["data"]["turns"]

    def last(self, sid: str):
        rows = json.loads(self.cli("sessions", "--json").stdout)["data"]["sessions"]
        return next(s for s in rows if s["session_id"] == sid)["last_turn"]

    def test_background_tests_then_follow_up_then_final_answer(self) -> None:
        self.prompt("s", "p0", "Run the Swift tests and tell me the result")
        self.stop("s", "p0", "Tests are running in the background; I will report when they finish.", SHELL)
        self.assertEqual(self.last("s")["completion"], "waiting_background")

        self.prompt("s", "p1", NOTE)                       # the harness wakes the session
        self.assertEqual(self.turns("s")[0]["completion"], "intermediate")
        self.assertEqual(self.turns("s")[0]["continued_in_turn"], 2)
        self.assertEqual(self.last("s")["completion"], "working")

        self.stop("s", "p1", "One suite still running; waiting.", SHELL)
        self.prompt("s", "p2", NOTE)
        self.stop("s", "p2", "All 269 tests passed (as reported by the runner).", [])
        turns = self.turns("s")
        self.assertEqual([t["completion"] for t in turns], ["intermediate", "intermediate", "answer"])
        self.assertEqual(turns[2]["request_origin"], "automated", "a notification is never the user's request")
        self.assertEqual(turns[2]["earlier_user_request"]["turn"], 1)
        self.assertEqual(self.last("s")["completion"], "answer")
        # The intermediate text is kept verbatim, with its status.
        show = json.loads(self.cli("show", "--session", "s", "--turn", "1", "--json").stdout)["data"]["turn"]
        self.assertEqual(show["final_response"]["text"], "Tests are running in the background; I will report when they finish.")
        self.assertEqual(show["completion"], "intermediate")
        ctx = self.cli("context", "--session", "s", "--turn", "1").stdout.decode()
        self.assertIn("- Completion: intermediate — the session continued automatically in turn 2", ctx)

    def test_redelivery_and_restart_change_nothing(self) -> None:
        self.prompt("r", "p0", "x")
        self.stop("r", "p0", "waiting", SHELL)
        self.stop("r", "p0", "waiting", SHELL)             # duplicate delivery
        self.assertEqual(len(self.turns("r")), 1)
        self.assertEqual(self.last("r")["completion"], "waiting_background")

    def test_watchers_and_schedules_do_not_hold_an_answer(self) -> None:
        self.prompt("m", "p0", "Publish the artifact")
        self.stop("m", "p0", "Published.", MONITOR, crons=[{"id": "c1", "cron": "*/5 * * * *"}])
        self.assertEqual(self.last("m")["completion"], "answer")

    def test_user_moving_on_settles_the_earlier_turn(self) -> None:
        self.prompt("u", "p0", "Start the dev server")
        self.stop("u", "p0", "Server running in the background.", SHELL)
        self.prompt("u", "p1", "Now add a footer")
        self.assertEqual(self.turns("u")[0]["completion"], "answer_background_running")

    def test_error_after_background_stop(self) -> None:
        self.prompt("e", "p0", "x")
        self.stop("e", "p0", "waiting", SHELL)
        self.prompt("e", "p1", NOTE)
        self.assertHookOk(self.hook({"hook_event_name": "StopFailure", "session_id": "e", "prompt_id": "p1",
                                     "cwd": self.project, "error": "rate_limit", "last_assistant_message": "API Error"}))
        self.assertEqual([t["completion"] for t in self.turns("e")], ["intermediate", "api_error"])

    def test_stop_without_background_field_is_an_answer(self) -> None:
        self.prompt("o", "p0", "x")
        self.stop("o", "p0", "done")                        # older Claude Code: no background_tasks
        self.assertEqual(self.last("o")["completion"], "answer")

    def test_follow_up_turn_carries_the_files_of_the_task(self) -> None:
        report = self.project + "/REPORT.md"
        self.prompt("w", "p0", "Write REPORT.md and run the tests")
        self.assertHookOk(self.hook({"hook_event_name": "PostToolUse", "session_id": "w", "prompt_id": "p0",
                                     "cwd": self.project, "tool_name": "Write",
                                     "tool_input": {"file_path": report, "content": "x"},
                                     "tool_response": {"filePath": report, "success": True}}))
        self.stop("w", "p0", "Wrote it; tests running.", SHELL)
        self.prompt("w", "p1", NOTE)
        self.stop("w", "p1", "Tests passed. REPORT.md is ready.", [])
        show = json.loads(self.cli("show", "--session", "w", "--turn", "2", "--json").stdout)["data"]["turn"]
        chain = show["work_chain"]
        self.assertEqual(chain["turns"], [1])
        self.assertEqual([f["path"] for f in chain["files_changed"]], [report])
        self.assertIsNotNone(chain["started_at"])
        first = json.loads(self.cli("show", "--session", "w", "--turn", "1", "--json").stdout)["data"]["turn"]
        self.assertNotIn("work_chain", first)
