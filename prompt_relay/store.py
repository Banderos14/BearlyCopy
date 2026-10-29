"""Append-only JSONL storage, one file per Claude Code session.

Layout under the data directory (see docs/DATA_MODEL.md):

    <root>/                 0700
      config.json           0600  enabled projects
      handler.log           0600  metadata-only diagnostics (never message text)
      events/               0700
        <session-key>.jsonl 0600  one JSON envelope per line

Concurrency: every append takes an exclusive ``flock`` on the session file,
checks for duplicates, writes the line with a single buffer and fsyncs.
Readers take a shared lock. A line cut short by a killed writer is skipped as
corrupt by readers, and the next writer starts on a fresh line.
"""

from __future__ import annotations

import errno
import fcntl
import hashlib
import json
import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

SCHEMA_VERSION = 1
LOCK_TIMEOUT_S = 3.0
# Identical payloads without a prompt_id are only treated as a redelivery when
# they arrive within this window; later identical payloads are kept.
DEDUP_WINDOW_S = 120.0
NO_SESSION_KEY = "_no-session"

_SAFE_KEY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


class StoreError(Exception):
    """Storage failure. ``code`` is a short, content-free identifier."""

    def __init__(self, code: str, detail: str = "") -> None:
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code


@dataclass
class ReadResult:
    records: List[Dict[str, Any]] = field(default_factory=list)
    corrupt_lines: int = 0
    unsupported_lines: int = 0


@dataclass
class SessionFile:
    key: str
    path: Path
    mtime: float


def session_key(session_id: Optional[str]) -> str:
    """Filename-safe key. Never lets a session id escape the events dir."""
    if not session_id:
        return NO_SESSION_KEY
    if _SAFE_KEY.match(session_id) and session_id != NO_SESSION_KEY:
        return session_id
    return "h-" + hashlib.sha256(session_id.encode("utf-8", "surrogatepass")).hexdigest()[:32]


def fingerprint(payload: Dict[str, Any]) -> str:
    canonical = json.dumps(payload, sort_keys=True, ensure_ascii=True, separators=(",", ":"))
    return "sha256:" + hashlib.sha256(canonical.encode("ascii")).hexdigest()


def encode_record(record: Dict[str, Any]) -> bytes:
    # ensure_ascii keeps the line pure ASCII: lossless for every JSON string,
    # including lone surrogates, and immune to locale/encoding issues.
    return json.dumps(record, ensure_ascii=True, separators=(",", ":")).encode("ascii") + b"\n"


def _lock(fd: int, mode: int, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(fd, mode | fcntl.LOCK_NB)
            return
        except OSError as exc:
            if exc.errno not in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EACCES):
                raise
            if time.monotonic() >= deadline:
                raise StoreError("lock_timeout")
            time.sleep(0.01)


def _write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        view = view[written:]


class Store:
    def __init__(self, root: Path, lock_timeout: float = LOCK_TIMEOUT_S) -> None:
        self.root = Path(root)
        self.events_dir = self.root / "events"
        self.lock_timeout = lock_timeout

    # -- setup -------------------------------------------------------------

    def ensure(self) -> None:
        try:
            for path in (self.root, self.events_dir):
                path.mkdir(mode=0o700, parents=True, exist_ok=True)
                os.chmod(path, 0o700)
        except OSError as exc:
            raise StoreError("storage_unavailable", type(exc).__name__) from exc

    def path_for(self, session_id: Optional[str]) -> Path:
        return self.events_dir / (session_key(session_id) + ".jsonl")

    # -- write -------------------------------------------------------------

    def append(self, record: Dict[str, Any]) -> str:
        """Append ``record``. Returns "stored" or "duplicate"."""
        self.ensure()
        path = self.path_for(record.get("session_id"))
        line = encode_record(record)
        try:
            fd = os.open(str(path), os.O_RDWR | os.O_APPEND | os.O_CREAT, 0o600)
        except OSError as exc:
            raise StoreError("storage_unavailable", type(exc).__name__) from exc
        try:
            _lock(fd, fcntl.LOCK_EX, self.lock_timeout)
            size = os.fstat(fd).st_size
            existing = os.pread(fd, size, 0) if size else b""
            if self._is_duplicate(existing, record):
                return "duplicate"
            if existing and not existing.endswith(b"\n"):
                line = b"\n" + line  # previous writer was cut off mid-line
            _write_all(fd, line)
            os.fsync(fd)
            return "stored"
        except StoreError:
            raise
        except OSError as exc:
            raise StoreError("write_failed", type(exc).__name__) from exc
        finally:
            os.close(fd)  # closing releases the lock

    @staticmethod
    def _is_duplicate(existing: bytes, record: Dict[str, Any]) -> bool:
        fp = record.get("fingerprint")
        if not fp or fp.encode("ascii") not in existing:
            return False
        has_prompt_id = bool(record.get("payload", {}).get("prompt_id"))
        now = record.get("received_at_epoch", time.time())
        for raw in existing.splitlines():
            if fp.encode("ascii") not in raw:
                continue
            try:
                old = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(old, dict) or old.get("fingerprint") != fp:
                continue
            if has_prompt_id:
                return True
            if abs(now - float(old.get("received_at_epoch", 0))) <= DEDUP_WINDOW_S:
                return True
        return False

    # -- read --------------------------------------------------------------

    def read_path(self, path: Path) -> ReadResult:
        result = ReadResult()
        try:
            fd = os.open(str(path), os.O_RDONLY)
        except FileNotFoundError:
            return result
        except OSError as exc:
            raise StoreError("read_failed", type(exc).__name__) from exc
        try:
            try:
                _lock(fd, fcntl.LOCK_SH, self.lock_timeout)
            except StoreError:
                pass  # read anyway; a partial trailing line is skipped below
            chunks = []
            while True:
                chunk = os.read(fd, 1 << 20)
                if not chunk:
                    break
                chunks.append(chunk)
        finally:
            os.close(fd)
        for raw in b"".join(chunks).splitlines():
            if not raw.strip():
                continue
            try:
                rec = json.loads(raw)
            except ValueError:
                result.corrupt_lines += 1
                continue
            if not isinstance(rec, dict) or not isinstance(rec.get("payload"), dict):
                result.corrupt_lines += 1
                continue
            if rec.get("schema") != SCHEMA_VERSION:
                result.unsupported_lines += 1
                continue
            result.records.append(rec)
        return result

    def read_session(self, session_id: Optional[str]) -> ReadResult:
        return self.read_path(self.path_for(session_id))

    def session_files(self) -> List[SessionFile]:
        try:
            entries = list(self.events_dir.iterdir())
        except FileNotFoundError:
            return []
        except OSError as exc:
            raise StoreError("read_failed", type(exc).__name__) from exc
        files = []
        for entry in entries:
            if entry.suffix != ".jsonl" or not entry.is_file():
                continue
            files.append(SessionFile(entry.stem, entry, entry.stat().st_mtime))
        files.sort(key=lambda f: f.mtime, reverse=True)
        return files

    # -- delete ------------------------------------------------------------

    def delete_path(self, path: Path) -> bool:
        try:
            path.unlink()
            return True
        except FileNotFoundError:
            return False

    def delete_all(self) -> int:
        count = 0
        for sf in self.session_files():
            if self.delete_path(sf.path):
                count += 1
        return count
