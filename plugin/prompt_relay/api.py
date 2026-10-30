"""Machine-readable JSON API (version 1) for the CLI's ``--json`` mode.

Contract: docs/JSON_API.md and docs/api/api-v1.schema.json. Golden files
in tests/golden pin the exact output.

Every ``--json`` invocation writes exactly one JSON document and a newline
to stdout, and nothing to stderr:

    {"api_version": 1, "command": "...", "ok": true|false,
     "data": {...}|null, "error": {"code", "message"}|null,
     "warnings": [{"code", "message"}]}

Output is pure ASCII (``\\u`` escapes), so it does not depend on the locale,
and every string, including lone surrogates, survives exactly.
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import re
import time
from typing import Any, Dict, List, Optional

from prompt_relay import correlation as c
from prompt_relay import export, origin, tools
from prompt_relay.events import Event
from prompt_relay.history import Session, display_title, session_title  # noqa: F401 (display_title re-exported)
from prompt_relay.retention import ACTIVE_GRACE_S
from prompt_relay.sensitive import Finding

API_VERSION = 1
PREVIEW_CHARS = 200

# Error codes (docs/JSON_API.md §5). New codes may be added in version 1.
USAGE_ERROR = "usage_error"
NOT_FOUND = "not_found"
AMBIGUOUS_SELECTION = "ambiguous_selection"
NO_FINAL_RESPONSE = "no_final_response"
CONFIRMATION_REQUIRED = "confirmation_required"
ACTIVE_SESSION = "active_session"
UNSAFE_PATH = "unsafe_path"
STORAGE_ERROR = "storage_error"
CONFIG_ERROR = "config_error"
INTERNAL_ERROR = "internal_error"


class ApiError(Exception):
    def __init__(self, code: str, message: str, data: Optional[Dict[str, Any]] = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data


def warning(code: str, message: str) -> Dict[str, str]:
    return {"code": code, "message": message}


def envelope(command: str, data: Optional[Dict[str, Any]] = None, warnings: Optional[List[Dict[str, str]]] = None,
             error: Optional[ApiError] = None) -> Dict[str, Any]:
    return {
        "api_version": API_VERSION,
        "command": command,
        "ok": error is None,
        "data": error.data if error is not None else data,
        "error": None if error is None else {"code": error.code, "message": error.message},
        "warnings": list(warnings or []),
    }


def dumps(doc: Dict[str, Any]) -> bytes:
    return (json.dumps(doc, ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n").encode("ascii")


def iso(epoch: Optional[float]) -> Optional[str]:
    if epoch is None:
        return None
    return _dt.datetime.fromtimestamp(epoch, tz=_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


# -- building blocks ---------------------------------------------------------

def project_ref(path: Optional[str]) -> Dict[str, Any]:
    name = os.path.basename(path.rstrip(os.sep)) if path else None
    return {"path": path, "name": name or None}


def session_running(s: Session, now: Optional[float] = None) -> bool:
    """A request without a Stop yet, with activity in the last 30 minutes
    (ADR-007's grace). Background tasks at a Stop do not count: Claude
    stopped."""
    if not s.turns or not s.turns[-1].trailing:
        return False
    last = s.last_event_epoch
    return last is not None and (time.time() if now is None else now) - last < ACTIVE_GRACE_S


def session_summary(s: Session) -> Dict[str, Any]:
    last = s.turns[-1] if s.turns else None
    claude_title = next((ev.session_title for ev in reversed(s.events) if ev.session_title), None)
    return {
        "title": session_title(s),
        "claude_code_title": claude_title,
        "answered_count": sum(1 for t in s.turns if t.final_response is not None),
        "running": session_running(s),
        "session_id": s.session_id,
        "session_key": s.key,
        "project": project_ref(s.project_dir),
        "first_event_at": s.first_at or None,
        "last_event_at": s.last_at or None,
        "event_count": len(s.events),
        "turn_count": len(s.turns),
        "cwds": list(s.cwds),
        "last_turn": None if last is None else {"index": last.index, "status": last.status},
        "integrity": {
            "corrupt_lines": s.corrupt_lines,
            "unsupported_lines": s.unsupported_lines,
            "foreign_lines": s.foreign_lines,
        },
    }


def _text_ref(ev: Event, full: bool) -> Dict[str, Any]:
    text = ev.text if ev.text is not None else ""
    ref = {
        "preview": text[:PREVIEW_CHARS],
        "truncated": len(text) > PREVIEW_CHARS,
        "char_count": len(text),
        "utf8_bytes": len(text.encode("utf-8", "surrogatepass")),
        "prompt_id": ev.prompt_id,
        "received_at": ev.received_at or None,
    }
    if full:
        ref["text"] = text
    return ref


def turn_object(t: c.Turn, full: bool = False, turns: Optional[List[c.Turn]] = None) -> Dict[str, Any]:
    """``turns``: the session's turns, needed to point an automated turn at
    the latest earlier request from the user (Phase 5.11)."""
    final = t.final_response
    last = t.responses[-1] if t.responses else None
    last_stop = t.last_stop
    error = None
    if last is not None and last.kind == "stop_failure":
        error = {"type": last.error, "details": last.error_details, "message": last.text}
    background = None
    if last_stop is not None:
        reported = last_stop.background_tasks is not None
        background = {"reported": reported, "count": len(last_stop.work_tasks) if reported else None,
                      "watchers": last_stop.watchers if reported else None}
    return {
        "index": t.index,
        "status": t.status,
        "link": t.link,
        # The turn's own prompt. A turn holds a prompt only when it is that
        # prompt's turn; how firmly the response belongs to it is ``link``.
        # Ambiguous responses get a turn without a prompt (candidates counted).
        "request": _text_ref(t.prompt, full) if t.prompt is not None else None,
        # user | user_pasted | automated | unknown (origin.py); null without a request.
        "request_origin": origin.classify(t.prompt.text) if t.prompt is not None else None,
        "earlier_user_request": _earlier(t, turns, full),
        "final_response": _text_ref(final, full) if final is not None else None,
        "response_event_count": len(t.responses),
        "candidate_request_turns": list(t.candidate_turns),
        "background_tasks": background,
        "error": error,
        "notification_count": len(t.notifications),
        "observed": tools.observed_counts(t),
        **({"observed_detail": tools.observed_detail(t)} if full else {}),
    }


def _earlier(t: c.Turn, turns: Optional[List[c.Turn]], full: bool) -> Optional[Dict[str, Any]]:
    if turns is None or t.prompt is None or origin.classify(t.prompt.text) != origin.AUTOMATED:
        return None
    found = origin.earlier_user_prompt(turns, t.index)
    return None if found is None else {"turn": found[0], **_text_ref(found[1], full)}


def turn_warnings(sess: Session, t: c.Turn, selection_warnings: List[str]) -> List[Dict[str, str]]:
    out = []
    for w in selection_warnings:
        out.append(warning("newer_prompts_awaiting_response", w))
    if t.final_response is not None:
        if t.status == c.STATUS_API_ERROR:
            out.append(warning("api_error_after_stop", export.API_ERROR_AFTER_STOP))
        elif t.final_response.has_background_tasks:
            out.append(warning("background_tasks_pending",
                               "background tasks were still running when Claude stopped; the work may not be finished"))
    out += integrity_warnings(sess)
    return out


def integrity_warnings(sess: Session) -> List[Dict[str, str]]:
    out = []
    if sess.corrupt_lines:
        out.append(warning("corrupt_lines_skipped", f"{sess.corrupt_lines} unreadable line(s) skipped"))
    if sess.unsupported_lines:
        out.append(warning("unsupported_lines_skipped", f"{sess.unsupported_lines} line(s) with an unknown schema skipped"))
    if sess.foreign_lines:
        out.append(warning("foreign_lines_ignored", f"{sess.foreign_lines} line(s) from another session ignored"))
    return out


def findings(items: List[Finding]) -> List[Dict[str, Any]]:
    return [{"section": f.section, "line": f.line, "kind": f.kind} for f in items]


def plan_object(plan, dry_run: bool) -> Dict[str, Any]:
    from prompt_relay import retention as r
    items = []
    freed = 0
    for it in plan.items:
        if it.action == r.DELETED:
            freed += it.file.size
        items.append({
            "session_id": it.session.session_id,
            "session_key": it.file.key,
            "project": project_ref(it.session.project_dir),
            "last_activity_at": iso(it.last_activity_epoch),
            "turn_count": len(it.session.turns),
            "bytes": it.file.size,
            "action": it.action,
            "reason": it.reason or None,
        })
    return {
        "operation": plan.kind,
        "dry_run": dry_run,
        "criteria": {
            "older_than_days": plan.older_than_days,
            "session": plan.session,
            "all": plan.all_sessions,
            "force_active": plan.force_active,
        },
        "now": iso(plan.now),
        "cutoff": iso(plan.cutoff_epoch),
        "active_grace_minutes": r.ACTIVE_GRACE_S // 60,
        "items": items,
        "summary": {
            "matched": len(items),
            "would_delete": plan.count(r.WOULD_DELETE),
            "deleted": plan.count(r.DELETED),
            "skipped": plan.count(r.SKIPPED_ACTIVE, r.SKIPPED_CHANGED, r.SKIPPED_UNSAFE),
            "failed": plan.count(r.FAILED),
            "bytes_freed": freed,
        },
    }
