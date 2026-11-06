"""Phase 12.1: the agent waits for the person (Needs Input).

Every event goes through the real hook handler (``bin/prompt-relay hook``)
into an isolated data dir; the state is read back through ``sessions
--json``. The hook must stay an observer: empty stdout, exit 0, no decision.
"""

from __future__ import annotations

import json

from helpers import IsolatedTestCase

SHELL = [{"id": "b1", "type": "shell", "status": "running", "description": "swift test", "command": "swift test"}]
NOTE = "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>"
SECRET_QUESTION = "Which database password should I use: hunter2 or swordfish?"


class NeedsInputTests(IsolatedTestCase):
    sid = "s1"

    def send(self, payload, env=None):
        base = {"session_id": self.sid, "cwd": self.project}
        proc = self.hook(dict(base, **payload), env=env)
        self.assertHookOk(proc)            # stdout empty, exit 0: never a decision
        return proc

    def prompt(self, pid="p1", text="Refactor the login module"):
        self.send({"hook_event_name": "UserPromptSubmit", "prompt_id": pid, "prompt": text})

    def stop(self, pid="p1", text="Done.", tasks=None):
        p = {"hook_event_name": "Stop", "prompt_id": pid, "stop_hook_active": False, "last_assistant_message": text}
        if tasks is not None:
            p["background_tasks"] = tasks
        self.send(p)

    def pre(self, tool, pid="p1", tool_use_id="t1", tool_input=None):
        self.send({"hook_event_name": "PreToolUse", "prompt_id": pid, "tool_name": tool, "tool_use_id": tool_use_id,
                   "tool_input": tool_input or {}})

    def post(self, tool, pid="p1", tool_use_id="t1", failed=False, tool_input=None):
        p = {"hook_event_name": "PostToolUseFailure" if failed else "PostToolUse", "prompt_id": pid, "tool_name": tool,
             "tool_use_id": tool_use_id, "tool_input": tool_input or {}, "tool_response": {}}
        if failed:
            p["error"] = "The user doesn't want to proceed with this tool use."
        self.send(p)

    def permission(self, tool="WebFetch", pid="p1"):
        self.send({"hook_event_name": "PermissionRequest", "prompt_id": pid, "tool_name": tool,
                   "tool_input": {"url": "https://example.com/" + SECRET_QUESTION},
                   "permission_suggestions": [{"type": "addRules"}]})

    def notify(self, ntype):
        self.send({"hook_event_name": "Notification", "notification_type": ntype,
                   "message": "Claude needs your permission: " + SECRET_QUESTION, "title": "Claude Code"})

    def session(self, sid=None):
        rows = json.loads(self.cli("sessions", "--json").stdout)["data"]["sessions"]
        return next(r for r in rows if r["session_id"] == (sid or self.sid))

    def attention(self, sid=None):
        return self.session(sid).get("attention")

    def raw(self) -> str:
        return (self.home / "events" / (self.sid + ".jsonl")).read_text()

    # 1. Working → AskUserQuestion → Needs Input → answered → Working → answer
    def test_question_then_answer(self) -> None:
        self.prompt()
        self.assertIsNone(self.attention())
        self.assertTrue(self.session()["running"])
        self.pre("AskUserQuestion", tool_input={"questions": [{"question": SECRET_QUESTION}]})
        att = self.attention()
        self.assertEqual((att["state"], att["kind"], att["subagent"]), ("needs_input", "question", False))
        self.assertEqual(self.session()["last_turn"]["completion"], "working", "a question is never an answer")
        self.assertEqual(self.session()["answered_count"], 0)
        self.post("AskUserQuestion")
        self.assertIsNone(self.attention(), "answered: working again")
        self.stop(text="Refactored.")
        self.assertIsNone(self.attention())
        self.assertEqual(self.session()["last_turn"]["completion"], "answer")
        self.assertNotIn(SECRET_QUESTION, self.raw(), "question text is never stored")
        self.assertNotIn("hunter2", self.raw())

    # 2. Working → ExitPlanMode → Needs Input → approved → Working
    def test_plan_approval(self) -> None:
        self.prompt()
        self.pre("ExitPlanMode", tool_input={"plan": "1. " + SECRET_QUESTION})
        self.assertEqual(self.attention()["kind"], "plan_approval")
        self.post("ExitPlanMode")
        self.assertIsNone(self.attention())
        self.post("Edit", tool_use_id="t2", tool_input={"file_path": self.project + "/a.py"})
        self.assertIsNone(self.attention())
        self.assertNotIn(SECRET_QUESTION, self.raw())

    # 3. Working → PermissionRequest → Needs Input → allowed / denied
    def test_permission_allowed_by_any_tool_result(self) -> None:
        self.prompt()
        self.permission("WebFetch")
        self.assertEqual(self.attention()["kind"], "permission")
        first = self.attention()
        self.notify("permission_prompt")              # ~6 s later, still the same wait
        again = self.attention()
        self.assertEqual(again["kind"], "permission")
        self.assertEqual(again["since"], first["since"], "the same wait keeps its start")
        self.assertGreater(again["last_signal_at"], first["last_signal_at"], "a repeat re-confirms it")
        self.post("WebFetch", tool_use_id="w1")        # not an evidence tool: an activity mark
        self.assertIsNone(self.attention(), "allowed: the tool ran")
        turn = json.loads(self.cli("turns", "--session", self.sid, "--json").stdout)["data"]["turns"][0]
        self.assertEqual(turn["observed"]["tool_events"], 0, "WebFetch is not evidence; counts unchanged")
        self.assertNotIn("permission_suggestions", self.raw())
        self.assertNotIn(SECRET_QUESTION, self.raw())

    def test_permission_denied_then_claude_stops(self) -> None:
        self.prompt()
        self.permission("Bash")
        self.post("Bash", failed=True, tool_input={"command": "rm -rf build"})
        self.assertIsNone(self.attention(), "denied: Claude goes on")
        self.permission("Bash")
        self.stop(text="I could not run it because permission was denied.")
        self.assertIsNone(self.attention())
        self.assertEqual(self.session()["last_turn"]["completion"], "answer", "Stop ends the turn as before")

    # 4. Background task → Waiting → Final answer ready (unchanged)
    def test_background_wait_is_not_needs_input(self) -> None:
        self.prompt("p0", "Run the tests")
        self.stop("p0", "Tests are running in the background.", SHELL)
        self.assertEqual(self.session()["last_turn"]["completion"], "waiting_background")
        self.assertIsNone(self.attention())
        self.prompt("p1", NOTE)
        self.stop("p1", "All tests passed.", [])
        self.assertEqual(self.session()["last_turn"]["completion"], "answer")
        self.assertIsNone(self.attention())

    # 5. Several agents: one Needs Input, another Working
    def test_one_session_waits_another_works(self) -> None:
        self.prompt()
        self.pre("AskUserQuestion")
        self.sid = "s2"
        self.prompt(text="Write docs")
        self.assertIsNone(self.attention("s2"))
        self.assertTrue(self.session("s2")["running"])
        self.assertEqual(self.attention("s1")["kind"], "question", "never combined across sessions")

    # 6. Redelivery, restart and cancelled questions
    def test_redelivery_restart_and_cancel(self) -> None:
        self.prompt()
        self.pre("AskUserQuestion")
        self.pre("AskUserQuestion")                   # redelivered: same wait
        first = self.attention()
        self.assertEqual(first, self.attention(), "reading again (an app restart) gives the same state")
        self.assertEqual(self.raw().count('"signal":"needs_input"'), 1, "a redelivery is stored once")
        self.post("AskUserQuestion", failed=True)      # Esc: the question was cancelled
        self.assertIsNone(self.attention())
        self.pre("AskUserQuestion", pid="p1", tool_use_id="t9")
        self.prompt("p2", "Never mind, do something else")   # the person typed instead
        self.assertIsNone(self.attention())

    def test_session_end_and_elicitation_result_end_a_wait(self) -> None:
        self.prompt()
        self.notify("elicitation_dialog")
        self.assertEqual(self.attention()["kind"], "elicitation")
        self.notify("elicitation_complete")
        self.assertIsNone(self.attention())
        self.notify("agent_needs_input")
        self.assertEqual(self.attention()["kind"], "input")
        self.send({"hook_event_name": "SessionEnd", "reason": "prompt_input_exit"})
        self.assertIsNone(self.attention(), "the session was closed")

    def test_session_end_without_a_wait_creates_nothing(self) -> None:
        self.sid = "never-prompted"
        self.send({"hook_event_name": "SessionEnd", "reason": "other"})
        self.notify("elicitation_complete")
        self.assertFalse((self.home / "events" / "never-prompted.jsonl").exists(), "no empty conversation appears")

    def test_no_timer_ends_a_wait(self) -> None:
        self.prompt()
        self.pre("AskUserQuestion")
        # Re-read much later: the state comes from events only; time alone changes nothing.
        self.assertEqual(self.attention()["kind"], "question")

    # 7. Hosts without a waiting signal, and what is never stored
    def test_without_signals_the_state_is_not_invented(self) -> None:
        self.prompt()
        self.assertIsNone(self.attention(), "no signal: Working stays the last confirmed state")
        self.notify("idle_prompt")                   # not a waiting signal
        self.pre("Bash")                             # PreToolUse of another tool
        self.assertIsNone(self.attention())
        self.assertNotIn("idle_prompt", self.raw())
        self.assertNotIn("PreToolUse", self.raw())
        self.assertIn("ignored_event", self.log_outcomes())

    def test_ordinary_tools_store_nothing_extra(self) -> None:
        self.prompt()
        size = len(self.raw())
        for i in range(5):
            self.post("Read", tool_use_id=f"r{i}")
            self.post("Grep", tool_use_id=f"g{i}")
        self.assertEqual(len(self.raw()), size, "non-evidence tools write nothing unless a wait is open")
        self.post("Bash", tool_use_id="b1", tool_input={"command": "swift test"})
        turn = json.loads(self.cli("turns", "--session", self.sid, "--json").stdout)["data"]["turns"][0]
        self.assertEqual(turn["observed"]["tool_events"], 1, "evidence tools are recorded as before")
        self.assertFalse((self.home / "waiting" / self.sid).exists())

    def test_waiting_signals_never_answer_inbox_or_copy(self) -> None:
        self.prompt()
        self.stop(text="First answer.")
        self.prompt("p2", "Next task")
        self.permission("Bash")
        data = json.loads(self.cli("results", "--json").stdout)["data"]
        self.assertEqual([r["response"]["preview"] for r in data["results"]], ["First answer."])
        ctx = json.loads(self.cli("context", "--session", self.sid, "--turn", "1", "--json").stdout)
        self.assertTrue(ctx["ok"])
        self.assertIn("First answer.", ctx["data"]["text"])

    def test_codex_permission_request(self) -> None:
        env = dict(self.env, PROMPT_RELAY_PROVIDER="codex", PROMPT_RELAY_HOST="terminal")
        base = {"session_id": "x1", "turn_id": "t1", "cwd": self.project}
        for payload in ({"hook_event_name": "UserPromptSubmit", "prompt": "Build"},
                        {"hook_event_name": "PermissionRequest", "tool_name": "Bash",
                         "tool_input": {"command": "make", "description": SECRET_QUESTION}}):
            self.assertHookOk(self.hook(dict(base, **payload), env=env))
        row = json.loads(self.cli("sessions", "--json").stdout)["data"]["sessions"][0]
        self.assertEqual(row["attention"]["kind"], "permission")
        self.assertEqual(row["source"]["provider"], "codex")
        self.assertHookOk(self.hook(dict(base, hook_event_name="PostToolUse", tool_name="Bash",
                                         tool_input={"command": "make"}, tool_response={"exit_code": 0}), env=env))
        row = json.loads(self.cli("sessions", "--json").stdout)["data"]["sessions"][0]
        self.assertNotIn("attention", row)
        text = "".join(p.read_text() for p in (self.home / "events").iterdir())
        self.assertNotIn(SECRET_QUESTION, text)

    def test_a_raw_signal_record_is_never_read(self) -> None:
        from prompt_relay.events import from_record
        rec = {"payload": {"hook_event_name": "PermissionRequest", "session_id": "s", "signal": "needs_input",
                           "kind": "permission"}}
        self.assertIsNone(from_record(rec), "only reduced signal records are read")
        rec["payload"]["reduced"] = 1
        rec["payload"]["signal"] = "approve_everything"
        self.assertIsNone(from_record(rec))


