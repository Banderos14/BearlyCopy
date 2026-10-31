"""Export formats.

Mode A, Copy Response: ``response_text`` returns Claude's final message
exactly as captured. Nothing is added, removed or re-encoded.

Mode B, Copy with Context (formerly Copy for ChatGPT, Review Pack): ``render_context`` builds a
structured packet for an independent review in ChatGPT. Each fact carries a provenance label:

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
from prompt_relay import origin, tools
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


API_ERROR_AFTER_STOP = ("Claude stopped with a message, but the turn later ended with an API error "
                        "(StopFailure); the work may be incomplete.")


class ExportError(Exception):
    pass


def status_text(turn: c.Turn) -> str:
    if turn.status == c.STATUS_API_ERROR and turn.final_response is not None:
        return API_ERROR_AFTER_STOP
    return STATUS_TEXT.get(turn.status, turn.status)


def warnings_for(turn: c.Turn) -> List[str]:
    """Reasons to treat the final response with caution (shown on stderr)."""
    final = turn.final_response
    if final is None:
        return []
    found = []
    if turn.status == c.STATUS_API_ERROR:
        found.append(API_ERROR_AFTER_STOP)
    elif final.has_background_tasks:
        found.append("background tasks were still running when Claude stopped; the work may not be finished")
    return found


def response_text(turn: c.Turn) -> str:
    final = turn.final_response
    if final is None or final.text is None:
        raise ExportError(status_text(turn))
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


def earlier_user_request(session: Optional[Session], turn: c.Turn) -> Optional[tuple]:
    """For a turn started by an automated message: (turn index, text) of the
    latest earlier request from the user in the same session."""
    req = request_text(turn)
    if session is None or req is None or origin.classify(req) != origin.AUTOMATED:
        return None
    found = origin.earlier_user_prompt(session.turns, turn.index)
    return None if found is None else (found[0], found[1].text)


def sensitive_findings(turn: c.Turn, request: bool = True, session: Optional[Session] = None) -> List[Finding]:
    findings: List[Finding] = []
    req = request_text(turn) if request else None
    if req:
        findings += scan(req, "request")
    earlier = earlier_user_request(session, turn) if request else None
    if earlier and earlier[1]:
        findings += scan(earlier[1], "request")
    final = turn.final_response
    if final and final.text:
        findings += scan(final.text, "response")
    return findings


def _relative(path: str, root: Optional[str]) -> str:
    """A path inside the project as project-relative; other paths keep only
    their last two components (no user name, no machine layout)."""
    if root:
        base = root.rstrip("/") + "/"
        if path.startswith(base):
            return path[len(base):]
    parts = [p for p in path.split("/") if p]
    return "…/" + "/".join(parts[-2:]) if len(parts) > 2 else path


def _duration(ms: Optional[int]) -> str:
    if ms is None:
        return "—"
    return f"{ms / 1000:.1f} s" if ms >= 1000 else f"{ms} ms"


def _command_cell(cmd: dict) -> str:
    if cmd.get("command") is None:
        return f"(command withheld: {cmd.get('command_withheld') or 'unavailable'})"
    line = cmd["command"].strip().splitlines()[0] if cmd["command"].strip() else ""
    line = line if len(line) <= 100 else line[:99] + "…"
    return line.replace("|", "\\|")


def _result_cell(cmd: dict) -> str:
    if cmd.get("background"):
        return "started in background; result not observed"
    if cmd.get("outcome") == "interrupted":
        return "interrupted"
    code = cmd.get("exit_code")
    text = f"exit {code}" if isinstance(code, int) else "exit code unavailable"
    if cmd.get("compound"):
        text += " ¹"
    return text


# Detail levels of Copy with Context (Phase 7). FULL is the package as it
# was before; STANDARD keeps the request and the response whole and leaves
# out output tails, routine commands and the full `git status` list, saying
# so in the package. One renderer for both, so the parts never diverge.
FULL = "full"
STANDARD = "standard"
DETAILS = (STANDARD, FULL)


def _observed_section(add, session: Session, turn: c.Turn, level: str = FULL) -> None:
    detail = tools.observed_detail(turn)
    commands = detail["commands"]
    add(f"## Observed during this turn [{CONFIRMED}]")
    if not turn.tools:
        add(f"[{UNAVAILABLE}] No tool events were captured for this turn. They need the Prompt Relay plugin 0.3.0 or "
            "later (PostToolUse / PostToolUseFailure hooks) with capture on for this project.")
        add("")
        return
    add("Source: Claude Code PostToolUse / PostToolUseFailure hook events of this session and turn.")
    main = [x for x in commands if not x["agent_type"]]
    sub = [x for x in commands if x["agent_type"]]
    important = [x for x in main if x["kind"] in ("test", "build", "git") or x["outcome"] != "ok" or x["background"]]
    if level == STANDARD:
        important = [x for x in important if x["kind"] in ("test", "build") or x["outcome"] != "ok" or x["background"]]
    others = len(main) - len(important)
    if important:
        add("")
        add("| Time (UTC) | Command (as run) | Result | Duration |")
        add("|---|---|---|---|")
        for x in important:
            when = x["at"][11:19] if len(x["at"]) >= 19 else x["at"]
            mark = " (after Stop)" if x["after_stop"] else ""
            add(f"| {when}{mark} | `{_command_cell(x)}` | {_result_cell(x)} | {_duration(x['duration_ms'])} |")
    add("")
    listed = "tests, builds, failures, background" if level == STANDARD else "tests, builds, git, failures, background"
    add(f"- Commands: {len(main)} observed; {len(important)} listed ({listed}); "
        f"{others} other commands counted, not listed.")
    if sub:
        failed_sub = sum(1 for x in sub if x["outcome"] != "ok")
        kinds = sorted({x["agent_type"] for x in sub})
        add(f"- Subagents ({', '.join(kinds)}): {len(sub)} commands, {failed_sub} not successful; not in the counts above.")
    if any(x["compound"] for x in important):
        add("- ¹ The command has a pipe, `||`, `;` or `&`: the exit code is the last process's and may hide a failure.")
    tails = [x for x in important if x.get("output_tail") or x.get("tail_withheld")]
    if level == STANDARD and tails:
        add(f"- Output of {len(tails)} listed command(s): left out in Standard; Copy with Context → Full includes it.")
    for x in important if level == FULL else []:
        if x.get("output_tail"):
            add(f"- Last lines of `{_command_cell(x)}` ({_result_cell(x)}), secret-scanned:")
            add(_block(x["output_tail"]))
        elif x.get("tail_withheld"):
            add(f"- Output of `{_command_cell(x)}` withheld: {x['tail_withheld']}.")
    if detail["notifications"]:
        add(f"- Background or subagent completion messages delivered during the turn: {detail['notifications']}.")
    if session.unlinked_tools:
        add(f"- {len(session.unlinked_tools)} tool events of this session could not be linked to a turn and are not included.")
    add("- Exit codes describe single commands. They do not show that the task is complete, and a later "
        "successful run does not show that every earlier failure was fixed.")
    add("")
    files = detail["files_changed"]
    add(f"## Files Claude changed (Edit/Write tool calls) [{CONFIRMED}]")
    if files:
        for f in files:
            edits = f" ({f['count']} edits)" if f["count"] > 1 else ""
            add(f"- {_relative(f['path'], session.project_dir)} — {', '.join(f['tools'])}{edits}")
        add("- Files changed through shell commands appear only in the Git state below.")
    else:
        add("- None observed. Changes made through shell commands appear only in the Git state below.")
    add("")


def _request_section(add, session: Session, turn: c.Turn) -> None:
    """The request, labelled by its origin (origin.py). A turn Claude Code
    started itself is never presented as the user's request."""
    req = request_text(turn)
    if req is None:
        add("## Original user request")
        add(f"[{UNAVAILABLE}] The request could not be determined unambiguously, so it is not included.")
        add("")
        return
    tag = CONFIRMED if turn.link == c.LINK_PROMPT_ID else f"{CONFIRMED}; link inferred"
    kind = origin.classify(req)
    if origin.is_user(kind):
        add("## Original user request")
        pasted = " It was pasted (Claude Code marked it as pasted text)." if kind == origin.USER_PASTED else ""
        add(f"[{tag}] Request as captured; it holds no automated message blocks.{pasted}")
        add("")
        add(_block(req))
        add("")
        return
    if kind == origin.UNKNOWN:
        add("## Request (source not established)")
        add(f"[{tag}] Request source not established: the text mixes automated message blocks (such as "
            "system reminders) with other text, so Prompt Relay cannot tell whether the user wrote it.")
        add("")
        add(_block(req))
        add("")
        return
    add("## Original user request")
    earlier = earlier_user_request(session, turn)
    if earlier is not None:
        add(f"[{CONFIRMED}; from turn {earlier[0]} of this session] This turn was not started by the user. "
            "The latest earlier request from the user in this session:")
        add("")
        add(_block(earlier[1] or ""))
    else:
        add(f"[{UNAVAILABLE}] This turn was not started by the user, and no earlier request from the user "
            "was captured in this session.")
    add("")
    add("### Automated message that started this turn")
    add(f"[{CONFIRMED}] Not written by the user: Claude Code started this turn itself (for example when a "
        "background session reported back). Verbatim:")
    add("")
    add(_block(req))
    add("")


