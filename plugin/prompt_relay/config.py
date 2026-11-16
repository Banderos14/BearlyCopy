"""Capture policy: which agent events the hook may store.

Three modes (Phase 16, ``prompt-relay capture``):

- ``selected`` (the default, and the only mode of schema 1): only projects
  the user enabled with ``prompt-relay enable`` (per-project opt-in);
- ``global``: every project a connected agent works in, except excluded
  projects and a few sensitive locations (home folder itself, ``/``,
  system folders, credential folders) — chosen explicitly by the user;
- ``paused``: nothing new is stored.

Exclusions always win. A missing config is ``selected`` with nothing
enabled; an unreadable, invalid or unknown config fails closed (nothing is
captured) — an error never widens capture. A config that uses ``global``,
``paused`` or exclusions is written as schema 2, which plugins older than
0.8.0 refuse (they capture nothing rather than ignore a pause).
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator, List, Optional, Tuple

CONFIG_SCHEMA = 1          # written while the policy is the pre-0.8 default (selected, no exclusions)
CONFIG_SCHEMA_POLICY = 2   # written once a mode or an exclusion is set
SUPPORTED_SCHEMAS = (CONFIG_SCHEMA, CONFIG_SCHEMA_POLICY)
MAX_RETENTION_DAYS = 36500

MODE_SELECTED = "selected"
MODE_GLOBAL = "global"
MODE_PAUSED = "paused"
MODES = (MODE_SELECTED, MODE_GLOBAL, MODE_PAUSED)


@dataclass
class Config:
    enabled_projects: List[str] = field(default_factory=list)
    error: Optional[str] = None  # set when the file exists but is unusable
    # Default age threshold for ``prompt-relay prune``; None = not set. There is
    # no automatic deletion: nothing prunes unless the user runs prune --yes.
    retention_days: Optional[int] = None
    # A bad retention value never disables capture; it is reported instead.
    retention_error: Optional[str] = None
    capture_mode: str = MODE_SELECTED
    excluded_projects: List[str] = field(default_factory=list)
    # The mode to return to on resume (global or selected).
    resume_mode: Optional[str] = None


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
    if not isinstance(data, dict) or data.get("schema") not in SUPPORTED_SCHEMAS:
        return Config(error="config_unsupported")
    projects = data.get("enabled_projects")
    if not isinstance(projects, list) or not all(isinstance(p, str) for p in projects):
        return Config(error="config_invalid_projects")
    cfg = Config(enabled_projects=list(projects))
    if data.get("schema") == CONFIG_SCHEMA_POLICY:
        mode = data.get("capture_mode")
        if mode not in MODES:
            return Config(error="config_invalid_capture_mode")
        excluded = data.get("excluded_projects", [])
        if not isinstance(excluded, list) or not all(isinstance(p, str) for p in excluded):
            return Config(error="config_invalid_excluded_projects")
        resume = data.get("resume_mode")
        if resume is not None and resume not in (MODE_SELECTED, MODE_GLOBAL):
            return Config(error="config_invalid_capture_mode")
        cfg.capture_mode, cfg.excluded_projects, cfg.resume_mode = mode, list(excluded), resume
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
    data: dict = {"schema": CONFIG_SCHEMA, "enabled_projects": sorted(set(config.enabled_projects)),
                  "retention_days": config.retention_days}
    if config.capture_mode != MODE_SELECTED or config.excluded_projects or config.resume_mode:
        if config.capture_mode not in MODES:
            raise ValueError("unknown capture mode")
        data["schema"] = CONFIG_SCHEMA_POLICY
        data["capture_mode"] = config.capture_mode
        data["excluded_projects"] = sorted(set(config.excluded_projects))
        data["resume_mode"] = config.resume_mode
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


# -- Phase 16: the capture decision -------------------------------------------

def _home() -> str:
    return os.path.realpath(os.path.expanduser("~"))


# Never captured automatically in global mode (an explicit ``enable`` of a
# project inside them still works, except for / and the home folder itself).
_SYSTEM_ROOTS = ("/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/cores", "/dev", "/Volumes/Recovery")
_HOME_SENSITIVE = ("Library", ".ssh", ".gnupg", ".aws", ".kube", ".docker", ".password-store", ".config/gcloud")


def _inside(path: str, root: str) -> bool:
    root = root.rstrip(os.sep) or os.sep
    return path == root or path.startswith(root + os.sep)


def too_broad(path: str) -> bool:
    """Locations global capture never accepts as a project: ``/``, the home
    folder itself, system folders and credential folders."""
    home = _home()
    if path in (os.sep, home):
        return True
    if any(_inside(path, r) for r in _SYSTEM_ROOTS):
        return True
    return any(_inside(path, os.path.join(home, h)) for h in _HOME_SENSITIVE)


def is_excluded(config: Config, project_dir: str) -> bool:
    candidate = normalize_project_path(project_dir)
    for excluded in config.excluded_projects:
        if _inside(candidate, excluded):
            return True
    return _same_dir_match(config.excluded_projects, candidate)


def capture_decision(config: Config, project_dir: Optional[str]) -> Tuple[bool, str]:
    """``(store?, outcome)`` for one hook event. Fails closed on every doubt;
    outcomes are content-free labels for handler.log."""
    if config.error:
        return False, config.error
    if config.capture_mode == MODE_PAUSED:
        return False, "capture_paused"
    if not isinstance(project_dir, str) or not project_dir or not os.path.isabs(project_dir):
        return False, "no_project_dir"
    if is_excluded(config, project_dir):
        return False, "project_excluded"
    if is_enabled(config, project_dir):
        return True, "ok"
    if config.capture_mode == MODE_GLOBAL:
        if too_broad(normalize_project_path(project_dir)):
            return False, "outside_capture_scope"
        return True, "ok"
    return False, "project_not_enabled"
