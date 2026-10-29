"""Phase 2A: JSON API contract, golden files, history management, path safety.

Golden files: tests/golden/cases/<case>.json describe hook events and CLI
queries; tests/golden/expected/<case>.json hold the expected responses.
Regenerate after an intentional change (then review the diff and follow the
versioning rules in docs/JSON_API.md §6):

    PROMPT_RELAY_UPDATE_GOLDEN=1 python3 -m unittest discover -s tests -k Golden
"""

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from typing import Any, Dict, List

from helpers import BIN, FIXTURES, REPO, IsolatedTestCase
from jsonschema_lite import validate_response

from prompt_relay import config, hook, retention
from prompt_relay.store import SessionFile, Store, StoreError

GOLDEN = REPO / "tests" / "golden"
SCHEMA = json.loads((REPO / "docs" / "api" / "api-v1.schema.json").read_text(encoding="utf-8"))
BASE_EPOCH = 1767225600.0  # 2026-01-01T00:00:00Z: fixed event times make golden output stable
FIXED_EXPORTED_AT = "2000-01-01T00:00:00.000000Z"  # context exported_at is wall-clock time
UPDATE = os.environ.get("PROMPT_RELAY_UPDATE_GOLDEN") == "1"


def run_json(args: List[str], env: Dict[str, str]) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(BIN), *args, "--json"], env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)


class JsonContractMixin:
    def parse_json_output(self, proc: subprocess.CompletedProcess) -> Dict[str, Any]:
        self.assertEqual(proc.stderr, b"", "--json mode must not write to stderr")
        out = proc.stdout
        self.assertTrue(out.endswith(b"\n") and out.count(b"\n") == 1, "exactly one JSON line on stdout")
        self.assertTrue(out.isascii(), "JSON output is pure ASCII")
        doc = json.loads(out)
        self.assertEqual(validate_response(doc, SCHEMA), [])
        self.assertEqual(doc["api_version"], 1)
        self.assertEqual(doc["ok"], proc.returncode == 0, "ok is true exactly when the exit code is 0")
        self.assertEqual(doc["ok"], doc["error"] is None)
        return doc


