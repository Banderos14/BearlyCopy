"""Phase 9.3: completion time on sessions, continuation context, Review Pack."""

from __future__ import annotations

import json
import time

from helpers import IsolatedTestCase

from prompt_relay import origin


class ContinuationOriginTests(IsolatedTestCase):
    def test_short_continuations_are_recognized(self) -> None:
        for text in ("продолжи где остановился", "Продолжай", "continue", "please continue from where you stopped",
                     "Дальше", "go on"):
            self.assertTrue(origin.is_continuation(text), text)
        for text in ("Continue the migration of the store to SQLite and add tests for every table, then write "
                     "a report about the performance of the new layer compared to the old JSONL files." , "Fix the bug",
                     "", None, "продолжительность анимации сделай 200 мс", "continued fractions explained"):
            self.assertFalse(origin.is_continuation(text), text)


class ContinuationApiTests(IsolatedTestCase):
    def turn(self, session: str, n: int, prompt: str, answer: str) -> None:
        self.assertHookOk(self.hook({"hook_event_name": "UserPromptSubmit", "session_id": session,
                                     "prompt_id": f"{session}-{n}", "cwd": self.project, "prompt": prompt}))
        self.assertHookOk(self.hook({"hook_event_name": "Stop", "session_id": session, "prompt_id": f"{session}-{n}",
                                     "cwd": self.project, "last_assistant_message": answer}))

    def test_continuation_keeps_its_request_and_offers_the_earlier_task(self) -> None:
        task = "Перенеси экспорт в отдельный модуль и добавь тесты на все форматы."
        self.turn("s1", 1, task, "Сделал половину.")
        self.turn("s1", 2, "продолжи где остановился", "Готово.")
        self.turn("other", 1, "Unrelated task in another session", "ok")
        turns = json.loads(self.cli("turns", "--session", "s1", "--json").stdout)["data"]["turns"]
        self.assertNotIn("continues_request", turns[0])
        self.assertEqual(turns[1]["request"]["preview"], "продолжи где остановился", "the request stays verbatim")
        self.assertEqual(turns[1]["continues_request"]["turn"], 1)
        self.assertEqual(turns[1]["continues_request"]["preview"], task)
        show = json.loads(self.cli("show", "--session", "s1", "--turn", "2", "--json").stdout)["data"]
        self.assertEqual(show["turn"]["continues_request"]["text"], task)
        self.assertEqual(show["turn"]["request"]["text"], "продолжи где остановился")
        ctx = self.cli("context", "--session", "s1", "--turn", "2").stdout.decode()
        self.assertIn("### Earlier task this request continues", ctx)
        self.assertIn("продолжи где остановился", ctx)
        self.assertLess(ctx.index("продолжи где остановился"), ctx.index(task), "the request first, context after")
        self.assertNotIn("Unrelated task in another session", ctx, "never another session's request")

    def test_first_turn_continuation_has_no_context(self) -> None:
        self.turn("s2", 1, "continue", "?")
        turns = json.loads(self.cli("turns", "--session", "s2", "--json").stdout)["data"]["turns"]
        self.assertNotIn("continues_request", turns[0])


class AnsweredAtTests(IsolatedTestCase):
    def test_last_turn_reports_completion_time_not_later_activity(self) -> None:
        self.assertHookOk(self.hook({"hook_event_name": "UserPromptSubmit", "session_id": "a", "prompt_id": "p",
                                     "cwd": self.project, "prompt": "x"}))
        self.assertHookOk(self.hook({"hook_event_name": "Stop", "session_id": "a", "prompt_id": "p",
                                     "cwd": self.project, "last_assistant_message": "done"}))
        time.sleep(0.02)
        self.assertHookOk(self.hook({"hook_event_name": "PostToolUse", "session_id": "a", "cwd": self.project,
                                     "tool_name": "Bash", "tool_input": {"command": "true"},
                                     "tool_response": {"stdout": "", "exit_code": 0}}))
        s = json.loads(self.cli("sessions", "--json").stdout)["data"]["sessions"][0]
        self.assertIn("answered_at", s["last_turn"])
        self.assertLessEqual(s["last_turn"]["answered_at"], s["last_event_at"])

    def test_stop_without_text_has_no_answered_at(self) -> None:
        self.assertHookOk(self.hook({"hook_event_name": "UserPromptSubmit", "session_id": "b", "prompt_id": "p",
                                     "cwd": self.project, "prompt": "x"}))
        self.assertHookOk(self.hook({"hook_event_name": "Stop", "session_id": "b", "prompt_id": "p", "cwd": self.project}))
        s = json.loads(self.cli("sessions", "--json").stdout)["data"]["sessions"][0]
        self.assertNotIn("answered_at", s["last_turn"])
        self.assertEqual(s["last_turn"]["status"], "stop_received_without_text")


class ReviewPackHeaderTests(IsolatedTestCase):
    def test_pack_has_portable_sections_and_logical_project(self) -> None:
        nested = self.project + "/macos"
        import os
        os.makedirs(nested)
        os.makedirs(self.project + "/.git")
        with open(self.project + "/.git/HEAD", "w") as fh:
            fh.write("ref: refs/heads/main\n")
        self.assertHookOk(self.hook({"hook_event_name": "UserPromptSubmit", "session_id": "n", "prompt_id": "p",
                                     "cwd": nested, "prompt": "Build it"}))
        self.assertHookOk(self.hook({"hook_event_name": "Stop", "session_id": "n", "prompt_id": "p",
                                     "cwd": nested, "last_assistant_message": "Built."}))
        ctx = self.cli("context", "--session", "n").stdout.decode()
        for section in ("## Source, host and project", "## Original user request", "## Claude final response",
                        "## Observed during this turn", "## Git state", "## Not checked (provenance and verification limits)",
                        "## Request for independent review"):
            self.assertIn(section, ctx)
        self.assertIn("- Project: project-a [Confirmed locally]", ctx)
        self.assertIn("- Working folder: macos inside the project [Confirmed locally]", ctx)
        self.assertNotIn("ChatGPT", ctx, "portable to any recipient")
