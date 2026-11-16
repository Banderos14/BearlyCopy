"""The 18 required scenarios (docs/TEST_PLAN.md §2), end to end.

Each test drives the real ``bin/prompt-relay`` executable in a subprocess
with synthetic hook payloads. The clipboard is the file MOCK backend.
"""

from __future__ import annotations

import fcntl
import json
import os
import socket
import subprocess
import sys
import time
import unittest
from pathlib import Path
from unittest import mock

from helpers import BIN, REPO, IsolatedTestCase


def _markdown_long(blocks: int = 1000) -> str:
    parts = ["# Long report\n"]
    for i in range(blocks):
        parts.append(f"\n## Section {i}\n\nParagraph {i} with `inline` code, **bold**, кириллица и emoji 🚀.\n")
        parts.append(f"\n```python\ndef f_{i}(x):\n    return x + {i}\n```\n")
        if i % 50 == 0:
            parts.append("\n````md\n```js\nnested()\n```\n````\n")
    return "".join(parts)


class RequiredScenarios(IsolatedTestCase):
    # 1
    def test_s01_one_prompt_one_stop(self):
        self.assertHookOk(self.hook(self.fx("prompt_basic.json")))
        self.assertHookOk(self.hook(self.fx("stop_basic.json")))
        out = self.cli("show")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.decode("utf-8"), self.fx("stop_basic.json")["last_assistant_message"])
        turns = self.cli("turns").stdout.decode()
        self.assertIn("link=prompt_id", turns)
        self.assertIn("stop_received", turns)

    # 2
    def test_s02_two_prompts_same_session(self):
        for i in (1, 2):
            pid = f"p-{i}"
            self.assertHookOk(self.hook(self.fx("prompt_basic.json", prompt_id=pid, prompt=f"request {i}")))
            self.assertHookOk(self.hook(self.fx("stop_basic.json", prompt_id=pid, last_assistant_message=f"answer {i}")))
        self.assertEqual(self.cli("show").stdout, b"answer 2")
        self.assertEqual(self.cli("show", "--session", "sess-a", "--turn", "1").stdout, b"answer 1")
        ctx = self.cli("context", "--session", "sess-a", "--turn", "1").stdout.decode()
        self.assertIn("request 1", ctx)
        self.assertNotIn("request 2", ctx)

    def test_s02b_two_prompts_without_prompt_id_use_order(self):
        for i in (1, 2):
            self.assertHookOk(self.hook(self.fx("prompt_minimal.json", prompt=f"q{i}")))
            self.assertHookOk(self.hook(self.fx("stop_minimal.json", last_assistant_message=f"a{i}")))
        turns = self.cli("turns", "--session", "sess-min").stdout.decode()
        self.assertEqual(turns.count("link=sequence"), 2)
        ctx = self.cli("context", "--session", "sess-min", "--turn", "2").stdout.decode()
        self.assertIn("link inferred", ctx)
        self.assertIn("q2", ctx)

    # 3
    def test_s03_parallel_sessions_different_projects(self):
        a_p = self.fx("prompt_basic.json", prompt="A request", prompt_id="pa")
        b_p = self.fx("prompt_basic.json", project=self.project_b, session_id="sess-b", prompt="B request", prompt_id="pb")
        b_s = self.fx("stop_basic.json", project=self.project_b, session_id="sess-b", prompt_id="pb", last_assistant_message="B answer")
        a_s = self.fx("stop_basic.json", prompt_id="pa", last_assistant_message="A answer")
        for payload in (a_p, b_p, b_s, a_s):
            self.assertHookOk(self.hook(payload))
        self.assertEqual(self.cli("show", "--project", self.project).stdout, b"A answer")
        self.assertEqual(self.cli("show", "--project", self.project_b).stdout, b"B answer")
        ctx_b = self.cli("context", "--project", self.project_b).stdout.decode()
        self.assertIn("B request", ctx_b)
        self.assertNotIn("A request", ctx_b)
        self.assertNotIn("A answer", ctx_b)
        self.assertEqual(len(self.records("sess-a")), 2)
        self.assertEqual(len(self.records("sess-b")), 2)

    # 4
    def test_s04_concurrent_stop_events(self):
        procs = []
        expected = {}
        for n in range(12):
            session = "sess-a" if n % 2 == 0 else "sess-b"
            project = self.project if session == "sess-a" else self.project_b
            text = f"concurrent answer {n} " + "x" * 50000
            payload = self.fx("stop_basic.json", project=project, session_id=session, prompt_id=f"p-{n}", last_assistant_message=text)
            expected.setdefault(session, set()).add(text)
            p = subprocess.Popen([sys.executable, str(BIN), "hook"], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env)
            procs.append((p, json.dumps(payload).encode()))
        for p, raw in procs:
            p.stdin.write(raw)
            p.stdin.close()
        for p, _ in procs:
            self.assertEqual(p.wait(timeout=30), 0)
            self.assertEqual(p.stdout.read(), b"")
            p.stdout.close()
            p.stderr.close()
        from prompt_relay.store import Store
        for session, texts in expected.items():
            result = Store(self.home).read_session(session)
            self.assertEqual(result.corrupt_lines, 0)
            got = {r["payload"]["last_assistant_message"] for r in result.records}
            self.assertEqual(got, texts)

    # 5
    def test_s05_duplicate_delivery(self):
        payload = self.fx("stop_basic.json")
        self.assertHookOk(self.hook(payload))
        self.assertHookOk(self.hook(payload))
        reordered = dict(reversed(list(payload.items())))  # same event, different key order
        self.assertHookOk(self.hook(reordered))
        self.assertEqual(len(self.records("sess-a")), 1)
        self.assertEqual(self.log_outcomes(), ["stored", "duplicate", "duplicate"])

    # 6
    def test_s06_empty_response(self):
        self.assertHookOk(self.hook(self.fx("prompt_basic.json")))
        self.assertHookOk(self.hook(self.fx("stop_empty.json")))
        self.assertEqual(self.cli("show").stdout, b"")
        out = self.cli("copy")
        self.assertEqual(out.returncode, 3)
        self.assertIn(b"empty", out.stderr)
        self.assertFalse(self.clip.exists())

    # 7
    def test_s07_missing_optional_fields(self):
        self.assertHookOk(self.hook(self.fx("prompt_minimal.json")))
        self.assertHookOk(self.hook(self.fx("stop_minimal.json")))
        self.assertHookOk(self.hook({"hook_event_name": "Stop", "cwd": self.project, "last_assistant_message": "no session id"}))
        self.assertHookOk(self.hook({"hook_event_name": "Stop", "session_id": "sess-x", "cwd": self.project}))
        self.assertEqual(self.cli("show", "--session", "sess-min").stdout, b"Minimal payload without optional fields.")
        out = self.cli("show", "--session", "sess-x")
        self.assertEqual(out.returncode, 3)
        self.assertIn(b"without a final message", out.stderr)
        self.assertIn("no-session", self.cli("sessions").stdout.decode())

    # 8
    def test_s08_long_markdown_with_code_blocks(self):
        text = _markdown_long()
        self.assertGreater(len(text.encode("utf-8")), 100_000)
        self.assertHookOk(self.hook(self.fx("stop_basic.json", last_assistant_message=text)))
        self.assertEqual(self.cli("show").stdout, text.encode("utf-8"))
        md = self.fx("stop_markdown.json")["last_assistant_message"]
        self.assertHookOk(self.hook(self.fx("stop_markdown.json", prompt_id="p-md")))
        self.assertEqual(self.cli("show").stdout, md.encode("utf-8"))
        ctx = self.cli("context").stdout.decode("utf-8")
        self.assertIn("`````markdown\n" + md + "\n`````", ctx)  # fence longer than the nested ````

    # 9
    def test_s09_unicode_and_special_characters(self):
        payload = self.fx("stop_unicode.json")
        self.assertHookOk(self.hook(payload))
        self.assertEqual(self.cli("show").stdout, payload["last_assistant_message"].encode("utf-8"))

    # 10
    def test_s10_corrupt_json(self):
        for raw in ((Path(__file__).parent / "fixtures" / "corrupt_truncated.json").read_bytes(),
                    b"", b"\xff\xfe not utf-8", b"[1, 2]", b"null", b"{}"):
            self.assertHookOk(self.hook(raw))
        self.assertFalse((self.home / "events").exists() and any((self.home / "events").iterdir()))
        self.assertEqual(self.log_outcomes(),
                         ["invalid_json", "invalid_json", "invalid_utf8", "invalid_payload", "invalid_payload", "ignored_event"])

    # 11
    def test_s11_storage_not_writable(self):
        blocker = self.tmp / "not-a-dir"
        blocker.write_text("x")
        env = dict(self.env, PROMPT_RELAY_HOME=str(blocker / "sub"))
        start = time.monotonic()
        proc = self.hook(self.fx("stop_basic.json"), env=env)
        self.assertHookOk(proc)
        self.assertLess(time.monotonic() - start, 5)
        # config cannot be read either: capture fails closed and says so on stderr only
        self.assertIn(b"prompt-relay:", proc.stderr)

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root bypasses file permissions")
    def test_s11b_session_file_read_only(self):
        from prompt_relay.store import Store
        self.assertHookOk(self.hook(self.fx("stop_basic.json")))
        path = Store(self.home).path_for("sess-a")
        os.chmod(path, 0o400)
        try:
            proc = self.hook(self.fx("stop_basic.json", prompt_id="p-ro"))
            self.assertHookOk(proc)
            self.assertIn(b"storage_unavailable", proc.stderr)
            self.assertEqual(self.cli("show").stdout, self.fx("stop_basic.json")["last_assistant_message"].encode())
        finally:
            os.chmod(path, 0o600)

    # 12
    def test_s12_ambiguous_request_response(self):
        self.assertHookOk(self.hook(self.fx("prompt_minimal.json", prompt="first")))
        self.assertHookOk(self.hook(self.fx("prompt_minimal.json", prompt="second")))
        self.assertHookOk(self.hook(self.fx("stop_minimal.json", last_assistant_message="which one?")))
        turns = self.cli("turns", "--session", "sess-min").stdout.decode()
        self.assertIn("link=ambiguous", turns)
        self.assertEqual(turns.count("no_matched_response"), 2)
        ctx = self.cli("context", "--session", "sess-min").stdout.decode()
        self.assertIn("ambiguous", ctx)
        self.assertNotIn("first", ctx)
        self.assertNotIn("second", ctx)
        self.assertEqual(self.cli("show", "--session", "sess-min").stdout, b"which one?")

    # 13
    def test_s13_background_tasks(self):
        self.assertHookOk(self.hook(self.fx("prompt_basic.json")))
        self.assertHookOk(self.hook(self.fx("stop_background.json")))
        self.assertIn("background_tasks_pending", self.cli("turns").stdout.decode())
        out = self.cli("copy")
        self.assertEqual(out.returncode, 0)
        self.assertIn(b"background tasks were still running", out.stderr)
        self.assertIn("may not be finished", self.cli("context").stdout.decode())
        # the session wakes up and stops again for the same prompt
        self.assertHookOk(self.hook(self.fx("stop_basic.json", last_assistant_message="Tests finished.")))
        turns = self.cli("turns").stdout.decode()
        self.assertEqual(len([ln for ln in turns.splitlines() if ln.strip()[:1].isdigit()]), 1)
        self.assertIn(" stop_received ", turns)
        self.assertEqual(self.cli("show").stdout, b"Tests finished.")

    # 14
    def test_s14_api_failure_instead_of_stop(self):
        self.assertHookOk(self.hook(self.fx("prompt_basic.json")))
        self.assertHookOk(self.hook(self.fx("stop_failure_rate_limit.json")))
        self.assertIn("api_error", self.cli("turns").stdout.decode())
        out = self.cli("copy")
        self.assertEqual(out.returncode, 3)
        self.assertIn(b"API error", out.stderr)
        self.assertFalse(self.clip.exists())
        ctx = self.cli("context").stdout.decode()
        self.assertIn("There is no successful final response", ctx)
        self.assertIn("API error type: rate_limit", ctx)
        self.assertNotIn("Reported by Claude] Verbatim", ctx)

    # 15
    def test_s15_copy_is_byte_exact(self):
        for name in ("stop_unicode.json", "stop_markdown.json"):
            payload = self.fx(name, prompt_id="p-" + name)
            self.assertHookOk(self.hook(payload))
            out = self.cli("copy", "--verify")
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertIn(b"MOCK", out.stderr)
            self.assertEqual(self.clip.read_bytes(), payload["last_assistant_message"].encode("utf-8"))

    # 16
    def test_s16_no_network_operations(self):
        from prompt_relay import cli, hook

        def forbidden(*args, **kwargs):
            raise AssertionError("network access attempted")

        with mock.patch.dict(os.environ, self.env, clear=True), \
                mock.patch.object(socket.socket, "connect", forbidden), \
                mock.patch.object(socket.socket, "connect_ex", forbidden), \
                mock.patch.object(socket, "create_connection", forbidden), \
                mock.patch.object(socket, "getaddrinfo", forbidden):
            for name in ("prompt_basic.json", "stop_basic.json"):
                event, outcome = hook.process(json.dumps(self.fx(name)).encode(), dict(self.env))
                self.assertEqual(outcome, "stored")
            with mock.patch("sys.stdout"), mock.patch("sys.stderr"):
                for argv in (["sessions"], ["turns"], ["show"], ["context"], ["copy"], ["copy-context"]):
                    self.assertEqual(cli.main(argv), 0, argv)

    # 17
    def test_s17_no_user_messages_in_git_changes(self):
        def repo_status() -> bytes:
            return subprocess.run(["git", "-C", str(REPO), "status", "--porcelain", "--ignored"],
                                  stdout=subprocess.PIPE, check=True).stdout

        before = repo_status()
        env = {k: v for k, v in self.env.items() if k != "PROMPT_RELAY_HOME"}
        self.assertEqual(self.cli("enable", self.project, env=env).returncode, 0)
        marker = "user-text-marker-" + os.urandom(8).hex()  # built at runtime: absent from sources
        self.assertHookOk(self.hook(self.fx("prompt_basic.json", prompt=marker), env=env))
        self.assertHookOk(self.hook(self.fx("stop_basic.json", last_assistant_message=marker), env=env))
        self.assertEqual(repo_status(), before)
        from prompt_relay.paths import data_dir
        default_dir = data_dir(env)  # the platform default under the temporary HOME
        self.assertTrue(str(default_dir).startswith(env["HOME"]))
        stored = (default_dir / "events" / "sess-a.jsonl").read_text()
        self.assertIn(marker, stored)
        grep = subprocess.run(["grep", "-rl", "--exclude-dir=.git", marker, str(REPO)], stdout=subprocess.PIPE)
        self.assertEqual(grep.stdout, b"", "user text must not appear inside the repository")

    # 18
    def test_s18_handler_stops_safely(self):
        from prompt_relay.store import Store
        self.assertHookOk(self.hook(self.fx("stop_basic.json")))
        path = Store(self.home).path_for("sess-a")
        # (a) another process holds the lock: the handler gives up, exits 0
        with open(path, "rb") as held:
            fcntl.flock(held.fileno(), fcntl.LOCK_EX)
            start = time.monotonic()
            proc = self.hook(self.fx("stop_basic.json", prompt_id="p-locked"))
            elapsed = time.monotonic() - start
        self.assertHookOk(proc)
        self.assertIn(b"lock_timeout", proc.stderr)
        self.assertLess(elapsed, 8, "must finish well inside the 10 s hook timeout")
        # (b) a writer killed mid-line leaves a partial line; the next event still lands
        with open(path, "ab") as fh:
            fh.write(b'{"schema":1,"payload":{"hook_event_name":"Stop","last_assist')
        self.assertHookOk(self.hook(self.fx("stop_basic.json", prompt_id="p-after", last_assistant_message="after crash")))
        result = Store(self.home).read_session("sess-a")
        self.assertEqual(result.corrupt_lines, 1)
        self.assertEqual(result.records[-1]["payload"]["last_assistant_message"], "after crash")
        self.assertEqual(self.cli("show").stdout, b"after crash")
        # (c) kill switch
        env = dict(self.env, PROMPT_RELAY_DISABLE="1")
        self.assertHookOk(self.hook(self.fx("stop_basic.json", prompt_id="p-disabled"), env=env))
        self.assertEqual(len(Store(self.home).read_session("sess-a").records), 2)


if __name__ == "__main__":
    unittest.main()