AGENT_REPORT = ('<agent-message from="a8d63b1804be9f2a2">\n[Subagent hand-back] No findings with confidence >= 8.\n'
                '- marker path is <root>/waiting/<key>\n</agent-message>')


class AgentMessageTests(IsolatedTestCase):
    """Phase 12.1 fix: a subagent's report (``<agent-message>``) is an
    automated message, never the user's request in Copy with Context."""
    sid = "s1"
    send, prompt, stop = NeedsInputTests.send, NeedsInputTests.prompt, NeedsInputTests.stop

    def test_classified_as_automated(self) -> None:
        from prompt_relay import origin
        self.assertEqual(origin.classify(AGENT_REPORT), origin.AUTOMATED)
        self.assertIsNone(origin.display_preview(AGENT_REPORT, 200))
        mixed = "Please look at this:\n" + AGENT_REPORT
        self.assertEqual(origin.classify(mixed), origin.UNKNOWN, "mixed with other text: source not established")
        pasted = "<pasted_content id=\"x\">" + AGENT_REPORT + "</pasted_content id=\"x\">"
        self.assertEqual(origin.classify(pasted), origin.USER_PASTED, "pasted by the user stays the user's")

    def test_copy_with_context_labels_it_and_keeps_it_verbatim(self) -> None:
        self.prompt("p1", "Run a security review of the last commits")
        self.stop("p1", "The review is running in a subagent.")
        self.prompt("p2", AGENT_REPORT)
        self.stop("p2", "No findings with confidence >= 8.")
        turn = json.loads(self.cli("show", "--session", self.sid, "--turn", "2", "--json").stdout)["data"]["turn"]
        self.assertEqual(turn["request_origin"], "automated")
        self.assertEqual(turn["earlier_user_request"]["turn"], 1)
        text = json.loads(self.cli("context", "--session", self.sid, "--turn", "2", "--json").stdout)["data"]["text"]
        user, _, rest = text.partition("### Automated message that started this turn")
        self.assertIn("## Original user request", user)
        self.assertIn("Run a security review of the last commits", user, "the user's own request is shown as such")
        self.assertNotIn("agent-message", user, "the agent report is never under the user's request")
        self.assertIn(AGENT_REPORT, rest, "the automated message is kept verbatim")
        self.assertIn("Not written by the user", rest)
        results = json.loads(self.cli("results", "--json").stdout)["data"]["results"]
        newest = results[0]
        self.assertEqual(newest["request"]["own"], False)
        self.assertEqual(newest["request"]["display_preview"], "Run a security review of the last commits")
