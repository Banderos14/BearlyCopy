"""Logical project of a captured folder (Phase 9.3, Project Intelligence).

Agents report the folder a command ran in (``cwd``). Xcode's Codex, for
example, runs in ``<repo>/macos``, so the last path component is not the
project. This module names the logical project a folder belongs to, using
only local metadata:

1. the user's own binding: the most specific enabled project containing the
   folder, unless a Git work tree lies strictly inside that enabled folder
   (a broad enabled folder such as ``~/Projects`` never merges repositories);
2. a verified Git work-tree root: the nearest ancestor with a ``.git``
   directory holding ``HEAD``, or a ``.git`` file starting with ``gitdir:``
   (a linked worktree);
3. a known workspace or package root marker in the folder itself;
4. the folder itself.

Never used by the hook. It runs no git or other command and reads no file
contents except the first bytes of a ``.git`` file; it only stats paths.
Paths are canonicalized with ``realpath`` so one directory has one id.
The raw ``cwd`` stays in the session record and its ``project``/``cwds``
fields; nothing is rewritten.
"""

from __future__ import annotations

import os
from typing import Dict, List, Optional

BASIS_ENABLED = "enabled_project"
BASIS_GIT = "git_root"
BASIS_WORKSPACE = "workspace"
BASIS_DIRECTORY = "directory"

WORKSPACE_MARKERS = ("Package.swift", "package.json", "pyproject.toml", "Cargo.toml", "go.mod")
WORKSPACE_SUFFIXES = (".xcodeproj", ".xcworkspace")
_MAX_DEPTH = 64


def _canonical(path: str) -> str:
    return os.path.realpath(os.path.expanduser(path))


def _inside(path: str, root: str) -> bool:
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def _is_git_root(folder: str) -> bool:
    dot_git = os.path.join(folder, ".git")
    try:
        if os.path.isdir(dot_git) and not os.path.islink(dot_git):
            return os.path.isfile(os.path.join(dot_git, "HEAD"))
        if os.path.isfile(dot_git) and not os.path.islink(dot_git):
            with open(dot_git, "rb") as fh:
                return fh.read(8) == b"gitdir: "
    except OSError:
        return False
    return False


def git_root(folder: str) -> Optional[str]:
    current = folder
    for _ in range(_MAX_DEPTH):
        if _is_git_root(current):
            return current
        parent = os.path.dirname(current)
        if parent == current:
            return None
        current = parent
    return None


def _is_workspace(folder: str) -> bool:
    try:
        names = os.listdir(folder)
    except OSError:
        return False
    return any(n in WORKSPACE_MARKERS or n.endswith(WORKSPACE_SUFFIXES) for n in names)


class Resolver:
    """Resolves folders to logical projects; caches per instance (one CLI call)."""

    def __init__(self, enabled_projects: List[str]) -> None:
        self._enabled = []
        for p in enabled_projects:
            try:
                self._enabled.append(_canonical(p))
            except (OSError, ValueError):
                continue
        self._cache: Dict[str, Optional[Dict[str, str]]] = {}

    def resolve(self, path: Optional[str]) -> Optional[Dict[str, str]]:
        if not path:
            return None
        if path in self._cache:
            return self._cache[path]
        result = self._resolve(path)
        self._cache[path] = result
        return result

    def _resolve(self, path: str) -> Dict[str, str]:
        try:
            real = _canonical(path)
        except (OSError, ValueError):
            real = path
        enabled = max((e for e in self._enabled if _inside(real, e)), key=len, default=None)
        repo = git_root(real) if os.path.isdir(real) else None
        if enabled is not None and not (repo is not None and repo != enabled and _inside(repo, enabled)):
            return self._ref(enabled, BASIS_ENABLED)
        if repo is not None:
            return self._ref(repo, BASIS_GIT)
        if os.path.isdir(real) and _is_workspace(real):
            return self._ref(real, BASIS_WORKSPACE)
        return self._ref(real, BASIS_DIRECTORY)

    @staticmethod
    def _ref(path: str, basis: str) -> Dict[str, str]:
        name = os.path.basename(path.rstrip(os.sep)) or path
        return {"path": path, "name": name, "basis": basis}
