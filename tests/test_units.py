"""Unit tests for core modules (in-process, isolated temp dirs)."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from helpers import REPO, IsolatedTestCase, load_fixture

from prompt_relay import config, correlation, export, gitinfo, hook, paths, sensitive
from prompt_relay.clipboard import ClipboardError, FileBackend, PbcopyBackend, get_backend
from prompt_relay.events import from_record
from prompt_relay.history import Session, SelectionError, filter_sessions, load_all, select_turn
from prompt_relay.store import DEDUP_WINDOW_S, NO_SESSION_KEY, Store, session_key


def ev(kind="stop", text="t", prompt_id=None, session="s", **payload):
    name = {"prompt": "UserPromptSubmit", "stop": "Stop", "stop_failure": "StopFailure"}[kind]
    body = {"hook_event_name": name, "session_id": session, "cwd": "/p"}
    if prompt_id:
        body["prompt_id"] = prompt_id
    body["prompt" if kind == "prompt" else "last_assistant_message"] = text
    body.update(payload)
    return from_record({"schema": 1, "record_id": os.urandom(4).hex(), "received_at": "t", "payload": body})


class CorrelationTests(unittest.TestCase):
    def test_prompt_id_links_even_out_of_order(self):
        turns = correlation.build_turns([ev("prompt", "q1", "a"), ev("prompt", "q2", "b"),
                                         ev("stop", "r2", "b"), ev("stop", "r1", "a")])
        self.assertEqual([(t.prompt.text, t.final_response.text, t.link) for t in turns],
                         [("q1", "r1", "prompt_id"), ("q2", "r2", "prompt_id")])

    def test_unknown_prompt_id_is_not_guessed(self):
        turns = correlation.build_turns([ev("prompt", "q"), ev("stop", "r", "zzz")])
        self.assertEqual(turns[1].link, "none")
        self.assertIsNone(turns[1].prompt)
        self.assertEqual(turns[0].status, "no_matched_response")

    def test_stop_hook_continuation_joins_previous_turn(self):
        turns = correlation.build_turns([ev("prompt", "q"), ev("stop", "r1"), ev("stop", "r2", stop_hook_active=True)])
        self.assertEqual(len(turns), 1)
        self.assertTrue(turns[0].continued_by_sequence)
        self.assertEqual(turns[0].final_response.text, "r2")

    def test_unrelated_stop_without_prompt_is_own_turn(self):
        turns = correlation.build_turns([ev("prompt", "q"), ev("stop", "r1"), ev("stop", "r2")])
        self.assertEqual(len(turns), 2)
        self.assertEqual(turns[1].link, "none")

    def test_failure_after_stop_keeps_text_but_reports_error(self):
        turns = correlation.build_turns([ev("prompt", "q", "a"), ev("stop", "r", "a"), ev("stop_failure", "API Error", "a", error="server_error")])
        self.assertEqual(turns[0].status, "api_error")
        self.assertEqual(turns[0].final_response.text, "r")

    def test_failure_text_is_never_a_response(self):
        turns = correlation.build_turns([ev("prompt", "q", "a"), ev("stop_failure", "API Error: Rate limit reached", "a")])
        self.assertIsNone(turns[0].final_response)
        with self.assertRaises(export.ExportError):
            export.response_text(turns[0])

    def test_trailing_prompt_is_awaiting(self):
        turns = correlation.build_turns([ev("prompt", "q1", "a"), ev("stop", "r", "a"), ev("prompt", "q2", "b")])
        self.assertEqual(turns[1].status, "awaiting_response")


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.store = Store(self.root / "d")

    def _record(self, payload, now=1000.0):
        return hook.build_record(payload, {}, now)

    def test_permissions(self):
        self.store.append(self._record({"hook_event_name": "Stop", "session_id": "s"}))
        self.assertEqual(os.stat(self.store.root).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(self.store.events_dir).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(self.store.path_for("s")).st_mode & 0o777, 0o600)

    def test_session_key_cannot_escape(self):
        for bad in ("../../etc/passwd", "/abs", "a/b", ".hidden", "x" * 300, "ñ", NO_SESSION_KEY):
            key = session_key(bad)
            self.assertNotIn("/", key)
            self.assertFalse(key.startswith("."))
            self.assertTrue(key.startswith("h-"), key)
        self.assertEqual(session_key(None), NO_SESSION_KEY)
        self.assertEqual(session_key("8f1c-uuid_ok.1"), "8f1c-uuid_ok.1")

    def test_hashed_session_keeps_real_id(self):
        sid = "weird/id"
        self.store.append(self._record({"hook_event_name": "Stop", "session_id": sid, "last_assistant_message": "x"}))
        sessions = load_all(self.store)
        self.assertEqual(sessions[0].session_id, sid)
        self.assertEqual(filter_sessions(sessions, session=sid)[0].session_id, sid)

    def test_dedup_window_without_prompt_id(self):
        p = {"hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": "same"}
        self.assertEqual(self.store.append(self._record(p, 1000.0)), "stored")
        self.assertEqual(self.store.append(self._record(p, 1000.0 + DEDUP_WINDOW_S - 1)), "duplicate")
        self.assertEqual(self.store.append(self._record(p, 1000.0 + DEDUP_WINDOW_S + 5)), "stored")

    def test_dedup_with_prompt_id_has_no_window(self):
        p = {"hook_event_name": "Stop", "session_id": "s", "prompt_id": "x", "last_assistant_message": "m"}
        self.store.append(self._record(p, 0.0))
        self.assertEqual(self.store.append(self._record(p, 1e9)), "duplicate")

    def test_corrupt_and_future_schema_lines_are_skipped(self):
        self.store.append(self._record({"hook_event_name": "Stop", "session_id": "s", "last_assistant_message": "ok"}))
        with open(self.store.path_for("s"), "ab") as fh:
            fh.write(b"garbage\n[1]\n" + json.dumps({"schema": 99, "payload": {}}).encode() + b"\n")
        result = self.store.read_session("s")
        self.assertEqual((len(result.records), result.corrupt_lines, result.unsupported_lines), (1, 2, 1))

    def test_lossless_roundtrip_including_lone_surrogate(self):
        text = "a\ud800b \u0000 é 👍"
        self.store.append(self._record({"hook_event_name": "Stop", "session_id": "s", "last_assistant_message": text}))
        self.assertEqual(self.store.read_session("s").records[0]["payload"]["last_assistant_message"], text)
        self.assertTrue(self.store.path_for("s").read_bytes().isascii())

    def test_delete(self):
        for sid in ("a", "b"):
            self.store.append(self._record({"hook_event_name": "Stop", "session_id": sid}))
        self.assertEqual(self.store.delete_all(), 2)
        self.assertEqual(self.store.session_files(), [])

    def test_empty_store(self):
        self.assertEqual(load_all(self.store), [])
        with self.assertRaises(SelectionError):
            select_turn([])


class HookUnitTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.project = str(self.root / "proj")
        os.makedirs(self.project)
        config.save(self.root, config.Config(enabled_projects=[os.path.realpath(self.project)]))

    def run_hook(self, payload, env=None):
        raw = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        return hook.process(raw, env or {}, root=self.root)[1]

    def test_project_must_be_enabled(self):
        self.assertEqual(self.run_hook({"hook_event_name": "Stop", "session_id": "s", "cwd": "/elsewhere"}), "project_not_enabled")
        self.assertEqual(self.run_hook({"hook_event_name": "Stop", "session_id": "s", "cwd": self.project + "/sub"}), "stored")

    def test_claude_project_dir_takes_precedence_over_cwd(self):
        env = {"CLAUDE_PROJECT_DIR": self.project}
        self.assertEqual(self.run_hook({"hook_event_name": "Stop", "session_id": "s", "cwd": "/tmp/worktree"}, env), "stored")
        rec = Store(self.root).read_session("s").records[0]
        self.assertEqual(rec["context"]["claude_project_dir"], self.project)
        self.assertEqual(from_record(rec).project_dir, self.project)

    def test_prefix_is_not_a_parent(self):
        self.assertEqual(self.run_hook({"hook_event_name": "Stop", "session_id": "s", "cwd": self.project + "-other"}), "project_not_enabled")

    def test_corrupt_config_fails_closed(self):
        (self.root / "config.json").write_text("{not json")
        self.assertEqual(self.run_hook({"hook_event_name": "Stop", "session_id": "s", "cwd": self.project}), "config_invalid_json")
        self.assertEqual(Store(self.root).session_files(), [])

    def test_unhandled_events_are_not_stored(self):
        for name in ("SessionStart", "SessionEnd", "Notification", "SubagentStop", "PreToolUse"):
            self.assertEqual(self.run_hook({"hook_event_name": name, "session_id": "s", "cwd": self.project}), "ignored_event")

    def test_oversized_payload(self):
        orig = hook.MAX_STDIN_BYTES
        hook.MAX_STDIN_BYTES = 10
        try:
            self.assertEqual(self.run_hook(b"x" * 11), "payload_too_large")
        finally:
            hook.MAX_STDIN_BYTES = orig

    def test_unknown_fields_are_preserved(self):
        payload = {"hook_event_name": "Stop", "session_id": "s", "cwd": self.project, "future_field": {"x": [1]}}
        self.run_hook(payload)
        self.assertEqual(Store(self.root).read_session("s").records[0]["payload"], payload)

    def test_log_contains_no_message_text(self):
        import io
        env = {"PROMPT_RELAY_HOME": str(self.root)}
        hook.main(io.BytesIO(json.dumps({"hook_event_name": "Stop", "session_id": "s", "cwd": self.project,
                                         "last_assistant_message": "TOPSECRET-xyz"}).encode()), env)
        from unittest import mock
        with mock.patch("sys.stderr"):
            hook.main(io.BytesIO(b"{broken TOPSECRET-xyz"), env)
        log = (self.root / "handler.log").read_text()
        self.assertNotIn("TOPSECRET", log)
        self.assertIn("Stop stored", log)
        self.assertIn("invalid_json", log)


class ExportTests(IsolatedTestCase):
    def test_fence_is_longer_than_content_fences(self):
        self.assertEqual(export.fence("no fences"), "```")
        self.assertEqual(export.fence("```\ncode\n```"), "````")
        self.assertEqual(export.fence("``````"), "```````")

    def test_sensitive_content_blocks_copy_context(self):
        secret = "export OPENAI_API_KEY=sk-proj-" + "a" * 30
        self.assertHookOk(self.hook(self.fx("prompt_basic.json")))
        self.assertHookOk(self.hook(self.fx("stop_basic.json", last_assistant_message="Set it:\n" + secret)))
        out = self.cli("copy-context")
        self.assertEqual(out.returncode, 5)
        self.assertIn(b"response line 2", out.stderr)
        self.assertNotIn(b"sk-proj", out.stderr, "findings must not echo the secret")
        self.assertFalse(self.clip.exists())
        self.assertEqual(self.cli("copy-context", "--allow-sensitive").returncode, 0)
        self.assertIn(secret, self.clip.read_text())
        # Copy Response is the user's explicit verbatim copy and is not blocked
        self.assertEqual(self.cli("copy").returncode, 0)

    def test_context_git_section_and_read_only(self):
        repo = self.project
        run = lambda *a: subprocess.run(["git", "-C", repo, *a], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        run("init", "-q", "-b", "main")
        run("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init")
        Path(repo, "new.txt").write_text("x")
        git_dir_before = sorted((p.relative_to(repo), p.stat().st_mtime_ns) for p in Path(repo, ".git").rglob("*"))
        info = gitinfo.collect(repo)
        self.assertTrue(info.available)
        self.assertEqual(info.branch, "main")
        self.assertEqual(len(info.head or ""), 40)
        self.assertEqual(info.changed_files, ["?? new.txt"])
        git_dir_after = sorted((p.relative_to(repo), p.stat().st_mtime_ns) for p in Path(repo, ".git").rglob("*"))
        self.assertEqual(git_dir_before, git_dir_after, "git metadata collection must not write to .git")
        self.assertHookOk(self.hook(self.fx("prompt_basic.json")))
        self.assertHookOk(self.hook(self.fx("stop_basic.json")))
        ctx = self.cli("context").stdout.decode()
        self.assertIn("- Branch: main [Confirmed locally]", ctx)
        self.assertIn("?? new.txt", ctx)
        self.assertIn("[Not verified]", ctx)
        self.assertIn("All tests pass (reported).", ctx)

    def test_git_unavailable(self):
        self.assertFalse(gitinfo.collect(None).available)
        self.assertFalse(gitinfo.collect(self.project).available)

    def test_hook_config_is_exec_form_and_writes_nothing(self):
        out = self.cli("hook-config", "--command", "/opt/pr/bin/prompt-relay")
        cfg = json.loads(out.stdout)
        self.assertEqual(set(cfg["hooks"]), {"UserPromptSubmit", "Stop", "StopFailure"})
        handler = cfg["hooks"]["Stop"][0]["hooks"][0]
        self.assertEqual(handler, {"type": "command", "command": "/opt/pr/bin/prompt-relay", "args": ["hook"], "timeout": 10})
        pinned = json.loads(self.cli("hook-config", "--command", "/opt/pr/bin/prompt-relay", "--python", "/usr/bin/python3").stdout)
        self.assertEqual(pinned["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"], "/usr/bin/python3")
        self.assertEqual(pinned["hooks"]["UserPromptSubmit"][0]["hooks"][0]["args"], ["/opt/pr/bin/prompt-relay", "hook"])
        self.assertEqual(self.cli("hook-config", "--command", "relative/path").returncode, 2)

    def test_enable_refuses_home_and_root(self):
        os.makedirs(self.env["HOME"], exist_ok=True)
        self.assertEqual(self.cli("enable", self.env["HOME"]).returncode, 1)
        self.assertEqual(self.cli("enable", "/").returncode, 1)

    def test_delete_requires_confirmation(self):
        self.assertHookOk(self.hook(self.fx("stop_basic.json")))
        self.assertEqual(self.cli("delete", "--all").returncode, 2)
        self.assertEqual(len(self.records("sess-a")), 1)
        self.assertEqual(self.cli("delete", "--session", "sess-a", "--yes").returncode, 0)
        self.assertEqual(self.records("sess-a"), [])

    def test_session_prefix_and_project_filter(self):
        self.assertHookOk(self.hook(self.fx("stop_basic.json", session_id="abc-111")))
        self.assertHookOk(self.hook(self.fx("stop_basic.json", session_id="abc-222", prompt_id="other")))
        self.assertEqual(self.cli("show", "--session", "abc").returncode, 3)  # ambiguous prefix
        self.assertEqual(self.cli("show", "--session", "abc-1").returncode, 0)
        self.assertEqual(self.cli("show", "--project", self.project_b).returncode, 3)


class PlatformTests(unittest.TestCase):
    def test_default_data_dirs(self):
        self.assertEqual(paths.data_dir({"HOME": "/Users/u"}, "darwin"), Path("/Users/u/Library/Application Support/PromptRelay"))
        self.assertEqual(paths.data_dir({"HOME": "/home/u"}, "linux"), Path("/home/u/.local/share/prompt-relay"))
        self.assertEqual(paths.data_dir({"HOME": "/h", "PROMPT_RELAY_HOME": "/x"}, "darwin"), Path("/x"))

    def test_clipboard_selection(self):
        self.assertIsInstance(get_backend({}, "darwin"), PbcopyBackend)
        self.assertIsInstance(get_backend({"PROMPT_RELAY_CLIPBOARD": "file:/tmp/x"}, "darwin"), FileBackend)
        with self.assertRaises(ClipboardError):
            get_backend({}, "linux")
        with self.assertRaises(ClipboardError):
            get_backend({"PROMPT_RELAY_CLIPBOARD": "xclip"}, "linux")

    def test_pbcopy_backend_sets_utf8_locale(self):
        from unittest import mock
        with mock.patch("os.path.exists", return_value=True), mock.patch("subprocess.run") as run:
            PbcopyBackend().copy("Привет")
        args, kwargs = run.call_args
        self.assertEqual(args[0], ["/usr/bin/pbcopy"])
        self.assertEqual(kwargs["input"], "Привет".encode("utf-8"))
        self.assertEqual(kwargs["env"]["LC_ALL"], "en_US.UTF-8")
        self.assertNotIn("shell", kwargs)

    def test_sensitive_patterns(self):
        hits = sensitive.scan("ok\n-----BEGIN RSA PRIVATE KEY-----\nAKIAABCDEFGHIJKLMNOP\npassword = hunter22hunter\nplain text", "r")
        self.assertEqual([(f.line, f.kind) for f in hits],
                         [(2, "private key block"), (3, "AWS access key id"), (4, "credential assignment")])
        self.assertEqual(sensitive.scan("Use `TOKEN` env var; see docs.", "r"), [])


class SourceSafetyTests(unittest.TestCase):
    SOURCES = sorted((REPO / "prompt_relay").glob("*.py")) + [REPO / "bin" / "prompt-relay"]

    def test_no_network_or_dynamic_execution_in_sources(self):
        import re
        forbidden = re.compile(r"^\s*(import|from)\s+(socket|urllib|http|requests|ssl|ftplib|smtplib|xmlrpc|asyncio)\b"
                               r"|shell\s*=\s*True|\beval\(|\bexec\(|os\.system\(|os\.popen\(", re.M)
        for path in self.SOURCES:
            self.assertIsNone(forbidden.search(path.read_text()), f"{path.name} uses a forbidden construct")

    def test_hook_never_prints(self):
        import re
        self.assertIsNone(re.search(r"\bprint\(|sys\.stdout", (REPO / "prompt_relay" / "hook.py").read_text()))

    def test_gitignore_excludes_local_data(self):
        text = (REPO / ".gitignore").read_text()
        for entry in ("*.jsonl", ".prompt-relay/", "__pycache__/", ".env", ".claude/settings.local.json"):
            self.assertIn(entry, text)


if __name__ == "__main__":
    unittest.main()
