"""Resolution of the local data directory.

The data directory is never inside a Git repository by default:
- macOS:  ~/Library/Application Support/PromptRelay
- other:  $XDG_DATA_HOME/prompt-relay  (default ~/.local/share/prompt-relay)
- override: $PROMPT_RELAY_HOME (used by tests and isolated manual checks)
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Mapping, Optional

ENV_HOME = "PROMPT_RELAY_HOME"


def data_dir(env: Optional[Mapping[str, str]] = None, platform: Optional[str] = None) -> Path:
    env = os.environ if env is None else env
    platform = sys.platform if platform is None else platform
    override = env.get(ENV_HOME)
    if override:
        return Path(override).expanduser()
    home = Path(env.get("HOME") or Path.home())
    if platform == "darwin":
        return home / "Library" / "Application Support" / "PromptRelay"
    xdg = env.get("XDG_DATA_HOME")
    base = Path(xdg) if xdg else home / ".local" / "share"
    return base / "prompt-relay"
