"""Export formats.

Mode A, Copy Response: ``response_text`` returns Claude's final message
exactly as captured. Nothing is added, removed or re-encoded.

Mode B, Copy Context: ``render_context`` builds a structured review packet
for ChatGPT. Each fact carries a provenance label:

- Confirmed locally   read by Prompt Relay on this machine (hook metadata
                      recorded by the local handler, read-only git output)
- Reported by Claude  text written by Claude; not independently checked
- Not verified        no independent source is connected
- Unavailable         could not be determined

The original request and response are embedded verbatim inside fences that
are longer than any fence run in the text, so the content cannot break out.
"""

from __future__ import annotations

import re
from typing import List, Optional

from prompt_relay import correlation as c
from prompt_relay.gitinfo import GitInfo
from prompt_relay.history import Session
from prompt_relay.sensitive import Finding, scan

CONFIRMED = "Confirmed locally"
REPORTED = "Reported by Claude"
NOT_VERIFIED = "Not verified"
UNAVAILABLE = "Unavailable"

STATUS_TEXT = {
    c.STATUS_STOPPED: "Stop event received. Claude finished responding; this does NOT mean the task succeeded.",
    c.STATUS_BACKGROUND: "Stop event received while background tasks were still running; the work may not be finished.",
    c.STATUS_NO_TEXT: "Stop event received without a final message text.",
    c.STATUS_API_ERROR: "The turn ended with an API error (StopFailure). There is no successful final response.",
    c.STATUS_AWAITING: "No response captured yet.",
    c.STATUS_NO_MATCH: "No response could be matched to this request.",
}

LINK_TEXT = {
    c.LINK_PROMPT_ID: "request and response share the same prompt_id",
    c.LINK_SEQUENCE: "inferred from event order only (no prompt_id available)",
    c.LINK_AMBIGUOUS: "ambiguous: several requests were pending; none was assigned",
    c.LINK_NONE: "no captured request could be linked",
}


class ExportError(Exception):
    pass


def response_text(turn: c.Turn) -> str:
    final = turn.final_response
    if final is None or final.text is None:
        raise ExportError(STATUS_TEXT.get(turn.status, "no final response"))
    return final.text


def fence(text: str) -> str:
    longest = max((len(m) for m in re.findall(r"`{3,}", text)), default=0)
    return "`" * max(3, longest + 1)


def _block(text: str, info: str = "text") -> str:
    f = fence(text)
    return f"{f}{info}\n{text}\n{f}"


def request_text(turn: c.Turn) -> Optional[str]:
    """The original request, only when it is unambiguously linked."""
    if turn.prompt is not None and turn.link in (c.LINK_PROMPT_ID, c.LINK_SEQUENCE):
        return turn.prompt.text
    return None


def sensitive_findings(turn: c.Turn) -> List[Finding]:
    findings: List[Finding] = []
    req = request_text(turn)
    if req:
        findings += scan(req, "request")
    final = turn.final_response
    if final and final.text:
        findings += scan(final.text, "response")
    return findings


def render_context(session: Session, turn: c.Turn, git: GitInfo, exported_at: str) -> str:
    final = turn.final_response
    lines: List[str] = []
    add = lines.append
    add("# Claude Code result for review (exported by Prompt Relay)")
    add("")
    add("Provenance labels: [Confirmed locally] = recorded on this machine by Prompt Relay; "
        "[Reported by Claude] = Claude's own words, not checked; "
        "[Not verified] = no independent source; [Unavailable] = could not be determined.")
    add("")
    add("## Session")
    add(f"- Project: {session.project_name} — {session.project_dir or UNAVAILABLE} [{CONFIRMED if session.project_dir else UNAVAILABLE}]")
    add(f"- Session ID: {session.session_id or UNAVAILABLE} [{CONFIRMED if session.session_id else UNAVAILABLE}]")
    add(f"- Turn: {turn.index} of {len(session.turns)}")
    when = final.received_at if final else (turn.last_event.received_at if turn.last_event else "")
    add(f"- Response captured at: {when or UNAVAILABLE} [{CONFIRMED if when else UNAVAILABLE}]")
    add(f"- Exported at: {exported_at}")
    add(f"- Response status: {STATUS_TEXT.get(turn.status, turn.status)} [{CONFIRMED}]")
    if len(turn.responses) > 1:
        add(f"- Response events in this turn: {len(turn.responses)} (stop-hook continuations or background wake-ups); the last Stop is shown")
    if final and final.has_background_tasks:
        add(f"- Background tasks at Stop: {len(final.background_tasks or [])} still in flight [{CONFIRMED}]")
    add(f"- Request ↔ response link: {LINK_TEXT.get(turn.link, turn.link)}")
    add("")

    add("## Original user request")
    req = request_text(turn)
    if req is not None:
        tag = CONFIRMED if turn.link == c.LINK_PROMPT_ID else f"{CONFIRMED}; link inferred"
        add(f"[{tag}]")
        add("")
        add(_block(req))
    else:
        add(f"[{UNAVAILABLE}] The request could not be determined unambiguously, so it is not included.")
    add("")

    add("## Claude final response")
    if final is not None and final.text is not None:
        add(f"[{REPORTED}] Verbatim text of Claude's last message for this turn.")
        add("")
        add(_block(final.text, "markdown"))
    else:
        add(f"[{UNAVAILABLE}] {STATUS_TEXT.get(turn.status, 'No final response.')}")
        if turn.responses and turn.responses[-1].kind == "stop_failure":
            err = turn.responses[-1]
            add(f"- API error type: {err.error or UNAVAILABLE} [{CONFIRMED}]")
    add("")

    add(f"## Git state (read-only, collected at export time {exported_at})")
    if git.available:
        add(f"- Branch: {git.branch or UNAVAILABLE} [{CONFIRMED if git.branch else UNAVAILABLE}]")
        add(f"- HEAD commit: {git.head or UNAVAILABLE + ' (no commits yet)'} [{CONFIRMED if git.head else UNAVAILABLE}]")
        if git.changed_files:
            add(f"- Uncommitted changes ({len(git.changed_files)}{'+' if git.changed_files_truncated else ''} entries, `git status --porcelain`) [{CONFIRMED}]:")
            add(_block("\n".join(git.changed_files)))
        else:
            add(f"- Uncommitted changes: none [{CONFIRMED}]")
        add("- Note: this is the state when exported, which may differ from the state when Claude finished.")
    else:
        add(f"- [{UNAVAILABLE}] {git.reason}")
    add("")

    add("## Tests and CI")
    add(f"- [{NOT_VERIFIED}] Prompt Relay has no independent source of test or CI results. "
        "Any statement about tests, builds or CI in Claude's response is reported by Claude only.")
    add("")
    add("## Verification status")
    add(f"- Claude's claims of success, passing tests or completed work: [{NOT_VERIFIED}]")
    add(f"- Completion signal: Claude Code Stop hook event, which only means Claude stopped responding [{CONFIRMED}]")
    add("")
    add("## Request for review")
    add("Please review this result independently. Check whether the response actually fulfils the original "
        "request, point out unsupported claims, risks and missing verification, and propose the next concrete "
        "step or follow-up prompt for Claude Code.")
    return "\n".join(lines) + "\n"
