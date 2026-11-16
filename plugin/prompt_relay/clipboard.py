"""Clipboard backends.

- ``pbcopy``  macOS system clipboard via /usr/bin/pbcopy. The only
              macOS-specific code in the core; REQUIRES VALIDATION ON macOS.
- ``file:P``  MOCK backend: writes the exact UTF-8 bytes to file P. Used by
              tests and for cloud/Linux checks. It is not a clipboard.

Selection: $PROMPT_RELAY_CLIPBOARD, else ``pbcopy`` on macOS, else none.
The future SwiftUI app writes to NSPasteboard directly instead.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Mapping, Optional

ENV_CLIPBOARD = "PROMPT_RELAY_CLIPBOARD"
PBCOPY = "/usr/bin/pbcopy"
PBPASTE = "/usr/bin/pbpaste"


class ClipboardError(Exception):
    pass


def _utf8_env() -> dict:
    # pbcopy/pbpaste pick the text encoding from the locale; without a UTF-8
    # locale non-ASCII text is mangled.
    env = dict(os.environ)
    env["LANG"] = "en_US.UTF-8"
    env["LC_ALL"] = "en_US.UTF-8"
    return env


def _encode(text: str) -> bytes:
    try:
        return text.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise ClipboardError("text contains characters that are not valid Unicode (lone surrogates)") from exc


class PbcopyBackend:
    name = "pbcopy"
    is_mock = False

    def copy(self, text: str) -> None:
        if not os.path.exists(PBCOPY):
            raise ClipboardError(f"{PBCOPY} not found")
        try:
            subprocess.run([PBCOPY], input=_encode(text), env=_utf8_env(), check=True, timeout=10,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        except (OSError, subprocess.SubprocessError) as exc:
            raise ClipboardError(f"pbcopy failed: {type(exc).__name__}") from exc

    def read_back(self) -> bytes:
        try:
            proc = subprocess.run([PBPASTE, "-Prefer", "txt"], env=_utf8_env(), check=True, timeout=10,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except (OSError, subprocess.SubprocessError) as exc:
            raise ClipboardError(f"pbpaste failed: {type(exc).__name__}") from exc
        return proc.stdout


class FileBackend:
    name = "file"
    is_mock = True

    def __init__(self, path: Path) -> None:
        self.path = Path(path)

    def copy(self, text: str) -> None:
        data = _encode(text)
        tmp = self.path.with_name(self.path.name + ".tmp")
        try:
            fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "wb") as fh:
                fh.write(data)
            os.replace(str(tmp), str(self.path))
        except OSError as exc:
            raise ClipboardError(f"mock clipboard write failed: {type(exc).__name__}") from exc

    def read_back(self) -> bytes:
        return self.path.read_bytes()


def get_backend(env: Optional[Mapping[str, str]] = None, platform: Optional[str] = None):
    env = os.environ if env is None else env
    platform = sys.platform if platform is None else platform
    spec = env.get(ENV_CLIPBOARD, "")
    if spec.startswith("file:") and len(spec) > 5:
        return FileBackend(Path(spec[5:]).expanduser())
    if spec == "pbcopy" or (not spec and platform == "darwin"):
        return PbcopyBackend()
    if spec:
        raise ClipboardError(f"unknown {ENV_CLIPBOARD} value; use 'pbcopy' or 'file:/path'")
    raise ClipboardError(
        "no system clipboard backend on this platform (macOS pbcopy only). "
        "Use --stdout, or set PROMPT_RELAY_CLIPBOARD=file:/path for a mock."
    )
