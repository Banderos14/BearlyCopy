"""Explicit per-project capture enablement.

Capture is opt-in: the hook stores nothing unless the event's project
directory is inside a project the user enabled with ``prompt-relay enable``.
A missing or unreadable config fails closed (nothing is captured).
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator, List, Optional

CONFIG_SCHEMA = 1
MAX_RETENTION_DAYS = 36500


@dataclass
class Config:
    enabled_projects: List[str] = field(default_factory=list)
    error: Optional[str] = None  # set when the file exists but is unusable
    # Default age threshold for ``prompt-relay prune``; None = not set. There is
    # no automatic deletion: nothing prunes unless the user runs prune --yes.
    retention_days: Optional[int] = None
    # A bad retention value never disables capture; it is reported instead.
    retention_error: Optional[str] = None


def valid_retention_days(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and 1 <= value <= MAX_RETENTION_DAYS


def normalize_project_path(path: str) -> str:
    return os.path.realpath(os.path.expanduser(path))


def config_path(root: Path) -> Path:
    return Path(root) / "config.json"


def load(root: Path) -> Config:
    path = config_path(root)
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        return Config()
    except OSError as exc:
        return Config(error="config_unreadable:" + type(exc).__name__)
    try:
        data = json.loads(raw)
    except ValueError:
        return Config(error="config_invalid_json")
    if not isinstance(data, dict) or data.get("schema") != CONFIG_SCHEMA:
        return Config(error="config_unsupported")
    projects = data.get("enabled_projects")
    if not isinstance(projects, list) or not all(isinstance(p, str) for p in projects):
        return Config(error="config_invalid_projects")
    cfg = Config(enabled_projects=list(projects))
    retention = data.get("retention_days")
    if retention is not None:
        if valid_retention_days(retention):
            cfg.retention_days = retention
        else:
            cfg.retention_error = "config_invalid_retention_days"
    return cfg


@contextlib.contextmanager
def locked(root: Path) -> Iterator[None]:
    """Serialize read-modify-write of config.json between CLI processes.
    The hook only reads the config (atomically replaced), so it never waits."""
    root = Path(root)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(str(root / "config.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def save(root: Path, config: Config) -> None:
    root = Path(root)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = config_path(root)
    tmp = path.with_name(f"{path.name}.{os.getpid()}.{os.urandom(4).hex()}.tmp")
    data = {"schema": CONFIG_SCHEMA, "enabled_projects": sorted(set(config.enabled_projects)),
            "retention_days": config.retention_days}
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(str(tmp), str(path))


def is_enabled(config: Config, project_dir: Optional[str]) -> bool:
    if config.error or not project_dir:
        return False
    candidate = normalize_project_path(project_dir)
    for enabled in config.enabled_projects:
        if candidate == enabled or candidate.startswith(enabled.rstrip(os.sep) + os.sep):
            return True
    return _same_dir_match(config.enabled_projects, candidate)


def _same_dir_match(enabled_projects: List[str], candidate: str) -> bool:
    """Fallback when the path strings differ but name the same directory:
    case-insensitive APFS (``~/Code/App`` vs ``~/code/app``), bind mounts.
    Compares (st_dev, st_ino) of the candidate and its parents."""
    ids = set()
    for enabled in enabled_projects:
        try:
            st = os.stat(enabled)
        except OSError:
            continue
        ids.add((st.st_dev, st.st_ino))
    if not ids:
        return False
    path = candidate
    while True:
        try:
            st = os.stat(path)
        except OSError:
            st = None
        if st is not None and (st.st_dev, st.st_ino) in ids:
            return True
        parent = os.path.dirname(path)
        if parent == path:
            return False
        path = parent
