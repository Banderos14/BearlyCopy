"""Phase 9.3: logical projects (Project Intelligence).

A session run from ``<repo>/macos`` (Xcode's Codex) belongs to the project
``<repo>``; different repositories never merge, even under one enabled
folder or with the same folder name. Only stats paths; never runs git.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from helpers import BIN, IsolatedTestCase

from prompt_relay import projects


def make_repo(path: Path) -> Path:
    (path / ".git").mkdir(parents=True)
    (path / ".git" / "HEAD").write_text("ref: refs/heads/main\n")
    return path


class ResolverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="pr-projects-")).resolve()

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_nested_folder_of_enabled_repo_is_the_repo(self) -> None:
        repo = make_repo(self.tmp / "prompt-relay")
        (repo / "macos").mkdir()
        (repo / "macos" / "Package.swift").write_text("// swift")
        r = projects.Resolver([str(repo)])
        self.assertEqual(r.resolve(str(repo / "macos")),
                         {"path": str(repo), "name": "prompt-relay", "basis": "enabled_project"})
        self.assertEqual(r.resolve(str(repo))["path"], str(repo))

    def test_git_root_without_enabled_binding(self) -> None:
        repo = make_repo(self.tmp / "app")
        (repo / "macos").mkdir()
        self.assertEqual(projects.Resolver([]).resolve(str(repo / "macos")),
                         {"path": str(repo), "name": "app", "basis": "git_root"})

    def test_broad_enabled_folder_never_merges_repositories(self) -> None:
        a = make_repo(self.tmp / "work" / "a")
        b = make_repo(self.tmp / "work" / "b")
        (a / "macos").mkdir()
        (b / "macos").mkdir()
        r = projects.Resolver([str(self.tmp / "work")])
        self.assertEqual(r.resolve(str(a / "macos"))["path"], str(a))
        self.assertEqual(r.resolve(str(b / "macos"))["path"], str(b))
        self.assertEqual(r.resolve(str(a / "macos"))["basis"], "git_root")

    def test_same_folder_names_in_different_repositories_stay_apart(self) -> None:
        a = make_repo(self.tmp / "x" / "site")
        b = make_repo(self.tmp / "y" / "site")
        r = projects.Resolver([str(a), str(b)])
        self.assertNotEqual(r.resolve(str(a))["path"], r.resolve(str(b))["path"])
        self.assertEqual(r.resolve(str(a))["name"], r.resolve(str(b))["name"])

    def test_more_specific_enabled_project_inside_repo_is_kept(self) -> None:
        repo = make_repo(self.tmp / "repo")
        smoke = repo / "acceptance" / "smoke"
        smoke.mkdir(parents=True)
        r = projects.Resolver([str(repo), str(smoke)])
        self.assertEqual(r.resolve(str(smoke))["path"], str(smoke))
        self.assertEqual(r.resolve(str(repo / "acceptance"))["path"], str(repo))

    def test_no_git_root_falls_back_to_workspace_then_directory(self) -> None:
        ws = self.tmp / "pkg"
        ws.mkdir()
        (ws / "App.xcodeproj").mkdir()
        plain = self.tmp / "plain"
        plain.mkdir()
        r = projects.Resolver([])
        self.assertEqual(r.resolve(str(ws))["basis"], "workspace")
        self.assertEqual(r.resolve(str(plain)), {"path": str(plain), "name": "plain", "basis": "directory"})
        gone = str(self.tmp / "deleted")
        self.assertEqual(r.resolve(gone)["path"], gone)
        self.assertIsNone(r.resolve(None))

    def test_linked_worktree_git_file_is_a_root(self) -> None:
        wt = self.tmp / "wt"
        (wt / "sub").mkdir(parents=True)
        (wt / ".git").write_text("gitdir: /elsewhere/.git/worktrees/wt\n")
        self.assertEqual(projects.Resolver([]).resolve(str(wt / "sub"))["path"], str(wt))

    def test_symlinked_or_fake_dot_git_is_not_a_root(self) -> None:
        real = make_repo(self.tmp / "real")
        fake = self.tmp / "fake"
        (fake / "sub").mkdir(parents=True)
        os.symlink(real / ".git", fake / ".git")
        other = self.tmp / "other"
        (other / ".git").mkdir(parents=True)  # no HEAD: not a repository
        r = projects.Resolver([])
        self.assertEqual(r.resolve(str(fake / "sub"))["basis"], "directory")
        self.assertEqual(r.resolve(str(other))["basis"], "directory")

    def test_symlinked_cwd_is_canonicalized(self) -> None:
        repo = make_repo(self.tmp / "repo")
        (repo / "macos").mkdir()
        link = self.tmp / "link"
        os.symlink(repo, link)
        self.assertEqual(projects.Resolver([]).resolve(str(link / "macos"))["path"], str(repo))

    def test_never_runs_a_command(self) -> None:
        repo = make_repo(self.tmp / "repo")
        with mock.patch.object(subprocess, "run", side_effect=AssertionError("no commands")), \
             mock.patch.object(subprocess, "Popen", side_effect=AssertionError("no commands")):
            self.assertEqual(projects.Resolver([]).resolve(str(repo))["basis"], "git_root")


class LogicalProjectApiTests(IsolatedTestCase):
    """Scenario F: Claude at the Git root and Codex in ``macos/`` share one project."""

    def test_sessions_and_projects_report_the_logical_project(self) -> None:
        repo = make_repo(Path(self.project))
        nested = repo / "macos"
        nested.mkdir()
        self.assertHookOk(self.hook({"hook_event_name": "UserPromptSubmit", "session_id": "claude-1",
                                     "prompt_id": "p1", "cwd": str(repo), "prompt": "A"}))
        self.assertHookOk(self.hook({"hook_event_name": "UserPromptSubmit", "session_id": "nested-1",
                                     "prompt_id": "p2", "cwd": str(nested), "prompt": "B"}))
        out = json.loads(self.cli("sessions", "--json").stdout)
        logical = {s["session_id"]: s["logical_project"] for s in out["data"]["sessions"]}
        self.assertEqual(logical["claude-1"]["path"], str(repo))
        self.assertEqual(logical["nested-1"]["path"], str(repo))
        raw = {s["session_id"]: s["project"]["path"] for s in out["data"]["sessions"]}
        self.assertEqual(raw["nested-1"], str(nested), "the real cwd is kept")
        rows = json.loads(self.cli("projects", "--json").stdout)["data"]["projects"]
        by_path = {p["path"]: p for p in rows}
        self.assertEqual(by_path[str(nested)]["logical_project"]["path"], str(repo))
        self.assertEqual(by_path[str(repo)]["logical_project"]["path"], str(repo))
        self.assertEqual(by_path[str(self.project_b)]["logical_project"]["path"], str(self.project_b))


if __name__ == "__main__":
    unittest.main()
