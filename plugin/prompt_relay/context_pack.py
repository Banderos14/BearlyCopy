"""Context Pack (Phase 13): several results in one hand-off.

A Context Pack is one Markdown document that carries one or more results
(request, final response, observed work, Git state) for another AI, each in
its own section with its own source and provenance. It never merges two
results, never summarises them and never lets one agent's words confirm
another's. Every result section is built by the same functions as Copy with
Context (``export.py``), one heading level deeper, so the labels and the
verbatim rules are the same.

Two representations of one pack:

- Markdown (``render_pack``): what the user copies into a chat;
- a manifest (``manifest``): machine-readable facts about the pack, its
  results and their provenance. It holds no absolute paths and no session
  ids: results are named by an opaque ``result_id``.

The format is versioned on its own (``FORMAT_VERSION``), independently of the
app, the Core and JSON API v1. The macOS app builds the same document from
the result sections the Core returns (``context-pack --json``) plus the
attachments and imports only the app knows; docs/CONTEXT_PACK.md is the
shared specification.
"""

from __future__ import annotations

import hashlib
import os
from typing import Any, Dict, List, Optional, Sequence, Tuple

from prompt_relay import correlation as c
from prompt_relay import export, origin, tools
from prompt_relay.export import CONFIRMED, NOT_VERIFIED, UNAVAILABLE
from prompt_relay.gitinfo import GitInfo
from prompt_relay.history import Session

FORMAT = "prompt-relay-context-pack"
FORMAT_VERSION = 1
MAX_RESULTS = 20
USER_SUPPLIED = "Supplied by you"

PROVIDER_TITLES = {"claude_code": "Claude Code", "codex": "Codex"}


def result_id(session_key: str, turn: int) -> str:
    """Opaque, stable id of one result (session key + turn): no session id or
    path can be read from it. The same result always gets the same id."""
    digest = hashlib.sha256(f"{session_key}#{turn}".encode("utf-8", "surrogatepass")).hexdigest()
    return "r-" + digest[:16]


def profile_name(profile: Optional[Dict[str, Any]]) -> str:
    """The neutral profile name the app shows when the user gave none:
    Default, Unassigned, Xcode, or the config folder's name."""
    if not profile:
        return "Unassigned"
    if profile.get("default"):
        return "Default"
    hint = profile.get("hint") or ""
    if "/Xcode/CodingAssistant" in hint:
        return "Xcode"
    name = os.path.basename(hint.rstrip("/")).lstrip(".")
    if name and name != "~":
        return name
    return "Profile " + str(profile.get("id", ""))[3:9]


def _shifted(add):
    """An ``add`` that puts every heading the section functions write one
    level deeper. Verbatim text is always added as one fenced block, which
    starts with a backtick, so it is never touched."""
    def shifted(line: str) -> None:
        add("#" + line if line.startswith("#") else line)
    return shifted


def render_section(session: Session, turn: c.Turn, git: GitInfo, exported_at: str,
                   project_root: Optional[str] = None, git_same_as: Optional[int] = None) -> str:
    """One result's body (no "## Result" heading): source, request, the final
    response verbatim, observed work, Git state and what is not checked.
    ``git_same_as``: an earlier result of the same project already holds the
    Git state collected for this pack."""
    lines: List[str] = []
    add = _shifted(lines.append)
    export._source_section(add, session, turn, project_root)
    export._request_section(add, session, turn)
    export._response_section(add, session, turn)
    export._observed_section(add, session, turn, export.FULL)
    if git_same_as is None:
        export._git_section(add, session, git, exported_at, export.FULL)
    else:
        add(f"## Git state (read-only, collected at export time {exported_at})")
        add(f"- Same repository and the same reading as Result {git_same_as} [{CONFIRMED}]")
        add("")
    export._not_checked_section(add, session)
    return "\n".join(lines) + "\n"


def heading(number: int, total: int, provider: str, profile: str, host: str, project: str) -> str:
    return f"## Result {number} of {total} — {provider} · {profile} · {host} · {project}"


def preamble(count: int, exported_at: str, agents: Sequence[str]) -> List[str]:
    """Title, provenance labels and the separation rule (shared with the app)."""
    reported = "; ".join(f"[Reported by {a}] = {a}'s own words, not checked" for a in agents)
    noun = "result" if count == 1 else "results"
    return [
        f"# Context Pack: {count} AI {noun} for an independent check",
        f"Prepared by Prompt Relay at {exported_at}. No AI service was used. Format: {FORMAT} v{FORMAT_VERSION}.",
        "",
        "Provenance labels: [Confirmed locally] = recorded on this machine by Prompt Relay; "
        + (reported + "; " if reported else "")
        + f"[{USER_SUPPLIED}] = typed or pasted into Prompt Relay by the user; "
        f"[{NOT_VERIFIED}] = no independent source; [{UNAVAILABLE}] = could not be determined.",
        "",
        "Each result below is a separate section with its own source. Their texts are not merged or rewritten, "
        "and one agent's statements do not confirm another's.",
        "",
    ]


def contents(entries: Sequence[Dict[str, str]], warnings: Sequence[str]) -> List[str]:
    """``entries``: provider, profile, host, project, title, answered_at."""
    lines = ["## Contents"]
    for n, e in enumerate(entries, 1):
        title = " ".join((e.get("title") or "").split())
        title = title if len(title) <= 80 else title[:79] + "…"
        lines.append(f"{n}. {e['provider']} · {e['profile']} · {e['host']} — project {e['project']}"
                     + (f" — “{title}”" if title else "")
                     + f" — answered {e.get('answered_at') or UNAVAILABLE}")
    for w in warnings:
        lines.append(f"- Warning: {w}")
    lines.append("")
    return lines


