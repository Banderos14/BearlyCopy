"""Phase 16: Global Capture, automatic projects, exclusions and pause.

The owner's case: Claude worked in a second repository that was never
enabled; its Stop was rejected ("project_not_enabled") and the answer was
never stored. With ``capture --global`` any project a connected agent works
in is captured and listed automatically; exclusions and pause win; every
config doubt fails closed; plugins older than 0.8.0 capture nothing rather
than ignore a pause.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import threading
from pathlib import Path

from helpers import REPO, IsolatedTestCase

from prompt_relay import config as _config


def prompt(session: str, cwd: str, text: str = "Задача 🐻", pid: str = "p1") -> dict:
    return {"hook_event_name": "UserPromptSubmit", "session_id": session, "cwd": cwd, "prompt": text, "prompt_id": pid}


def stop(session: str, cwd: str, text: str, pid: str = "p1") -> dict:
    return {"hook_event_name": "Stop", "session_id": session, "cwd": cwd, "prompt_id": pid,
            "last_assistant_message": text, "stop_hook_active": False}


class CapturePolicyTests(IsolatedTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.repos = self.tmp / "repos"
        self.prompt_relay = self.mkrepo("prompt-relay")
        self.theatre = self.mkrepo("tete-a-tete-theatre")
        self.third = self.mkrepo("third")

    def mkrepo(self, name: str, parent: Path = None) -> str:
        path = (parent or self.repos) / name
        (path / ".git").mkdir(parents=True)
        (path / ".git" / "HEAD").write_text("ref: refs/heads/main\n")
        return str(path.resolve())

    def json_cli(self, *args: str) -> dict:
        proc = self.cli(*args, "--json")
        doc = json.loads(proc.stdout)
        self.assertTrue(doc["ok"], doc)
        return doc["data"]

    def projects(self) -> dict:
        return {p["path"]: p for p in self.json_cli("projects")["projects"] if p["path"]}

    def outcomes(self) -> list:
        return [line.split()[-1] for line in (self.home / "handler.log").read_text().splitlines()]

    def run_turn(self, session: str, cwd: str, answer: str, pid: str = "p1") -> None:
        self.assertHookOk(self.hook(prompt(session, cwd, pid=pid)))
        self.assertHookOk(self.hook(stop(session, cwd, answer, pid=pid)))

    # -- the owner's workflow -------------------------------------------------

    def test_selected_mode_rejects_an_unknown_project_as_before(self) -> None:
        self.run_turn("s-theatre", self.theatre, "Сцена готова")
        self.assertEqual(self.outcomes()[-2:], ["project_not_enabled", "project_not_enabled"])
        self.assertEqual(self.json_cli("results", "--limit", "50")["results"], [])

    def test_global_mode_captures_new_projects_across_switches(self) -> None:
        self.cli("enable", self.prompt_relay)
        self.assertEqual(self.json_cli("capture", "--global")["mode"], "global")
        answers = {self.prompt_relay: "Relay answer", self.theatre: "Ответ театра ✅\n```js\nplay()\n```",
                   self.third: "Third answer"}
        for i, path in enumerate([self.prompt_relay, self.theatre, self.third]):
            self.run_turn("s%d" % i, path, answers[path])
        self.run_turn("s0", self.prompt_relay, "Relay again", pid="p2")   # back to the first repository
        self.assertEqual(self.outcomes().count("stored"), 8, self.outcomes())
        projects = self.projects()
        for path in answers:
            self.assertIn(path, projects, "discovered automatically")
            self.assertTrue(projects[path]["capture_enabled"])
            self.assertEqual(projects[path]["session_count"], 1)
        self.assertFalse(projects[self.theatre]["explicitly_enabled"], "no per-project step happened")
        results = self.json_cli("results", "--limit", "50")["results"]
        texts = {r["project"]["path"]: r for r in results}
        self.assertEqual(set(texts), set(answers), "every project's answer is in All Results")
        theatre = self.cli("show", "--session", "s1")
        self.assertEqual(theatre.stdout.decode().rstrip("\n"), answers[self.theatre], "stored verbatim")

    def test_same_folder_name_in_two_places_stays_two_projects(self) -> None:
        a = self.mkrepo("app", self.tmp / "work")
        b = self.mkrepo("app", self.tmp / "personal")
        self.cli("capture", "--global")
        self.run_turn("a1", a, "A")
        self.run_turn("b1", b, "B")
        projects = self.projects()
        self.assertIn(a, projects)
        self.assertIn(b, projects)
        self.assertEqual(projects[a]["logical_project"]["path"], a)
        self.assertEqual(projects[b]["logical_project"]["path"], b)

    def test_subfolders_group_and_nested_repositories_stay_independent(self) -> None:
        self.cli("capture", "--global")
        sub = os.path.join(self.theatre, "src", "scenes")
        os.makedirs(sub)
        nested = self.mkrepo("vendor-lib", Path(self.theatre) / "vendor")
        self.run_turn("t1", self.theatre, "root")
        self.run_turn("t2", sub, "sub")
        self.run_turn("t3", nested, "nested")
        projects = self.projects()
        self.assertEqual(projects[sub]["logical_project"]["path"], self.theatre, "a subfolder belongs to its repository")
        self.assertEqual(projects[nested]["logical_project"]["path"], nested, "a nested repository is its own project")

    def test_linked_worktree_is_its_own_project(self) -> None:
        self.cli("capture", "--global")
        wt = self.tmp / "theatre-feature"
        wt.mkdir()
        (wt / ".git").write_text("gitdir: %s/.git/worktrees/feature\n" % self.theatre)
        self.run_turn("w1", str(wt.resolve()), "worktree")
        self.run_turn("w2", self.theatre, "main")
        projects = self.projects()
        self.assertEqual(projects[str(wt.resolve())]["logical_project"]["path"], str(wt.resolve()))
        self.assertEqual(projects[self.theatre]["logical_project"]["path"], self.theatre)

    def test_symlinked_path_resolves_to_the_same_project(self) -> None:
        self.cli("capture", "--global")
        link = self.tmp / "theatre-link"
        link.symlink_to(self.theatre)
        self.run_turn("l1", str(link), "via link")
        self.run_turn("l2", self.theatre, "direct")
        projects = self.projects()
        theatre = [p for path, p in projects.items() if path in (str(link), self.theatre)]
        self.assertEqual({p["logical_project"]["path"] for p in theatre}, {self.theatre})
        self.assertEqual(len(theatre), 2, "the raw folders are kept as received (never rewritten)")

    def test_duplicate_delivery_is_stored_once(self) -> None:
        self.cli("capture", "--global")
        self.run_turn("d1", self.theatre, "once")
        self.assertHookOk(self.hook(stop("d1", self.theatre, "once")))
        self.assertEqual(self.outcomes()[-1], "duplicate")
        self.assertEqual(len(self.json_cli("results", "--limit", "50")["results"]), 1)

    def test_profiles_never_mix(self) -> None:
        self.cli("capture", "--global")
        work = dict(self.env, CLAUDE_CONFIG_DIR=str(self.tmp / "home" / ".claude-work"))
        self.assertHookOk(self.hook(prompt("same", self.theatre), env=self.env))
        self.assertHookOk(self.hook(stop("same", self.theatre, "personal"), env=self.env))
        self.assertHookOk(self.hook(prompt("same", self.theatre), env=work))
        self.assertHookOk(self.hook(stop("same", self.theatre, "work"), env=work))
        sessions = self.json_cli("sessions")["sessions"]
        self.assertEqual(len(sessions), 2, "one native id, two profiles, two sessions")

    def test_concurrent_sessions_in_different_projects(self) -> None:
        self.cli("capture", "--global")
        threads = [threading.Thread(target=self.run_turn, args=("c%d" % i, path, "answer %d" % i))
                   for i, path in enumerate([self.prompt_relay, self.theatre, self.third] * 2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        results = self.json_cli("results", "--limit", "50")["results"]
        self.assertEqual(len(results), 6)
        self.assertEqual(sorted(r["session_key"] for r in results), ["c%d" % i for i in range(6)])
        by_key = {r["session_key"]: r["project"]["path"] for r in results}
        for i, path in enumerate([self.prompt_relay, self.theatre, self.third] * 2):
            self.assertEqual(by_key["c%d" % i], path, "each answer under its own project")

    # -- exclusions, pause, scope -------------------------------------------

    def test_exclusion_wins_over_global_and_over_enable(self) -> None:
        self.cli("enable", self.theatre)
        self.cli("capture", "--global", "--exclude", self.theatre)
        self.run_turn("x1", os.path.join(self.theatre), "secret")
        self.assertEqual(self.outcomes()[-1], "project_excluded")
        self.assertFalse(self.projects()[self.theatre]["capture_enabled"])
        self.assertTrue(self.projects()[self.theatre]["excluded"])
        self.cli("enable", self.theatre)   # turning it back on removes the exclusion
        self.run_turn("x2", self.theatre, "visible")
        self.assertEqual(self.outcomes()[-1], "stored")

    def test_disable_in_global_mode_excludes(self) -> None:
        self.cli("capture", "--global")
        self.cli("disable", self.third)
        self.assertIn(self.third, self.json_cli("capture")["excluded_projects"])
        self.run_turn("y1", self.third, "no")
        self.assertEqual(self.outcomes()[-1], "project_excluded")

    def test_pause_stores_nothing_and_resume_restores_the_mode(self) -> None:
        self.cli("capture", "--global")
        self.cli("capture", "--pause")
        self.run_turn("p1", self.theatre, "paused")
        self.assertEqual(self.outcomes()[-2:], ["capture_paused", "capture_paused"])
        self.assertEqual(self.json_cli("results", "--limit", "50")["results"], [])
        self.assertEqual(self.json_cli("capture", "--resume")["mode"], "global")
        self.run_turn("p2", self.theatre, "resumed")
        self.assertEqual(self.outcomes()[-1], "stored")

    def test_global_never_captures_home_root_system_or_credentials(self) -> None:
        self.cli("capture", "--global")
        home = str(Path(self.env["HOME"]).resolve())
        os.makedirs(os.path.join(home, ".ssh"), exist_ok=True)
        for i, path in enumerate([home, "/", "/usr/local", os.path.join(home, ".ssh"), os.path.join(home, "Library")]):
            self.assertHookOk(self.hook(stop("z%d" % i, path, "x")))
            self.assertEqual(self.outcomes()[-1], "outside_capture_scope", path)

    def test_missing_or_relative_cwd_is_rejected(self) -> None:
        self.cli("capture", "--global")
        self.assertHookOk(self.hook({"hook_event_name": "Stop", "session_id": "m1", "last_assistant_message": "x"}))
        self.assertEqual(self.outcomes()[-1], "no_project_dir")
        self.assertHookOk(self.hook(stop("m2", "relative/dir", "x")))
        self.assertEqual(self.outcomes()[-1], "no_project_dir")
        self.assertHookOk(self.hook(stop("m3", 42, "x")))
        self.assertEqual(self.outcomes()[-1], "no_project_dir")

    # -- config safety ---------------------------------------------------------

    def test_broken_or_unknown_config_fails_closed(self) -> None:
        self.cli("capture", "--global")
        cfg = self.home / "config.json"
        good = cfg.read_text()
        for bad, code in [("{not json", "config_invalid_json"),
                          (good.replace('"global"', '"everything"'), "config_invalid_capture_mode"),
                          (good.replace('"excluded_projects": []', '"excluded_projects": "x"'), "config_invalid_excluded_projects"),
                          (good.replace('"schema": 2', '"schema": 3'), "config_unsupported")]:
            cfg.write_text(bad)
            self.assertHookOk(self.hook(stop("f-" + code, self.theatre, "x")))
            self.assertEqual(self.outcomes()[-1], code)
        cfg.write_text(good)
        self.assertEqual(self.json_cli("capture")["mode"], "global")

    def test_existing_schema_1_config_is_unchanged_and_selected(self) -> None:
        cfg = json.loads((self.home / "config.json").read_text())
        self.assertEqual(cfg["schema"], 1, "nothing migrates until the user picks a mode")
        self.assertEqual(self.json_cli("capture")["mode"], "selected")
        self.cli("capture", "--selected")
        self.assertEqual(json.loads((self.home / "config.json").read_text())["schema"], 1)
        self.cli("capture", "--global")
        self.cli("capture", "--selected")
        self.assertEqual(json.loads((self.home / "config.json").read_text())["schema"], 1,
                         "back to the old shape when the policy is the default again")

    def test_a_0_4_1_plugin_captures_nothing_with_a_capture_mode_set(self) -> None:
        """The real config loader of plugin 0.4.1 (commit 0dffa80) refuses schema 2."""
        try:
            source = subprocess.run(["git", "-C", str(REPO), "show", "0dffa80:plugin/prompt_relay/config.py"],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True).stdout
        except (subprocess.CalledProcessError, FileNotFoundError):
            self.skipTest("commit 0dffa80 not in this clone")
        old_file = self.tmp / "old_config.py"
        old_file.write_bytes(source)
        spec = importlib.util.spec_from_file_location("old_config", str(old_file))
        old = importlib.util.module_from_spec(spec)
        import sys
        sys.modules["old_config"] = old
        try:
            spec.loader.exec_module(old)
        finally:
            sys.modules.pop("old_config", None)
        self.cli("capture", "--pause")
        loaded = old.load(self.home)
        self.assertTrue(loaded.error, "an old hook sees an unusable config and stores nothing (fails closed)")
        self.assertFalse(old.is_enabled(loaded, self.project))
        self.cli("capture", "--selected")   # schema 1 again: the old plugin works as before
        self.assertFalse(old.load(self.home).error)

    def test_doctor_flags_an_old_plugin_once_a_mode_is_set(self) -> None:
        cache = self.tmp / "home" / ".claude" / "plugins"
        root = cache / "cache" / "prompt-relay" / "prompt-relay" / "0.4.1"
        shutil.copytree(str(REPO / "plugin"), str(root), ignore=shutil.ignore_patterns("__pycache__"))
        manifest = root / ".claude-plugin" / "plugin.json"
        data = json.loads(manifest.read_text())
        data["version"] = "0.4.1"
        manifest.write_text(json.dumps(data))
        (cache / "installed_plugins.json").write_text(json.dumps({"version": 2, "plugins": {
            "prompt-relay@prompt-relay": [{"scope": "user", "installPath": str(root), "version": "0.4.1"}]}}))
        before = [f["code"] for f in self.json_cli("doctor", "--no-project")["findings"]]
        self.assertNotIn("plugin_too_old_for_capture_mode", before)
        self.cli("capture", "--global")
        after = [f["code"] for f in self.json_cli("doctor", "--no-project")["findings"]]
        self.assertIn("plugin_too_old_for_capture_mode", after)

    def test_capture_config_is_written_atomically_and_privately(self) -> None:
        self.cli("capture", "--global", "--exclude", self.third)
        cfg = self.home / "config.json"
        self.assertEqual(oct(cfg.stat().st_mode & 0o777), "0o600")
        self.assertEqual([p.name for p in self.home.iterdir() if p.name.endswith(".tmp")], [])
        self.assertEqual(_config.load(self.home).excluded_projects, [self.third])
