"""The Python interpreter the plugin hook should use (``<data dir>/python-path``).

The plugin launcher (plugin/hooks/run-hook) reads this one-line file first,
so hooks run with an interpreter the user has already used successfully,
independent of Claude Desktop's minimal PATH. It is written only by the CLI
(``enable`` when no valid pin exists, or ``pin-python``), never by the hook.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Optional, Tuple

PIN_FILE = "python-path"
MIN_VERSION = (3, 9)

OK = "ok"
NOT_SET = "not_set"
MISSING = "missing"
NOT_EXECUTABLE = "not_executable"
INVALID = "invalid"


def pin_path(root: Path) -> Path:
    return Path(root) / PIN_FILE


def read_pin(root: Path) -> Tuple[Optional[str], str]:
    """Returns (path, state) without running the interpreter."""
    try:
        raw = pin_path(root).read_text(encoding="utf-8")
    except FileNotFoundError:
        return None, NOT_SET
    except (OSError, UnicodeDecodeError):
        return None, INVALID
    path = raw.splitlines()[0].strip() if raw.strip() else ""
    if not os.path.isabs(path):
        return (path or None), INVALID
    if not os.path.exists(path):
        return path, MISSING
    if os.path.isdir(path) or not os.access(path, os.X_OK):
        return path, NOT_EXECUTABLE
    return path, OK


def interpreter_version(path: str) -> Optional[Tuple[int, int, int]]:
    """Run ``path -I -S`` once to read its version (CLI only, never the hook)."""
    try:
        proc = subprocess.run([path, "-I", "-S", "-c", "import sys; print('%d %d %d' % sys.version_info[:3])"],
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    try:
        major, minor, micro = (int(x) for x in proc.stdout.decode("ascii").split())
    except ValueError:
        return None
    return (major, minor, micro) if proc.returncode == 0 else None


def write_pin(root: Path, python: str) -> Tuple[int, int, int]:
    """Validate ``python`` and pin it. Raises ValueError with a readable reason."""
    if not os.path.isabs(python):
        raise ValueError("the interpreter path must be absolute")
    if not os.path.isfile(python) or not os.access(python, os.X_OK):
        raise ValueError("not an executable file")
    version = interpreter_version(python)
    if version is None:
        raise ValueError("could not run it as Python")
    if version[:2] < MIN_VERSION:
        raise ValueError(f"Python {version[0]}.{version[1]} is too old; 3.9+ is required")
    root = Path(root)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    target = pin_path(root)
    tmp = target.with_name(f"{target.name}.{os.getpid()}.{os.urandom(4).hex()}.tmp")
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(python + "\n")
    os.replace(str(tmp), str(target))
    return version


def clear_pin(root: Path) -> bool:
    try:
        pin_path(root).unlink()
        return True
    except FileNotFoundError:
        return False