STANDARD_REQUEST = ("Please review each result independently. For each one, check whether the response fulfils its "
                    "original request, compare the agent's claims with what was observed, and point out unsupported "
                    "claims, risks and missing verification. Where results depend on each other, say where they agree "
                    "or conflict, without treating one agent's statement as proof of another's. Propose the next "
                    "concrete step.")


def instructions_section(instructions: Optional[str]) -> List[str]:
    """The user's own instructions, verbatim and labelled as theirs; without
    them, Prompt Relay's standard request, labelled as such."""
    if instructions is not None and instructions.strip():
        return ["## Review instructions",
                f"[{USER_SUPPLIED}] Written by the user for the receiving AI. Not part of any agent's result.",
                "",
                export._block(instructions),
                ""]
    return ["## Review request",
            "[Prompt Relay standard text] The user wrote no instructions; this is Prompt Relay's default request.",
            "",
            STANDARD_REQUEST,
            ""]


def mixed_project_warning(projects: Sequence[str]) -> Optional[str]:
    distinct = sorted(set(projects))
    if len(distinct) < 2:
        return None
    return (f"these results come from {len(distinct)} different projects ({', '.join(distinct)}). "
            "Their contexts are separate; a file or command in one project says nothing about another.")


def render_pack(sections: Sequence[Tuple[Dict[str, str], str]], exported_at: str,
                instructions: Optional[str] = None, extra_warnings: Sequence[str] = ()) -> str:
    """The whole Markdown document. ``sections``: (contents entry, body)."""
    entries = [e for e, _ in sections]
    agents = []
    for e in entries:
        agent = e.get("agent") or ("Codex" if e["provider"] == "Codex" else "Claude")
        if agent not in agents:
            agents.append(agent)
    warnings = list(extra_warnings)
    mixed = mixed_project_warning([e["project"] for e in entries])
    if mixed:
        warnings.insert(0, mixed)
    lines = preamble(len(sections), exported_at, agents) + contents(entries, warnings)
    total = len(sections)
    for n, (e, body) in enumerate(sections, 1):
        lines.append(heading(n, total, e["provider"], e["profile"], e["host"], e["project"]))
        lines.append("")
        lines.append(body.rstrip("\n"))
        lines.append("")
    lines += instructions_section(instructions)
    return "\n".join(lines).rstrip("\n") + "\n"


# -- facts for the manifest and the app ------------------------------------------------

def _request_info(session: Session, turn: c.Turn) -> Dict[str, Any]:
    req = export.request_text(turn)
    if req is None:
        return {"included": False, "provenance": "unavailable", "origin": "unknown"}
    codex = bool(turn.prompt and turn.prompt.source and turn.prompt.source.get("provider") == "codex")
    kind = origin.classify(req)
    who = "not_established" if codex else ("user" if origin.is_user(kind) else
                                            "unknown" if kind == origin.UNKNOWN else "automated")
    info: Dict[str, Any] = {"included": True, "provenance": "confirmed_locally" if turn.link == c.LINK_PROMPT_ID
                            else "confirmed_locally_link_inferred", "origin": who, "characters": len(req)}
    if who == "automated":
        earlier = export.earlier_user_request(session, turn)
        info["earlier_user_request_turn"] = earlier[0] if earlier else None
    return info


def entry(session: Session, turn: c.Turn, project_root: Optional[str], title: Optional[str],
          profile: Optional[Dict[str, Any]]) -> Dict[str, str]:
    source, provider, agent = export.provider_names(session)
    host = export.HOST_TITLES.get((source or {}).get("host", "unknown"), "Unknown")
    project = os.path.basename(project_root.rstrip(os.sep)) if project_root else session.project_name
    final = turn.final_response
    return {"provider": provider, "agent": agent, "profile": profile_name(profile), "host": host, "project": project,
            "title": title or "", "answered_at": (final.received_at if final else "") or ""}


def result_manifest(position: int, session: Session, turn: c.Turn, e: Dict[str, str],
                    completion: Dict[str, Any], profile: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    source = next((ev.source for ev in session.events if ev.source), None)
    final = turn.final_response
    counts = tools.observed_counts(turn)
    return {
        "position": position,
        "result_id": result_id(session.key, turn.index),
        "kind": "local_capture",
        "provider": (source or {}).get("provider", "claude_code"),
        "profile": e["profile"],
        "profile_recorded": profile is not None,
        "host": (source or {}).get("host", "unknown"),
        "project": e["project"],
        "turn": turn.index,
        "answered_at": e["answered_at"] or None,
        "status": turn.status,
        "completion": completion.get("completion"),
        "link": turn.link,
        "request": _request_info(session, turn),
        "response": {"included": bool(final and final.text is not None),
                     "provenance": "reported_by_agent", "characters": len(final.text) if final and final.text else 0},
        "observed": {"provenance": "confirmed_locally", **counts},
        "attachments": [],
    }


def manifest(results: List[Dict[str, Any]], exported_at: str, version: str, instructions: Optional[str],
             warnings: Sequence[str], characters: int) -> Dict[str, Any]:
    """Machine-readable facts about one pack: no absolute paths, no session
    ids, no text of the request or the response."""
    return {
        "format": FORMAT,
        "format_version": FORMAT_VERSION,
        "prepared_at": exported_at,
        "prepared_by": f"Prompt Relay {version}",
        "ai_service_used": False,
        "result_count": len(results),
        "results": results,
        "review_instructions": {"supplied_by_user": bool(instructions and instructions.strip()),
                                "characters": len(instructions or "")},
        "markdown_characters": characters,
        "warnings": list(warnings),
        "limits": [
            "Claims inside a response are the agent's own words and are not verified.",
            "Git state is read when the pack is prepared, not when the agent finished.",
            "Copying the pack does not mean another app received it.",
        ],
    }
