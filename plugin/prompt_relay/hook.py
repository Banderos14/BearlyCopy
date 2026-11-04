"""Claude Code command-hook handler.

Contract with Claude Code (docs/ARCHITECTURE.md, "Hook handler contract"):
- reads one JSON object from stdin; field order is irrelevant;
- never writes to stdout (stdout of UserPromptSubmit would become context
  for Claude, and JSON on stdout could be read as a decision);
- always exits 0, so a storage failure never blocks or steers Claude;
- performs no network I/O and never executes text from the payload;
- writes diagnostics to handler.log as metadata only (no message text).
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Tuple

from prompt_relay import config as _config
from prompt_relay.events import KIND_BY_EVENT
from prompt_relay.adapters import normalize
from prompt_relay.paths import data_dir
from prompt_relay.store import SCHEMA_VERSION, Store, StoreError, fingerprint
from prompt_relay.tools import TOOL_EVENTS, reduce as reduce_tool_event

MAX_STDIN_BYTES = 64 * 1024 * 1024
LOG_MAX_BYTES = 256 * 1024
ENV_DISABLE = "PROMPT_RELAY_DISABLE"
ENV_VIA = "PROMPT_RELAY_VIA"  # set to "plugin" by plugin/hooks/run-hook


def _utc_iso(epoch: float) -> str:
    return _dt.datetime.fromtimestamp(epoch, tz=_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def build_record(payload: Dict[str, Any], env: Mapping[str, str], now: float) -> Dict[str, Any]:
    context: Dict[str, Any] = {}
    if env.get("PROMPT_RELAY_PROVIDER", "claude_code") == "claude_code" and env.get("CLAUDE_PROJECT_DIR"):
        context["claude_project_dir"] = env["CLAUDE_PROJECT_DIR"]
    if env.get("PROMPT_RELAY_PROVIDER", "claude_code") == "claude_code" and env.get("CLAUDE_CODE_REMOTE"):
        context["claude_code_remote"] = env["CLAUDE_CODE_REMOTE"]
    session_id = payload.get("session_id")
    return {
        "schema": SCHEMA_VERSION,
        "record_id": os.urandom(16).hex(),
        "received_at": _utc_iso(now),
        "received_at_epoch": now,
        "hook_event_name": payload.get("hook_event_name"),
        "session_id": session_id if isinstance(session_id, str) and session_id else None,
        "fingerprint": fingerprint(payload),
        "context": context,
        "payload": payload,
    }


def _event_label(payload: Dict[str, Any]) -> str:
    name = payload.get("hook_event_name")
    if not isinstance(name, str):
        return "-"
    return "".join(c for c in name if c.isalnum())[:40] or "-"


def process(raw: bytes, env: Mapping[str, str], now: Optional[float] = None, root: Optional[Path] = None) -> Tuple[str, str]:
    """Handle one hook invocation.

    Returns ``(event_label, outcome)``; both are content-free and safe to log.
    """
    if env.get(ENV_DISABLE) == "1":
        return "-", "disabled"
    if len(raw) > MAX_STDIN_BYTES:
        return "-", "payload_too_large"
    try:
        payload = json.loads(raw.decode("utf-8"))
    except UnicodeDecodeError:
        return "-", "invalid_utf8"
    except ValueError:
        return "-", "invalid_json"
    if not isinstance(payload, dict):
        return "-", "invalid_payload"
    label = _event_label(payload)
    if payload.get("hook_event_name") not in KIND_BY_EVENT:
        return label, "ignored_event"

    root = data_dir(env) if root is None else root
    cfg = _config.load(root)
    if cfg.error:
        return label, cfg.error
    project_dir = (env.get("CLAUDE_PROJECT_DIR") if env.get("PROMPT_RELAY_PROVIDER", "claude_code") == "claude_code" else None) or payload.get("cwd")
    if not isinstance(project_dir, str) or not _config.is_enabled(cfg, project_dir):
        return label, "project_not_enabled"

    payload = normalize(payload, env)
    if payload is None:
        return label, "unsupported_source_event"
    record = build_record(payload, env, time.time() if now is None else now)
    try:
        return label, Store(root).append(record)
    except StoreError as exc:
        return label, exc.code


def via_label(env: Mapping[str, str]) -> str:
    """How the handler was started: "plugin" (the plugin launcher) or "direct"
    (a settings-based hook, bin/prompt-relay hook, or a test)."""
    return "plugin" if env.get(ENV_VIA) == "plugin" else "direct"


def _log(root: Path, event: str, outcome: str, via: str = "direct") -> None:
    try:
        if not root.is_dir():
            return
        path = root / "handler.log"
        try:
            if path.stat().st_size > LOG_MAX_BYTES:
                os.replace(str(path), str(path) + ".1")
        except FileNotFoundError:
            pass
        fd = os.open(str(path), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            # Format: <utc> <event> via=<plugin|direct> <outcome>. The outcome
            # stays the last token; older lines have no via= field.
            os.write(fd, f"{_utc_iso(time.time())} {event} via={via} {outcome}\n".encode("ascii", "replace"))
        finally:
            os.close(fd)
    except Exception:
        pass


def main(stdin: Any = None, env: Optional[Mapping[str, str]] = None) -> int:
    env = os.environ if env is None else env
    outcome = "internal_error"
    event = "-"
    root: Optional[Path] = None
    try:
        stream = stdin if stdin is not None else sys.stdin.buffer
        raw = stream.read(MAX_STDIN_BYTES + 1)
        root = data_dir(env)
        event, outcome = process(raw, env, root=root)
    except Exception as exc:  # never let a failure reach Claude Code
        outcome = "internal_error:" + type(exc).__name__
    if outcome not in ("stored", "duplicate", "ignored_event", "project_not_enabled", "disabled"):
        try:
            sys.stderr.write(f"prompt-relay: {outcome}\n")
        except Exception:
            pass
    if root is not None and outcome != "disabled":
        _log(root, event, outcome, via_label(env))
    return 0
