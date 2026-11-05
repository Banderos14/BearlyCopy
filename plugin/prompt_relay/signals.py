"""Signals that an agent waits for the person (Phase 12.1).

Claude Code shows a question (AskUserQuestion), a plan for approval
(ExitPlanMode), a permission dialog (PermissionRequest), or an MCP
elicitation, and stops working until the person acts. Hooks report these
moments; Prompt Relay only *observes* them:

- the handler never writes stdout and always exits 0, which the hooks
  documentation defines as "no decision" — the normal dialog appears and
  nothing is answered, allowed, approved or changed (no ``updatedInput``);
- only a reduced record is stored: event and tool names, the notification
  type and ids. Question text, plan text, ``tool_input``, ``message``,
  ``title`` and ``permission_suggestions`` are never stored.

There is no hook for "the person answered". A wait ends with the next
activity the hooks confirm: a tool result, a new prompt, Stop/StopFailure,
an elicitation result notification, or the end of the session. Never on a
timer (``attention`` in api.py).
"""

from __future__ import annotations

from typing import Any, Dict, Optional

SIGNAL_EVENTS = ("PreToolUse", "PermissionRequest", "Notification", "SessionEnd")

QUESTION = "question"
PLAN = "plan_approval"
PERMISSION = "permission"
ELICITATION = "elicitation"
INPUT = "input"
KINDS = (QUESTION, PLAN, PERMISSION, ELICITATION, INPUT)

NEEDS_INPUT = "needs_input"
RESOLVED = "resolved"
SESSION_END = "session_end"
# A tool finished while a wait was open: the agent works again. ACTIVITY,
# RESOLVED and SESSION_END are written only while a waiting marker exists
# (hook.py), so ordinary tools and session ends add no records.
ACTIVITY = "activity"
ALL_SIGNALS = (NEEDS_INPUT, RESOLVED, SESSION_END, ACTIVITY)

# Tool results that stay evidence (tools.reduce), exactly the 0.3.0 matchers.
# Every other tool result is at most an ACTIVITY signal.
EVIDENCE_TOOLS = {
    "PostToolUse": ("Bash", "Write", "Edit", "MultiEdit", "NotebookEdit", "SendUserFile", "Artifact"),
    "PostToolUseFailure": ("Bash", "Write", "Edit", "MultiEdit", "NotebookEdit"),
}


def is_evidence(payload: Dict[str, Any]) -> bool:
    return payload.get("tool_name") in EVIDENCE_TOOLS.get(payload.get("hook_event_name"), ())  # type: ignore[arg-type]


def activity(payload: Dict[str, Any]) -> Dict[str, Any]:
    """A non-evidence tool result, reduced to ids and the tool name."""
    out: Dict[str, Any] = {"hook_event_name": payload.get("hook_event_name"), "reduced": 1, "signal": ACTIVITY}
    for key in ("session_id", "prompt_id", "tool_use_id", "agent_id", "cwd"):
        value = payload.get(key)
        if isinstance(value, str) and value:
            out[key] = value[:200]
    tool = payload.get("tool_name")
    if isinstance(tool, str) and tool:
        out["tool_name"] = tool[:120]
    return out

PRE_TOOL_KINDS = {"AskUserQuestion": QUESTION, "ExitPlanMode": PLAN}
NOTIFICATION_KINDS = {
    "permission_prompt": PERMISSION,
    "elicitation_dialog": ELICITATION,
    "elicitation_url_dialog": ELICITATION,
    "agent_needs_input": INPUT,
}
NOTIFICATION_RESOLVED = ("elicitation_complete", "elicitation_response")


def classify(payload: Dict[str, Any]) -> Optional[Dict[str, str]]:
    """``{"signal": ..., "kind"?: ...}`` or None (not a signal: not stored)."""
    event = payload.get("hook_event_name")
    if event == "PreToolUse":
        kind = PRE_TOOL_KINDS.get(payload.get("tool_name"))  # type: ignore[arg-type]
        return {"signal": NEEDS_INPUT, "kind": kind} if kind else None
    if event == "PermissionRequest":
        return {"signal": NEEDS_INPUT, "kind": PERMISSION}
    if event == "Notification":
        ntype = payload.get("notification_type")
        if ntype in NOTIFICATION_KINDS:
            return {"signal": NEEDS_INPUT, "kind": NOTIFICATION_KINDS[ntype]}
        if ntype in NOTIFICATION_RESOLVED:
            return {"signal": RESOLVED}
        return None
    if event == "SessionEnd":
        return {"signal": SESSION_END}
    return None


def reduce(payload: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """The only form of a signal event that is ever stored; None: ignore."""
    found = classify(payload)
    if found is None:
        return None
    out: Dict[str, Any] = {"hook_event_name": payload.get("hook_event_name"), "reduced": 1, **found}
    for key in ("session_id", "prompt_id", "tool_use_id", "agent_id", "agent_type", "cwd", "notification_type"):
        value = payload.get(key)
        if isinstance(value, str) and value:
            out[key] = value[:200]
    tool = payload.get("tool_name")
    if isinstance(tool, str) and tool:
        out["tool_name"] = tool[:120]
    return out
