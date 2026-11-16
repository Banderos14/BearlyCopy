"""Minimal, read-only Git metadata for Copy Context.

Collected at export time, never inside the hook. Hardening against side
effects and repository-controlled command execution:
- GIT_OPTIONAL_LOCKS=0: ``git status`` does not refresh/write the index;
- core.fsmonitor=false: a repo-configured fsmonitor command is not run;
- maintenance.auto=false, gc.auto=0: no auto-maintenance child can start.
  Today only write commands (commit, fetch, merge, am, rebase) trigger it,
  and since git 2.47 it detaches and keeps writing .git/objects in the
  background; this pins the read-only guarantee for future git versions;
- no pager, no terminal prompts, fixed timeout, no shell.
"""

from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass, field
from typing import List, Optional

GIT_TIMEOUT_S = 5.0
MAX_CHANGED_FILES = 100


@dataclass
class GitInfo:
    available: bool
    reason: str = ""
    branch: Optional[str] = None
    head: Optional[str] = None
    changed_files: List[str] = field(default_factory=list)
    changed_files_truncated: bool = False


def _git(path: str, *args: str) -> Optional[str]:
    env = dict(os.environ)
    env.update({"GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat", "LC_ALL": "C"})
    cmd = ["git", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
           "-c", "maintenance.auto=false", "-c", "gc.auto=0", "-C", path, *args]
    try:
        proc = subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=GIT_TIMEOUT_S, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.decode("utf-8", "replace")


def collect(path: Optional[str]) -> GitInfo:
    if not path or not os.path.isdir(path):
        return GitInfo(False, "project directory is not available on this machine")
    inside = _git(path, "rev-parse", "--is-inside-work-tree")
    if inside is None or inside.strip() != "true":
        return GitInfo(False, "not a Git work tree (or git is not installed)")
    info = GitInfo(True)
    branch = _git(path, "rev-parse", "--abbrev-ref", "HEAD")
    info.branch = branch.strip() if branch else None
    if info.branch == "HEAD":
        info.branch = "(detached HEAD)"
    head = _git(path, "rev-parse", "--verify", "-q", "HEAD")
    info.head = head.strip() if head else None  # None on an unborn branch
    status = _git(path, "status", "--porcelain=v1", "--untracked-files=normal")
    if status is not None:
        lines = [ln for ln in status.splitlines() if ln.strip()]
        info.changed_files = lines[:MAX_CHANGED_FILES]
        info.changed_files_truncated = len(lines) > MAX_CHANGED_FILES
    return info
