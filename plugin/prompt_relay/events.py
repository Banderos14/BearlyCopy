"""Normalized view of stored hook envelopes.

Only fields documented in the official Claude Code hooks reference are read
(see docs/HOOKS_RESEARCH.md). Every field is treated as optional and
type-checked; the raw payload stays untouched in the envelope.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, List, Optional

from prompt_relay import profiles as _profiles
from prompt_relay import signals as _signals

# Events the hook handler stores. Everything else is ignored, not persisted.
KIND_BY_EVENT = {
    "UserPromptSubmit": "prompt",
    "Stop": "stop",
    "StopFailure": "stop_failure",
    # Stored only in the reduced form of tools.reduce (ADR-013).
    "PostToolUse": "tool",
    "PostToolUseFailure": "tool",
    # Phase 12.1: the agent waits for the person (signals.py). Stored only
    # reduced (no question, plan or command text); never a turn or answer.
    "PreToolUse": "signal",
    "PermissionRequest": "signal",
    "Notification": "signal",
    "SessionEnd": "signal",
}


def _str(value: Any) -> Optional[str]:
    return value if isinstance(value, str) else None


def _nonempty_str(value: Any) -> Optional[str]:
    return value if isinstance(value, str) and value else None


def _list(value: Any) -> Optional[List[Any]]:
    return value if isinstance(value, list) else None


@dataclass
class Event:
    record_id: str
    received_at: str
    kind: str
    session_id: Optional[str]
    prompt_id: Optional[str]
    cwd: Optional[str]
    project_dir: Optional[str]
    transcript_path: Optional[str]
    # UserPromptSubmit.prompt, Stop.last_assistant_message, or for
    # StopFailure the rendered API error string (never Claude's answer).
    text: Optional[str]
    stop_hook_active: Optional[bool]
    background_tasks: Optional[List[Any]]
    session_crons: Optional[List[Any]]
    error: Optional[str]
    error_details: Optional[str]
    agent_id: Optional[str]
    received_at_epoch: Optional[float] = None
    # kind == "tool": the reduced record (tools.reduce), never a raw payload.
    tool: Optional[Dict[str, Any]] = None
    # UserPromptSubmit.session_title: a title Claude Code gave the session.
    session_title: Optional[str] = None
    source: Optional[Dict[str, Any]] = None
    native_turn_id: Optional[str] = None
    # Phase 12: the local agent profile (profiles.py), allowlisted fields only.
    profile: Optional[Dict[str, Any]] = None
    # Phase 12: the agent's own session id when the stored key was scoped.
    native_session_id: Optional[str] = None
    # Phase 12.1, kind == "signal": needs_input | resolved | session_end,
    # and for needs_input the kind of action (signals.KINDS).
    signal: Optional[str] = None
    signal_kind: Optional[str] = None
    tool_use_id: Optional[str] = None

    @property
    def tool_name(self) -> Optional[str]:
        return _str(self.tool.get("tool_name")) if self.tool else None

    @property
    def tool_path(self) -> Optional[str]:
        return _nonempty_str(self.tool.get("path")) if self.tool else None

    @property
    def work_tasks(self) -> List[Any]:
        """Background tasks that are work in flight. A ``monitor`` only watches
        (Claude Code arms one for an Artifact's live updates and it keeps
        running); it is reported apart and does not make work pending."""
        return [t for t in self.background_tasks or [] if not (isinstance(t, dict) and t.get("type") == "monitor")]

    @property
    def watchers(self) -> int:
        return len(self.background_tasks or []) - len(self.work_tasks)

    @property
    def has_background_tasks(self) -> bool:
        return bool(self.work_tasks)


def from_record(record: Dict[str, Any]) -> Optional[Event]:
    payload = record.get("payload")
    if not isinstance(payload, dict):
        return None
    kind = KIND_BY_EVENT.get(payload.get("hook_event_name"))  # type: ignore[arg-type]
    if kind is None:
        return None
    context = record.get("context") if isinstance(record.get("context"), dict) else {}
    cwd = _nonempty_str(payload.get("cwd"))
    project_dir = _nonempty_str(context.get("claude_project_dir")) or cwd
    if kind in ("tool", "signal") and payload.get("reduced") != 1:
        return None  # a raw tool or signal payload is never read, even if one was stored
    signal = payload.get("signal") if kind == "signal" else None
    if kind == "tool" and payload.get("signal") == _signals.ACTIVITY:
        kind = "signal"   # Phase 12.1: a non-evidence tool result after a wait
        signal = _signals.ACTIVITY
    if kind == "signal" and signal not in _signals.ALL_SIGNALS:
        return None
    if kind == "prompt":
        text = _str(payload.get("prompt"))
    elif kind in ("tool", "signal"):
        text = None
    else:
        text = _str(payload.get("last_assistant_message"))
    stop_hook_active = payload.get("stop_hook_active")
    return Event(
        record_id=str(record.get("record_id", "")),
        received_at=str(record.get("received_at", "")),
        kind=kind,
        # Phase 12: a scoped record (non-default Claude Code profile) is read
        # under its envelope key; the payload keeps the agent's own id.
        session_id=(_nonempty_str(record.get("session_id")) if _nonempty_str(record.get("native_session_id"))
                    else _nonempty_str(payload.get("session_id"))),
        prompt_id=_nonempty_str(payload.get("prompt_id")),
        cwd=cwd,
        project_dir=project_dir,
        transcript_path=_nonempty_str(payload.get("transcript_path")),
        text=text,
        stop_hook_active=stop_hook_active if isinstance(stop_hook_active, bool) else None,
        background_tasks=_list(payload.get("background_tasks")),
        session_crons=_list(payload.get("session_crons")),
        error=_nonempty_str(payload.get("error")),
        error_details=_str(payload.get("error_details")),
        agent_id=_nonempty_str(payload.get("agent_id")),
        received_at_epoch=_epoch(record.get("received_at_epoch")),
        source=payload.get("source") if isinstance(payload.get("source"), dict) else None,
        native_turn_id=_nonempty_str(payload.get("native_turn_id")),
        profile=_profiles.valid(record.get("agent_profile")),
        native_session_id=_nonempty_str(record.get("native_session_id")),
        signal=signal,
        signal_kind=payload.get("kind") if kind == "signal" and payload.get("kind") in _signals.KINDS else None,
        tool_use_id=_nonempty_str(payload.get("tool_use_id")),
        tool=dict(payload) if kind == "tool" else None,
        session_title=_nonempty_str(payload.get("session_title")) if kind == "prompt" else None,
    )


def _epoch(value: Any) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) if value == value and abs(value) < 1e11 else None  # reject NaN/absurd
