"""Shared test utilities: isolated data dirs, fixtures, subprocess runners.

Every test uses a fresh temporary PROMPT_RELAY_HOME and a temporary project
directory, so no test touches real user data, Claude settings or the
system clipboard (the clipboard is always the file MOCK backend).
"""

from __future__ import annotations

import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Dict, List, Optional

REPO = Path(__file__).resolve().parent.parent
FIXTURES = REPO / "tests" / "fixtures"
BIN = REPO / "bin" / "prompt-relay"

if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))


def load_fixture(name: str, project: str, **overrides: Any) -> Dict[str, Any]:
    data = json.loads((FIXTURES / name).read_text(encoding="utf-8"))
    data = json.loads(json.dumps(data).replace("__PROJECT_A__", project))
    data.update(overrides)
    return copy.deepcopy(data)


class IsolatedTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="prompt-relay-test-"))
        self.home = self.tmp / "data"
        self.project = str((self.tmp / "project-a").resolve())
        self.project_b = str((self.tmp / "project-b").resolve())
        os.makedirs(self.project)
        os.makedirs(self.project_b)
        self.clip = self.tmp / "clipboard.bin"
        self.env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(self.tmp / "home"),
            "PROMPT_RELAY_HOME": str(self.home),
            "PROMPT_RELAY_CLIPBOARD": "file:" + str(self.clip),
            "LANG": "C.UTF-8",
        }
        for p in (self.project, self.project_b):
            self.cli("enable", p)

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def fx(self, name: str, project: Optional[str] = None, **overrides: Any) -> Dict[str, Any]:
        return load_fixture(name, project or self.project, **overrides)

    def hook(self, payload: Any, env: Optional[Dict[str, str]] = None) -> subprocess.CompletedProcess:
        raw = payload if isinstance(payload, bytes) else json.dumps(payload, ensure_ascii=False).encode("utf-8")
        return subprocess.run([sys.executable, str(BIN), "hook"], input=raw, env=env or self.env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)

    def assertHookOk(self, proc: subprocess.CompletedProcess) -> None:
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, b"", "hook must never write to stdout")

    def cli(self, *args: str, env: Optional[Dict[str, str]] = None) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(BIN), *args], env=env or self.env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)

    def records(self, session_id: str) -> List[Dict[str, Any]]:
        from prompt_relay.store import Store
        return Store(self.home).read_session(session_id).records

    def log_outcomes(self) -> List[str]:
        path = self.home / "handler.log"
        if not path.exists():
            return []
        return [line.split()[-1] for line in path.read_text().splitlines()]
