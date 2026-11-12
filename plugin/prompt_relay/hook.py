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
from prompt_relay import profiles as _profiles
from prompt_relay.events import KIND_BY_EVENT
from prompt_relay.adapters import normalize, PROVIDERS, HOSTS
from prompt_relay.paths import data_dir
from prompt_relay import signals as _signals
from prompt_relay.store import SCHEMA_VERSION, Store, StoreError, fingerprint, session_key
from prompt_relay.tools import TOOL_EVENTS, reduce as reduce_tool_event

MAX_STDIN_BYTES = 64 * 1024 * 1024
LOG_MAX_BYTES = 256 * 1024
ENV_DISABLE = "PROMPT_RELAY_DISABLE"
ENV_VIA = "PROMPT_RELAY_VIA"  # set to "plugin" by plugin/hooks/run-hook
# Expected outcomes: logged, never written to stderr.
QUIET_OUTCOMES = ("stored", "duplicate", "ignored_event", "project_not_enabled", "disabled", "capture_paused",
                  "project_excluded", "outside_capture_scope", "no_project_dir")


def _utc_iso(epoch: float) -> str:
    return _dt.datetime.fromtimestamp(epoch, tz=_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def build_record(payload: Dict[str, Any], env: Mapping[str, str], now: float) -> Dict[str, Any]:
    context: Dict[str, Any] = {}
    if env.get("PROMPT_RELAY_PROVIDER", "claude_code") == "claude_code" and env.get("CLAUDE_PROJECT_DIR"):
        context["claude_project_dir"] = env["CLAUDE_PROJECT_DIR"]
    if env.get("PROMPT_RELAY_PROVIDER", "claude_code") == "claude_code" and env.get("CLAUDE_CODE_REMOTE"):
        context["claude_code_remote"] = env["CLAUDE_CODE_REMOTE"]
    session_id = payload.get("session_id")
    session_id = session_id if isinstance(session_id, str) and session_id else None
    record: Dict[str, Any] = {
        "schema": SCHEMA_VERSION,
        "record_id": os.urandom(16).hex(),
        "received_at": _utc_iso(now),
        "received_at_epoch": now,
        "hook_event_name": payload.get("hook_event_name"),
        "session_id": session_id,
        "fingerprint": fingerprint(payload),
        "context": context,
        "payload": payload,
    }
    # Phase 12: the local profile (the agent's config home, never an account)
    # goes into the envelope; the payload stays exactly as received. A
    # non-default Claude Code home scopes the stored session key, so equal
    # session ids from two homes never share a history file; the default home
    # keeps the plain key (existing history is unchanged).
    provider = env.get("PROMPT_RELAY_PROVIDER", "claude_code")
    profile = _profiles.from_env(provider, env)
    if profile is not None:
        record["agent_profile"] = profile
        if provider == "claude_code":
            scoped = _profiles.scoped_session_id(session_id, profile)
            if scoped != session_id:
                record["session_id"] = scoped
                record["native_session_id"] = session_id
    return record


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
    # The project the agent works in: Claude Code's own CLAUDE_PROJECT_DIR,
    # else the event's cwd. Phase 16: the capture policy decides (selected
    # projects, global with exclusions, or paused); every doubt fails closed.
    project_dir = (env.get("CLAUDE_PROJECT_DIR") if env.get("PROMPT_RELAY_PROVIDER", "claude_code") == "claude_code" else None) or payload.get("cwd")
    allowed, why = _config.capture_decision(cfg, project_dir if isinstance(project_dir, str) else None)
    if not allowed:
        return label, why

    payload = normalize(payload, env)
    if payload is None:
        # Phase 12.1: a PreToolUse of another tool or a Notification type that
        # is not a waiting signal is not stored and not an error.
        if KIND_BY_EVENT.get(label) == "signal":
            return label, "ignored_event"
        return label, "unsupported_source_event"
    record = build_record(payload, env, time.time() if now is None else now)
    signal = payload.get("signal") if payload.get("reduced") == 1 else None
    store = Store(root)
    marker = _waiting_marker(root, record.get("session_id"))
    if signal in (_signals.ACTIVITY, _signals.RESOLVED, _signals.SESSION_END):
        # Phase 12.1: these only end a wait for the person. Without an open
        # wait they are not stored (no extra records, no empty sessions).
        if marker is None or not marker.exists() or not store.path_for(record.get("session_id")).exists():
            _clear_marker(marker)
            return label, "ignored_event"
    try:
        outcome = store.append(record)
    except StoreError as exc:
        return label, exc.code
    if outcome == "stored":
        if signal == _signals.NEEDS_INPUT:
            _set_marker(marker)
        else:
            _clear_marker(marker)   # any confirmed activity ends a wait
    return label, outcome


def _waiting_marker(root: Path, session_id: Any) -> Optional[Path]:
    """``<data>/waiting/<session key>``: an empty file while a wait is open.
    Only gates ACTIVITY records; the event log stays the source of truth."""
    if not isinstance(session_id, str) or not session_id:
        return None
    folder = root / "waiting"
    if folder.is_symlink():
        return None
    return folder / session_key(session_id)


def _set_marker(marker: Optional[Path]) -> None:
    if marker is None:
        return
    try:
        marker.parent.mkdir(mode=0o700, exist_ok=True)
        if marker.parent.is_symlink():
            return
        fd = os.open(str(marker), os.O_WRONLY | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
        os.close(fd)
    except OSError:
        pass


def _clear_marker(marker: Optional[Path]) -> None:
    if marker is None:
        return
    try:
        if not marker.is_symlink():
            marker.unlink()
    except OSError:
        pass


def via_label(env: Mapping[str, str]) -> str:
    """How the handler was started: "plugin" (the plugin launcher) or "direct"
    (a settings-based hook, bin/prompt-relay hook, or a test)."""
    return "plugin" if env.get(ENV_VIA) == "plugin" else "direct"


def _log(root: Path, event: str, outcome: str, via: str = "direct", env: Optional[Mapping[str, str]] = None) -> None:
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
            env = {} if env is None else env
            provider = env.get("PROMPT_RELAY_PROVIDER", "claude_code")
            provider = provider if provider in PROVIDERS else "unknown"
            host = env.get("PROMPT_RELAY_HOST", "unknown")
            host = host if host in HOSTS else "unknown"
            event = event if event in KIND_BY_EVENT else "-"
            source = f" provider={provider} host={host}" if "PROMPT_RELAY_PROVIDER" in env else ""
            os.write(fd, f"{_utc_iso(time.time())} {event} via={via}{source} {outcome}\n".encode("ascii", "replace"))
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
    if outcome not in QUIET_OUTCOMES:
        try:
            sys.stderr.write(f"prompt-relay: {outcome}\n")
        except Exception:
            pass
    if root is not None and outcome != "disabled":
        _log(root, event, outcome, via_label(env), env)
    return 0
