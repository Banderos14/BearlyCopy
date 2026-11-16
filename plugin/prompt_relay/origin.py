"""Where a captured request came from (Phase 5.11).

UserPromptSubmit carries no field that says who wrote the prompt. Claude Code
also fires it for turns it starts itself: a side session finishing, a CI
monitor waking the session. Those prompts are made of harness blocks such as
``<system-reminder>`` and ``<side-sessions-event>`` (observed 2026-10-30,
HOOKS_RESEARCH §3a). The origin is therefore read from the text's structure,
and stays "unknown" whenever the structure does not settle it:

- "user"         no harness block outside pasted text
- "user_pasted"  the same, and the text holds a ``<pasted_content>`` block
- "automated"    nothing but harness blocks (and whitespace)
- "unknown"      harness blocks mixed with other text

Blocks inside ``<pasted_content>`` are the user's pasted data and never count.
The stored text is never changed; this only decides how it is labelled.
"""

from __future__ import annotations

import re
from typing import List, Optional

from prompt_relay.events import Event

USER = "user"
USER_PASTED = "user_pasted"
AUTOMATED = "automated"
UNKNOWN = "unknown"

# Blocks Claude Code and the desktop app inject into turns they start.
# Phase 12.1 fix: ``<agent-message from="...">`` — a subagent's or another
# session's report delivered into the conversation (observed 2026-11-05 in
# Claude Desktop's Code tab: the whole prompt was one such block).
HARNESS_TAGS = ("system-reminder", "side-sessions-event", "ci-monitor-event", "task-notification", "agent-message")

_PASTED = re.compile(r"<pasted_content\b([^>]*)>.*?</pasted_content\1>|<pasted_content\b[^>]*>.*?</pasted_content\b[^>]*>",
                     re.DOTALL)
_HARNESS = re.compile(r"<(%s)\b[^>]*>.*?</\1>" % "|".join(re.escape(t) for t in HARNESS_TAGS), re.DOTALL)


def classify(text: Optional[str]) -> str:
    if text is None or not text.strip():
        return UNKNOWN
    outside, pasted = _PASTED.subn(" ", text)
    rest, harness = _HARNESS.subn(" ", outside)
    if not harness:
        return USER_PASTED if pasted else USER
    if not rest.strip() and not pasted:
        return AUTOMATED
    return UNKNOWN


def strip_harness(text: str) -> str:
    """The text without harness blocks, for one-line titles only."""
    return _HARNESS.sub(" ", text)


_WRAPPER = re.compile(r"</?pasted_content\b[^>]*>")


def display_preview(text: Optional[str], limit: int) -> Optional[str]:
    """The start of a request as a person would read it: harness blocks and
    paste wrappers removed. None when nothing but harness blocks remains.
    For display only; exports keep the verbatim text."""
    if not text:
        return None
    rest = _WRAPPER.sub("", strip_harness(text)).strip()
    return rest[:limit] if rest else None


def is_user(origin: str) -> bool:
    return origin in (USER, USER_PASTED)


def earlier_user_prompt(turns: List, index: int) -> Optional[tuple]:
    """(turn index, prompt) of the latest request before turn ``index`` (1-based)
    of the same session whose origin is the user; None when there is none."""
    for t in reversed(turns[: index - 1]):
        p: Optional[Event] = t.prompt
        if p is not None and is_user(classify(p.text)):
            return t.index, p
    return None


# Phase 9.3: a short request that only continues earlier work ("продолжи где
# остановился", "continue"). Its text stays the turn's request, verbatim; the
# latest earlier substantive request of the same session is offered beside
# it as labelled context, never in its place.
CONTINUATION_MAX_CHARS = 120
_CONTINUATION = re.compile(
    r"^\s*(?:please\s+|пожалуйста[,\s]+|ну\s+)?"
    r"(?:продолж(?:и|ай|им|ите|айте|ить|аем)|дальше|далее|давай\s+дальше|continue|go\s+on|keep\s+going|carry\s+on|resume|proceed)"
    r"(?![\w-])",
    re.IGNORECASE)


def is_continuation(text: Optional[str]) -> bool:
    if not text:
        return False
    rest = _WRAPPER.sub("", strip_harness(text)).strip()
    return 0 < len(rest) <= CONTINUATION_MAX_CHARS and _CONTINUATION.match(rest) is not None


def continued_prompt(turns: List, index: int) -> Optional[tuple]:
    """For a short continuation request at turn ``index``: (turn index, prompt)
    of the latest earlier request in the same session that is neither a
    continuation nor automated; None otherwise."""
    if index < 2 or index > len(turns):
        return None
    current = turns[index - 1].prompt
    if current is None or not is_continuation(current.text):
        return None
    for t in reversed(turns[: index - 1]):
        p: Optional[Event] = t.prompt
        if p is None or not p.text or classify(p.text) == AUTOMATED or is_continuation(p.text):
            continue
        return t.index, p
    return None
