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
        # The pending prompt has a different prompt_id: conflicting evidence.
        turns = correlation.build_turns([ev("prompt", "q", "other"), ev("stop", "r", "zzz")])
        self.assertEqual(turns[1].link, "none")
        self.assertIsNone(turns[1].prompt)
        self.assertEqual(turns[0].status, "no_matched_response")

    # Regression (audit A1): prompt event without prompt_id, Stop with one.
    def test_stop_prompt_id_with_prompt_lacking_it_links_by_order(self):
        turns = correlation.build_turns([ev("prompt", "q"), ev("stop", "r", "pid-x"), ev("stop", "r2", "pid-x", stop_hook_active=True)])
        self.assertEqual(len(turns), 1)
        self.assertEqual((turns[0].link, turns[0].final_response.text), ("sequence", "r2"))
        two = correlation.build_turns([ev("prompt", "q1"), ev("prompt", "q2"), ev("stop", "r", "pid-x")])
        self.assertEqual(two[-1].link, "none")

    # Regression (audit A2): a prompt_id match must not discard other pending prompts.
    def test_prompt_id_match_keeps_other_pending_prompt(self):
        turns = correlation.build_turns([ev("prompt", "q1", "a"), ev("prompt", "q2"), ev("stop", "r1", "a"), ev("stop", "r2")])
        self.assertEqual([(t.prompt.text, t.link, t.final_response.text) for t in turns],
                         [("q1", "prompt_id", "r1"), ("q2", "sequence", "r2")])

    # Regression (audit A3): no fallback to an older, superseded Stop text.
    def test_last_stop_without_text_has_no_final_response(self):
        turn = correlation.build_turns([ev("prompt", "q", "a"), ev("stop", "old", "a"), ev("stop", None, "a", stop_hook_active=True)])[0]
        self.assertIsNone(turn.final_response)
        self.assertEqual(turn.status, "stop_received_without_text")
        with self.assertRaises(export.ExportError):
            export.response_text(turn)

    # Regression (audit A5): events without session_id are never linked.
    def test_no_link_mode(self):
        turns = correlation.build_turns([ev("prompt", "q", session=None), ev("stop", "r", session=None)], link_events=False)
        self.assertEqual([(t.link, t.prompt is None) for t in turns], [("none", False), ("none", True)])

    def test_no_prompt_id_background_wake_joins_turn(self):
        turns = correlation.build_turns([ev("prompt", "q"), ev("stop", "wait", background_tasks=[{"id": "t"}]), ev("stop", "done", background_tasks=[])])
        self.assertEqual(len(turns), 1)
        self.assertEqual((turns[0].status, turns[0].final_response.text), ("stop_received", "done"))

    def test_interrupted_turn_without_prompt_id_is_ambiguous_not_guessed(self):
        # Esc produces no Stop (documented), so the next answer cannot be linked by order.
        turns = correlation.build_turns([ev("prompt", "q1"), ev("prompt", "q2"), ev("stop", "r2")])
        self.assertEqual(turns[-1].link, "ambiguous")
        self.assertEqual([p.text for p in turns[-1].candidate_prompts], ["q1", "q2"])

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
        # Regression (audit A4): the error must be surfaced, not hidden behind the text.
        self.assertEqual(export.status_text(turns[0]), export.API_ERROR_AFTER_STOP)
        self.assertEqual(export.warnings_for(turns[0]), [export.API_ERROR_AFTER_STOP])

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

    # Regression (audit B2): a pre-existing root (PROMPT_RELAY_HOME=$HOME by
    # mistake) must not be chmod-ed; only events/ is ours.
    def test_existing_root_mode_is_not_changed(self):
        root = self.root / "existing"
        root.mkdir(mode=0o755)
        os.chmod(root, 0o755)
        Store(root).append(self._record({"hook_event_name": "Stop", "session_id": "s"}))
        self.assertEqual(os.stat(root).st_mode & 0o777, 0o755)
        self.assertEqual(os.stat(root / "events").st_mode & 0o777, 0o700)

    # Regression (audit B1): a line belonging to another session is never merged.
    def test_foreign_session_line_is_ignored(self):
        self.store.append(self._record({"hook_event_name": "Stop", "session_id": "a", "last_assistant_message": "A"}))
        with open(self.store.path_for("a"), "ab") as fh:
            fh.write(json.dumps(self._record({"hook_event_name": "Stop", "session_id": "b", "last_assistant_message": "B"})).encode() + b"\n")
        session = load_all(self.store)[0]
        self.assertEqual([e.text for e in session.events], ["A"])
        self.assertEqual(session.foreign_lines, 1)

    def test_partial_and_nul_filled_tail_then_append(self):
        self.store.append(self._record({"hook_event_name": "Stop", "session_id": "s", "last_assistant_message": "one"}))
        with open(self.store.path_for("s"), "ab") as fh:
            fh.write(b'{"schema":1,"payload":{"hook_ev' + b"\x00" * 64)  # crash: torn line + zero-filled tail
        self.store.append(self._record({"hook_event_name": "Stop", "session_id": "s", "last_assistant_message": "two"}, 5000.0))
        result = self.store.read_session("s")
        self.assertEqual([r["payload"]["last_assistant_message"] for r in result.records], ["one", "two"])
        self.assertEqual(result.corrupt_lines, 1)
        with open(self.store.path_for("s"), "ab") as fh:
            fh.write(b"\xff\xfe\n{\"schema\": 1, \"payload\": \"not-an-object\"}\n")
        self.assertEqual(self.store.read_session("s").corrupt_lines, 3)

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

    # Audit E2: the fsmonitor mitigation claimed in SECURITY.md T9 really works.
    def test_repo_configured_fsmonitor_is_not_executed(self):
        repo = self.project
        marker = Path(self.tmp, "FSMONITOR_RAN")
        hook_script = Path(self.tmp, "fsmonitor.sh")
        hook_script.write_text(f"#!/bin/sh\ntouch '{marker}'\n")
        hook_script.chmod(0o755)
        run = lambda *a: subprocess.run(["git", "-C", repo, *a], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        run("init", "-q")
        run("config", "core.fsmonitor", str(hook_script))
        self.assertTrue(gitinfo.collect(repo).available)
        self.assertFalse(marker.exists(), "repo-configured core.fsmonitor ran during metadata collection")

    def test_git_unavailable(self):
        self.assertFalse(gitinfo.collect(None).available)
        self.assertFalse(gitinfo.collect(self.project).available)

    def test_hook_config_is_exec_form_and_writes_nothing(self):
        import sys
        # Regression (audit F2): by default the interpreter running the CLI is
        # pinned; nothing assumes /usr/bin/python3 or the hook's PATH.
        cfg = json.loads(self.cli("hook-config", "--command", "/opt/pr/bin/prompt-relay").stdout)
        self.assertEqual(set(cfg["hooks"]), {"UserPromptSubmit", "Stop", "StopFailure"})
        handler = cfg["hooks"]["Stop"][0]["hooks"][0]
        self.assertEqual(handler, {"type": "command", "command": sys.executable,
                                   "args": ["/opt/pr/bin/prompt-relay", "hook"], "timeout": 10})
        shebang = json.loads(self.cli("hook-config", "--command", "/opt/pr/bin/prompt-relay", "--use-shebang").stdout)
        self.assertEqual(shebang["hooks"]["Stop"][0]["hooks"][0],
                         {"type": "command", "command": "/opt/pr/bin/prompt-relay", "args": ["hook"], "timeout": 10})
        missing = self.cli("hook-config", "--python", str(self.tmp / "no-such-python"))
        self.assertEqual(missing.returncode, 2)
        self.assertIn(b"not an executable file", missing.stderr)
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


class AuditRegressionTests(IsolatedTestCase):
    # Regression (audit F1): the entry point must exit 0 even if the package
    # cannot be imported (moved checkout) or Python is too old.
    def test_hook_entry_point_exits_zero_when_package_missing(self):
        import shutil, sys
        lone = self.tmp / "lone"
        lone.mkdir()
        shutil.copy(str(REPO / "bin" / "prompt-relay"), str(lone / "prompt-relay"))
        proc = subprocess.run([sys.executable, str(lone / "prompt-relay"), "hook"], input=b"{}",
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env, timeout=30)
        self.assertEqual((proc.returncode, proc.stdout), (0, b""))
        self.assertIn(b"startup_failed:ModuleNotFoundError", proc.stderr)
        self.assertNotIn(b"Traceback", proc.stderr)

    # Regression (audit C1): concurrent enable must not lose projects or crash.
    def test_concurrent_enable_keeps_every_project(self):
        import sys
        dirs = []
        for i in range(16):
            d = self.tmp / f"proj-{i}"
            d.mkdir()
            dirs.append(str(d.resolve()))
        procs = [subprocess.Popen([sys.executable, str(REPO / "bin" / "prompt-relay"), "enable", d], env=self.env,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.PIPE) for d in dirs]
        codes = [p.wait(timeout=60) for p in procs]
        for p in procs:
            p.stderr.close()
        self.assertEqual(codes, [0] * len(dirs))
        listed = set(self.cli("projects").stdout.decode().split())
        self.assertTrue(set(dirs) <= listed)
        self.assertEqual(list(self.home.glob("config.json*.tmp")), [])

    # Regression (audit A4): Copy Response warns when the turn ended in an API error.
    def test_copy_warns_on_api_error_after_stop(self):
        self.assertHookOk(self.hook(self.fx("prompt_basic.json")))
        self.assertHookOk(self.hook(self.fx("stop_basic.json")))
        self.assertHookOk(self.hook(self.fx("stop_failure_rate_limit.json")))
        out = self.cli("copy")
        self.assertEqual(out.returncode, 0)
        self.assertIn(b"later ended with an API error", out.stderr)
        self.assertIn("later ended with an API error", self.cli("context").stdout.decode())

    # Regression (audit A5): two unknown sessions without session_id are not linked.
    def test_events_without_session_id_are_never_linked(self):
        self.assertHookOk(self.hook({"hook_event_name": "UserPromptSubmit", "cwd": self.project, "prompt": "question from X"}))
        self.assertHookOk(self.hook({"hook_event_name": "Stop", "cwd": self.project, "last_assistant_message": "answer from Y"}))
        ctx = self.cli("context").stdout.decode()
        self.assertNotIn("question from X", ctx)
        self.assertIn("no captured request could be linked", ctx)

    # Regression (audit E1): Copy Response warns (never blocks) on suspected secrets.
    def test_copy_response_warns_on_secrets_without_echo(self):
        secret = "AKIA" + "ABCDEFGHIJKLMNOP"
        self.assertHookOk(self.hook(self.fx("stop_basic.json", last_assistant_message="key " + secret)))
        out = self.cli("copy")
        self.assertEqual(out.returncode, 0)
        self.assertIn(b"AWS access key id", out.stderr)
        self.assertNotIn(secret.encode(), out.stderr)
        self.assertEqual(self.clip.read_text(), "key " + secret)

    # Regression (audit C2): the same directory under a different spelling
    # (case-insensitive APFS, bind mount) is recognized via (st_dev, st_ino).
    def test_enabled_project_matched_by_identity(self):
        from unittest import mock
        real_stat = os.stat
        alias = "/Volumes/Alias/Project-A"

        def fake_stat(path, *a, **k):
            if str(path) == alias:
                return real_stat(self.project)
            if str(path) in ("/Volumes/Alias", "/Volumes"):
                raise FileNotFoundError(path)
            return real_stat(path, *a, **k)

        cfg = config.load(self.home)
        with mock.patch("os.stat", fake_stat):
            self.assertTrue(config.is_enabled(cfg, alias + "/src"))
            self.assertFalse(config.is_enabled(cfg, "/Volumes/Other"))


class SchemaConformanceTests(IsolatedTestCase):
    """Documented (and, later, real) payloads go through the real handler.

    Fixtures named documented_*.json follow the official hooks reference;
    real_*.json are added after the macOS validation and are picked up here.
    """

    def schema_fixtures(self):
        from helpers import FIXTURES
        names = sorted(p.name for p in FIXTURES.glob("documented_*.json")) + \
            sorted(p.name for p in FIXTURES.glob("real_*.json"))
        self.assertGreaterEqual(len(names), 5)
        return names

    def test_any_json_encoding_is_stored_verbatim_once(self):
        from prompt_relay.store import Store
        for name in self.schema_fixtures():
            with self.subTest(name):
                payload = self.fx(name, session_id="conf-" + name.split(".")[0].replace("_", "-"))
                encodings = [
                    json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                    json.dumps(payload, ensure_ascii=True).encode("ascii"),
                    json.dumps(dict(reversed(list(payload.items()))), indent=2).replace("\n", "\r\n").encode() + b"\r\n",
                ]
                for raw in encodings:
                    self.assertHookOk(self.hook(raw))
                records = Store(self.home).read_session(payload["session_id"]).records
                self.assertEqual(len(records), 1, "same event in another encoding is a duplicate")
                self.assertEqual(records[0]["payload"], payload)

    def test_documented_fields_are_interpreted(self):
        stop = from_record({"schema": 1, "payload": self.fx("documented_stop.json")})
        self.assertEqual((stop.kind, stop.prompt_id, stop.stop_hook_active), ("stop", "550e8400-e29b-41d4-a716-446655440000", True))
        self.assertEqual(stop.text, "I've completed the refactoring. Here's a summary...")
        self.assertTrue(stop.has_background_tasks)
        self.assertEqual(len(stop.session_crons), 1)
        prompt = from_record({"schema": 1, "payload": self.fx("documented_user_prompt_submit.json")})
        self.assertEqual((prompt.kind, prompt.text), ("prompt", "Write a function to calculate the factorial of a number"))
        fail = from_record({"schema": 1, "payload": self.fx("documented_stop_failure.json")})
        self.assertEqual((fail.kind, fail.error, fail.error_details, fail.text),
                         ("stop_failure", "rate_limit", "429 Too Many Requests", "API Error: Rate limit reached"))
        minimal = from_record({"schema": 1, "payload": self.fx("documented_stop_failure_minimal.json")})
        self.assertEqual((minimal.error, minimal.error_details, minimal.text), ("unknown", None, None))

    def test_documented_turns(self):
        for name in ("documented_user_prompt_submit.json", "documented_stop.json"):
            self.assertHookOk(self.hook(self.fx(name)))
        self.assertIn("link=prompt_id", self.cli("turns").stdout.decode())
        self.assertIn("background_tasks_pending", self.cli("turns").stdout.decode())
        self.assertHookOk(self.hook(self.fx("documented_stop_no_task_registry.json")))
        self.assertEqual(self.cli("show").stdout, b"Done.")
        self.assertIn("not reported by Claude Code [Unavailable]", self.cli("context").stdout.decode())
        self.assertHookOk(self.hook(self.fx("documented_stop_failure_minimal.json")))
        self.assertIn("api_error", self.cli("turns").stdout.decode())

    def test_every_fixture_text_survives_show_byte_exact(self):
        from helpers import FIXTURES
        for path in sorted(FIXTURES.glob("*.json")):
            if path.name.startswith("corrupt"):
                continue
            payload = self.fx(path.name, session_id="exact-" + path.stem.replace("_", "-"))
            if payload.get("hook_event_name") != "Stop" or not isinstance(payload.get("last_assistant_message"), str):
                continue
            with self.subTest(path.name):
                self.assertHookOk(self.hook(payload))
                out = self.cli("show", "--session", payload["session_id"])
                self.assertEqual(out.stdout, payload["last_assistant_message"].encode("utf-8"))


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