def render_context(session: Session, turn: c.Turn, git: GitInfo, exported_at: str, detail: str = FULL) -> str:
    if detail not in DETAILS:
        raise ValueError(f"unknown detail level {detail!r}")
    final = turn.final_response
    lines: List[str] = []
    add = lines.append
    add("# Copy with Context: Claude Code result for an independent check")
    add(f"Exported by Prompt Relay at {exported_at}. No AI service was used.")
    if detail == STANDARD:
        add("Detail: Standard. The request and the response are complete. Left out: command output, routine and "
            "git commands (counted below) and the list of uncommitted files; Full Context has them.")
    add("")
    add("Provenance labels: [Confirmed locally] = recorded on this machine by Prompt Relay; "
        "[Reported by Claude] = Claude's own words, not checked; "
        "[Not verified] = no independent source; [Unavailable] = could not be determined.")
    add("")
    add("## Session")
    add(f"- Source: Claude Code on this Mac, captured by the Prompt Relay hooks [{CONFIRMED}]")
    add(f"- Project: {session.project_name} [{CONFIRMED if session.project_dir else UNAVAILABLE}]")
    add(f"- Session ID: {session.session_id or UNAVAILABLE} [{CONFIRMED if session.session_id else UNAVAILABLE}]")
    add(f"- Turn: {turn.index} of {len(session.turns)}")
    when = final.received_at if final else (turn.last_event.received_at if turn.last_event else "")
    add(f"- Response captured at: {when or UNAVAILABLE} [{CONFIRMED if when else UNAVAILABLE}]")
    add(f"- Response status: {status_text(turn)} [{CONFIRMED}]")
    if len(turn.responses) > 1:
        add(f"- Response events in this turn: {len(turn.responses)} (stop-hook continuations or background wake-ups); the last Stop is shown")
    if final and final.has_background_tasks:
        add(f"- Background tasks at Stop: {len(final.work_tasks)} still in flight [{CONFIRMED}]")
    elif final and final.background_tasks is None:
        add(f"- Background tasks at Stop: not reported by Claude Code [{UNAVAILABLE}]")
    if final and final.watchers:
        add(f"- Watchers at Stop: {final.watchers} (monitors such as an artifact's live updates; not work in flight) [{CONFIRMED}]")
    add(f"- Request ↔ response link: {LINK_TEXT.get(turn.link, turn.link)}")
    add("")

    _request_section(add, session, turn)

    add("## Claude final response")
    if final is not None and final.text is not None:
        add(f"[{REPORTED}] Verbatim text of Claude's last message for this turn.")
        add("")
        add(_block(final.text, "markdown"))
    else:
        add(f"[{UNAVAILABLE}] {status_text(turn)}")
        if turn.responses and turn.responses[-1].kind == "stop_failure":
            err = turn.responses[-1]
            add(f"- API error type: {err.error or UNAVAILABLE} [{CONFIRMED}]")
    add("")

    _observed_section(add, session, turn, detail)

    add(f"## Git state (read-only, collected at export time {exported_at})")
    if git.available:
        add(f"- Branch: {git.branch or UNAVAILABLE} [{CONFIRMED if git.branch else UNAVAILABLE}]")
        add(f"- HEAD commit: {git.head or UNAVAILABLE + ' (no commits yet)'} [{CONFIRMED if git.head else UNAVAILABLE}]")
        if git.changed_files and detail == STANDARD:
            add(f"- Uncommitted changes: {len(git.changed_files)}{'+' if git.changed_files_truncated else ''} entries "
                f"(`git status --porcelain`; the list is in Full Context) [{CONFIRMED}]")
        elif git.changed_files:
            add(f"- Uncommitted changes ({len(git.changed_files)}{'+' if git.changed_files_truncated else ''} entries, `git status --porcelain`) [{CONFIRMED}]:")
            add(_block("\n".join(git.changed_files)))
        else:
            add(f"- Uncommitted changes: none [{CONFIRMED}]")
        add("- Note: this is the state when exported, which may differ from the state when Claude finished.")
    else:
        add(f"- [{UNAVAILABLE}] {git.reason}")
    add("")

    add("## Not checked")
    add(f"- Claude's claims of success, passing tests or completed work: [{NOT_VERIFIED}]. Compare them with the "
        "observed commands above; Prompt Relay does not interpret Claude's text.")
    add(f"- CI: no source is connected [{UNAVAILABLE}]")
    add(f"- Completion signal: Claude Code Stop hook event, which only means Claude stopped responding [{CONFIRMED}]")
    add("")
    add("## Request for review")
    add("Please review this result independently. Check whether the response actually fulfils the original "
        "request, compare Claude's claims with the observed commands, point out unsupported claims, risks and "
        "missing verification, and propose the next concrete step or follow-up prompt for Claude Code.")
    return "\n".join(lines) + "\n"