class GoldenTests(JsonContractMixin, unittest.TestCase):
    maxDiff = None

    def run_case(self, case_path: Path) -> Dict[str, Any]:
        case = json.loads(case_path.read_text(encoding="utf-8"))
        tmp = Path(tempfile.mkdtemp(prefix="pr-golden-"))
        projects = {k: str((tmp / f"project-{k.lower()}").resolve()) for k in ("A", "B")}
        for p in projects.values():
            os.makedirs(p)
        home = tmp / "data"
        config.save(home, config.Config(enabled_projects=sorted(projects.values())))

        def subst(text: str) -> str:
            for k, p in projects.items():
                text = text.replace(f"__PROJECT_{k}__", p)
            return text

        n = 0
        for step in case["events"]:
            if "fixture" in step:
                raw = (FIXTURES / step["fixture"]).read_text(encoding="utf-8").replace(
                    "__PROJECT_A__", f"__PROJECT_{step.get('project', 'A')}__")
                payload = json.loads(subst(raw))
            else:
                payload = json.loads(subst(json.dumps(step["payload"])))
            payload.update(json.loads(subst(json.dumps(step.get("override", {})))))
            for _ in range(step.get("repeat", 1)):
                raw_bytes = json.dumps(payload, ensure_ascii=False).encode("utf-8")
                outcome = hook.process(raw_bytes, {}, now=BASE_EPOCH + n, root=home)[1]
                self.assertIn(outcome, ("stored", "duplicate"))
                n += 1

        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(tmp / "home"),
               "PROMPT_RELAY_HOME": str(home), "LANG": "C.UTF-8"}
        results = {}
        for name, argv in case["queries"].items():
            proc = run_json([subst(a) for a in argv], env)
            doc = self.parse_json_output(proc)
            results[name] = {"argv": argv, "exit_code": proc.returncode, "response": self.normalize(doc, projects, tmp)}
        return results

    @staticmethod
    def normalize(doc: Any, projects: Dict[str, str], tmp: Path) -> Any:
        exported = None
        if isinstance(doc.get("data"), dict) and "exported_at" in doc["data"]:
            exported = doc["data"]["exported_at"]

        def walk(v: Any) -> Any:
            if isinstance(v, dict):
                return {k: walk(x) for k, x in v.items()}
            if isinstance(v, list):
                return [walk(x) for x in v]
            if isinstance(v, str):
                if exported:
                    v = v.replace(exported, FIXED_EXPORTED_AT)
                for k, p in projects.items():
                    v = v.replace(p, f"__PROJECT_{k}__")
                return v.replace(str(tmp), "__TMP__")
            return v
        return walk(doc)

    def test_golden_cases(self):
        cases = sorted((GOLDEN / "cases").glob("*.json"))
        self.assertGreaterEqual(len(cases), 13)
        for case_path in cases:
            with self.subTest(case_path.stem):
                results = self.run_case(case_path)
                expected_path = GOLDEN / "expected" / case_path.name
                if UPDATE:
                    expected_path.write_text(json.dumps(results, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
                                             encoding="utf-8")
                    continue
                self.assertTrue(expected_path.exists(), f"missing {expected_path}; run with PROMPT_RELAY_UPDATE_GOLDEN=1")
                expected = json.loads(expected_path.read_text(encoding="utf-8"))
                self.assertEqual(results, expected)

    @unittest.skipIf(UPDATE, "expected files are being regenerated")
    def test_expected_files_are_schema_valid_and_versioned(self):
        for path in sorted((GOLDEN / "expected").glob("*.json")):
            for name, result in json.loads(path.read_text(encoding="utf-8")).items():
                with self.subTest(f"{path.stem}:{name}"):
                    self.assertEqual(result["response"]["api_version"], 1)
                    self.assertEqual(validate_response(result["response"], SCHEMA), [])

    @unittest.skipIf(UPDATE, "expected files are being regenerated")
    def test_golden_texts_are_verbatim(self):
        # The full text in show --json must equal the fixture text exactly.
        expected = json.loads((GOLDEN / "expected" / "09_unicode_markdown.json").read_text(encoding="utf-8"))
        for query, fixture in (("show_unicode", "stop_unicode.json"), ("show_markdown", "stop_markdown.json")):
            want = json.loads((FIXTURES / fixture).read_text(encoding="utf-8"))["last_assistant_message"]
            got = expected[query]["response"]["data"]["turn"]["final_response"]["text"]
            self.assertEqual(got, want)


class JsonApiTests(JsonContractMixin, IsolatedTestCase):
    def jcli(self, *args: str) -> Dict[str, Any]:
        proc = run_json(list(args), self.env)
        doc = self.parse_json_output(proc)
        doc["_exit"] = proc.returncode
        return doc

    def test_text_mode_unchanged(self):
        self.assertHookOk(self.hook(self.fx("prompt_basic.json")))
        self.assertHookOk(self.hook(self.fx("stop_basic.json")))
        self.assertEqual(self.cli("show").stdout, self.fx("stop_basic.json")["last_assistant_message"].encode())
        self.assertIn(b"stop_received", self.cli("sessions").stdout)
        self.assertNotIn(b"api_version", self.cli("turns").stdout)

    def test_usage_errors_are_json(self):
        for args in (["show", "--turn", "x"], ["sessions", "--bogus"], ["prune", "--older-than-days", "0"]):
            with self.subTest(args):
                doc = self.jcli(*args)
                self.assertEqual((doc["_exit"], doc["error"]["code"]), (2, "usage_error"))

    def test_lone_surrogate_and_nul_survive_json(self):
        text = "a\ud800b\x00c 👍 \r\n"
        payload = self.fx("stop_basic.json", last_assistant_message=text)
        self.assertEqual(hook.process(json.dumps(payload).encode(), dict(self.env), root=self.home)[1], "stored")
        doc = self.jcli("show")
        self.assertEqual(doc["data"]["turn"]["final_response"]["text"], text)
        self.assertEqual(doc["data"]["turn"]["final_response"]["char_count"], len(text))

    def test_warnings_go_into_json_not_stderr(self):
        self.assertHookOk(self.hook(self.fx("stop_background.json")))
        with open(Store(self.home).path_for("sess-a"), "ab") as fh:
            fh.write(b"garbage\n")
        doc = self.jcli("show")
        codes = [w["code"] for w in doc["warnings"]]
        self.assertIn("background_tasks_pending", codes)
        self.assertIn("corrupt_lines_skipped", codes)

    def test_preview_is_truncated_but_show_is_full(self):
        long_text = "x" * 500 + "😀"
        self.assertHookOk(self.hook(self.fx("stop_basic.json", last_assistant_message=long_text)))
        turn = self.jcli("turns")["data"]["turns"][0]["final_response"]
        self.assertEqual((len(turn["preview"]), turn["truncated"], turn["char_count"]), (200, True, 501))
        self.assertNotIn("text", turn)
        self.assertEqual(turn["utf8_bytes"], 504)
        self.assertEqual(self.jcli("show")["data"]["turn"]["final_response"]["text"], long_text)

    def test_context_json_reports_findings_without_values(self):
        secret = "AKIA" + "ABCDEFGHIJKLMNOP"
        self.assertHookOk(self.hook(self.fx("stop_basic.json", last_assistant_message="key " + secret)))
        doc = self.jcli("context")
        self.assertEqual(doc["data"]["sensitive_findings"], [{"section": "response", "line": 1, "kind": "AWS access key id"}])
        self.assertIn("sensitive_content", [w["code"] for w in doc["warnings"]])
        self.assertIn(secret, doc["data"]["text"])  # the text itself is verbatim; the UI decides
        self.assertNotIn(secret, json.dumps(doc["warnings"]))

    def test_storage_error_is_json(self):
        os.symlink(str(self.tmp), str(self.home / "events"))
        proc = run_json(["sessions"], self.env)
        doc = self.parse_json_output(proc)
        self.assertEqual((proc.returncode, doc["error"]["code"]), (1, "unsafe_path"))


class HistoryManagementTests(JsonContractMixin, IsolatedTestCase):
    def store_old(self, session_id: str, days_old: float, project: str = None, text: str = "old answer") -> Path:
        payload = self.fx("stop_basic.json", project=project, session_id=session_id, prompt_id="p-" + session_id,
                          last_assistant_message=text)
        when = time.time() - days_old * 86400
        self.assertEqual(hook.process(json.dumps(payload).encode(), dict(self.env), now=when, root=self.home)[1], "stored")
        path = Store(self.home).path_for(session_id)
        os.utime(str(path), (when, when))
        return path

    def test_prune_is_dry_run_by_default(self):
        old = self.store_old("old-1", 40)
        doc = run_json(["prune", "--older-than-days", "30"], self.env)
        data = self.parse_json_output(doc)["data"]
        self.assertTrue(data["dry_run"])
        self.assertEqual([(i["session_id"], i["action"]) for i in data["items"]], [("old-1", "would_delete")])
        self.assertTrue(old.exists())
        text = self.cli("prune", "--older-than-days", "30")
        self.assertEqual(text.returncode, 0)
        self.assertIn(b"dry run: 1 session file(s) would be deleted", text.stdout)
        self.assertTrue(old.exists())

    def test_prune_yes_deletes_only_old_sessions_and_nothing_else(self):
        old = self.store_old("old-1", 40)
        middle = self.store_old("mid-1", 10)
        self.assertHookOk(self.hook(self.fx("stop_basic.json", session_id="new-1")))
        (self.home / "events" / "notes.txt").write_text("not a session")
        doc = self.parse_json_output(run_json(["prune", "--older-than-days", "30", "--yes"], self.env))
        self.assertFalse(doc["data"]["dry_run"])
        self.assertEqual(doc["data"]["summary"]["deleted"], 1)
        self.assertFalse(old.exists())
        self.assertTrue(middle.exists())
        self.assertTrue(Store(self.home).path_for("new-1").exists())
        for kept in ("config.json", "handler.log", "events/notes.txt"):
            self.assertTrue((self.home / kept).exists(), kept)

    def test_retention_setting_drives_prune_and_is_never_automatic(self):
        self.assertEqual(self.jcli("prune")["error"]["code"], "usage_error")  # nothing configured
        doc = self.jcli("retention", "--days", "30")
        self.assertEqual(doc["data"], {"retention_days": 30, "automatic_deletion": False})
        self.assertEqual(self.jcli("retention", "--days", "0")["error"]["code"], "usage_error")
        old = self.store_old("old-1", 40)
        # capturing new events never prunes, even with retention configured
        self.assertHookOk(self.hook(self.fx("stop_basic.json", session_id="new-1")))
        self.assertTrue(old.exists())
        self.assertEqual(self.jcli("prune")["data"]["items"][0]["action"], "would_delete")
        self.assertEqual(self.jcli("retention", "--off")["data"]["retention_days"], None)
        # enable/disable keep the retention setting
        self.jcli("retention", "--days", "7")
        self.assertEqual(self.cli("disable", self.project_b).returncode, 0)
        self.assertEqual(config.load(self.home).retention_days, 7)

    def jcli(self, *args: str) -> Dict[str, Any]:
        return self.parse_json_output(run_json(list(args), self.env))

    def test_invalid_retention_value_never_disables_capture(self):
        cfg = json.loads((self.home / "config.json").read_text())
        cfg["retention_days"] = "forever"
        (self.home / "config.json").write_text(json.dumps(cfg))
        self.assertHookOk(self.hook(self.fx("stop_basic.json")))
        self.assertEqual(len(self.records("sess-a")), 1)
        doc = self.jcli("projects")
        self.assertIn("retention_setting_invalid", [w["code"] for w in doc["warnings"]])

    def test_delete_preview_confirmation_and_active_protection(self):
        self.assertHookOk(self.hook(self.fx("stop_basic.json")))
        path = Store(self.home).path_for("sess-a")
        proc = run_json(["delete", "--session", "sess-a"], self.env)
        doc = self.parse_json_output(proc)
        self.assertEqual((proc.returncode, doc["error"]["code"], doc["data"]["dry_run"]), (2, "confirmation_required", True))
        dry = self.jcli("delete", "--session", "sess-a", "--dry-run")
        self.assertEqual(dry["data"]["items"][0]["action"], "skipped_active")
        proc = run_json(["delete", "--session", "sess-a", "--yes"], self.env)
        doc = self.parse_json_output(proc)
        self.assertEqual((proc.returncode, doc["error"]["code"]), (6, "active_session"))
        self.assertTrue(path.exists())
        forced = self.jcli("delete", "--session", "sess-a", "--yes", "--force-active")
        self.assertEqual(forced["data"]["items"][0]["action"], "deleted")
        self.assertFalse(path.exists())
        self.assertEqual(self.jcli("delete", "--session", "nope", "--yes")["error"]["code"], "not_found")

    def test_file_written_after_planning_is_kept(self):
        self.store_old("old-1", 40)
        store = Store(self.home)
        plan = retention.plan_prune(store, 30)
        self.assertHookOk(self.hook(self.fx("stop_basic.json", session_id="old-1", prompt_id="late")))
        retention.execute(store, plan)
        self.assertEqual(plan.items[0].action, retention.SKIPPED_CHANGED)
        self.assertEqual(len(store.read_session("old-1").records), 2)

    def test_hook_waiting_for_lock_survives_concurrent_delete(self):
        # Regression: a hook blocked on the lock of a file that is then
        # deleted used to write into the unlinked inode (event lost).
        self.assertHookOk(self.hook(self.fx("stop_basic.json")))
        path = Store(self.home).path_for("sess-a")
        held = open(path, "rb")
        fcntl.flock(held.fileno(), fcntl.LOCK_EX)
        proc = subprocess.Popen([sys.executable, str(BIN), "hook"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=self.env)
        proc.stdin.write(json.dumps(self.fx("stop_basic.json", prompt_id="after-delete",
                                            last_assistant_message="survivor")).encode())
        proc.stdin.close()
        time.sleep(0.7)  # the hook has opened the file and waits for the lock
        os.unlink(str(path))
        held.close()
        self.assertEqual(proc.wait(timeout=30), 0)
        proc.stdout.close()
        proc.stderr.close()
        records = Store(self.home).read_session("sess-a").records
        self.assertEqual([r["payload"]["last_assistant_message"] for r in records], ["survivor"])


    def test_select_by_session_key(self):
        self.assertHookOk(self.hook({"hook_event_name": "Stop", "cwd": self.project, "last_assistant_message": "orphan"}))
        self.assertHookOk(self.hook(self.fx("stop_basic.json", session_id="weird/id", last_assistant_message="hashed")))
        keys = {s["session_id"]: s["session_key"] for s in self.jcli("sessions")["data"]["sessions"]}
        self.assertEqual(keys[None], "_no-session")
        self.assertTrue(keys["weird/id"].startswith("h-"))
        self.assertEqual(self.cli("show", "--session", keys["weird/id"]).stdout, b"hashed")
        self.assertEqual(self.cli("show", "--session", "_no-session").stdout, b"orphan")
        doc = self.jcli("delete", "--session", "_no-session", "--yes", "--force-active")
        self.assertEqual(doc["data"]["items"][0]["action"], "deleted")

    def test_concurrent_hooks_and_deletes_never_corrupt(self):
        procs = []
        for n in range(16):
            p = subprocess.Popen([sys.executable, str(BIN), "hook"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, env=self.env)
            procs.append((p, json.dumps(self.fx("stop_basic.json", session_id=f"s{n % 3}", prompt_id=f"p{n}",
                                                 last_assistant_message="x" * 20000)).encode()))
        deleters = [subprocess.Popen([sys.executable, str(BIN), "delete", "--all", "--yes", "--force-active", "--json"],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env) for _ in range(3)]
        for p, raw in procs:
            p.stdin.write(raw)
            p.stdin.close()
        for p, _ in procs:
            self.assertEqual(p.wait(timeout=60), 0)
            self.assertEqual(p.stdout.read(), b"")
            p.stdout.close()
            p.stderr.close()
        for d in deleters:
            out, err = d.communicate(timeout=60)
            self.assertIn(d.returncode, (0, 1))
            self.assertEqual(validate_response(json.loads(out), SCHEMA), [])
        stored = sum(1 for line in (self.home / "handler.log").read_text().splitlines() if line.endswith(" stored"))
        self.assertEqual(stored, 16, "every hook stored its event (into a live or a recreated file)")
        for sf in Store(self.home).session_files():
            self.assertEqual(Store(self.home).read_path(sf.path).corrupt_lines, 0)


class PathSafetyTests(JsonContractMixin, IsolatedTestCase):
    def outside_file(self) -> Path:
        target = self.tmp / "precious.txt"
        target.write_text("user file that must survive")
        return target

    def test_symlinked_session_file_is_never_read_written_or_deleted(self):
        target = self.outside_file()
        os.makedirs(self.home / "events", exist_ok=True)
        os.symlink(str(target), str(self.home / "events" / "sess-a.jsonl"))
        proc = self.hook(self.fx("stop_basic.json"))
        self.assertHookOk(proc)
        self.assertIn(b"unsafe_path", proc.stderr)
        self.assertEqual(self.cli("sessions").stdout, b"no captured sessions\n")
        self.assertEqual(self.cli("delete", "--all", "--yes", "--force-active").returncode, 0)
        self.assertEqual(target.read_text(), "user file that must survive")
        self.assertTrue(os.path.islink(str(self.home / "events" / "sess-a.jsonl")))

    def test_symlinked_events_dir_is_refused(self):
        outside = self.tmp / "elsewhere"
        outside.mkdir()
        keep = outside / "x.jsonl"
        keep.write_text("{}\n")
        os.symlink(str(outside), str(self.home / "events"))
        proc = self.hook(self.fx("stop_basic.json"))
        self.assertHookOk(proc)
        self.assertIn(b"unsafe_path", proc.stderr)
        for args in (["delete", "--all", "--yes", "--force-active"], ["prune", "--older-than-days", "1", "--yes"]):
            proc = run_json(args, self.env)
            self.assertEqual(self.parse_json_output(proc)["error"]["code"], "unsafe_path")
        self.assertEqual(keep.read_text(), "{}\n")
        self.assertEqual(sorted(p.name for p in outside.iterdir()), ["x.jsonl"])

    def test_safe_unlink_refuses_anything_outside_events(self):
        target = self.outside_file()
        st = target.stat()
        store = Store(self.home)
        store.ensure()
        for path in (target, self.home / "config.json", self.home / "events" / ".." / "config.json"):
            with self.subTest(str(path)):
                sf = SessionFile("x", Path(path), st.st_mtime, st.st_size)
                with self.assertRaises(StoreError) as ctx:
                    store.safe_unlink(sf)
                self.assertEqual(ctx.exception.code, "unsafe_path")
        self.assertTrue(target.exists())
        self.assertTrue((self.home / "config.json").exists())

    def test_non_session_names_in_events_are_ignored(self):
        os.makedirs(self.home / "events", exist_ok=True)
        for name in (".hidden.jsonl", "notes.txt", "-dash.jsonl"):
            (self.home / "events" / name).write_text("{}\n")
        self.assertHookOk(self.hook(self.fx("stop_basic.json")))
        self.assertEqual([sf.key for sf in Store(self.home).session_files()], ["sess-a"])
        self.assertEqual(self.cli("delete", "--all", "--yes", "--force-active").returncode, 0)
        self.assertEqual(sorted(p.name for p in (self.home / "events").iterdir()), ["-dash.jsonl", ".hidden.jsonl", "notes.txt"])

    def test_dedup_ignores_damaged_epoch(self):
        # Regression: a damaged duplicate line (non-numeric epoch) crashed the append.
        payload = {"hook_event_name": "Stop", "session_id": "s", "cwd": self.project, "last_assistant_message": "m"}
        rec = hook.build_record(payload, {}, 1000.0)
        rec["received_at_epoch"] = "not-a-number"
        store = Store(self.home)
        store.ensure()
        with open(store.path_for("s"), "ab") as fh:
            fh.write(json.dumps(rec).encode() + b"\n")
        self.assertEqual(store.append(hook.build_record(payload, {}, 1001.0)), "stored")


if __name__ == "__main__":
    unittest.main()
