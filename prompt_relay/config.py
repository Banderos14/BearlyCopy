"""Explicit per-project capture enablement.

Capture is opt-in: the hook stores nothing unless the event's project
directory is inside a project the user enabled with ``prompt-relay enable``.
A missing or unreadable config fails closed (nothing is captured).
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional

CONFIG_SCHEMA = 1


@dataclass
class Config:
    enabled_projects: List[str] = field(default_factory=list)
    error: Optional[str] = None  # set when the file exists but is unusable


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
    return Config(enabled_projects=list(projects))


def save(root: Path, config: Config) -> None:
    root = Path(root)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = config_path(root)
    tmp = path.with_name(path.name + ".tmp")
    data = {"schema": CONFIG_SCHEMA, "enabled_projects": sorted(set(config.enabled_projects))}
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
    return False
