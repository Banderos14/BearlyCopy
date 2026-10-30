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
HARNESS_TAGS = ("system-reminder", "side-sessions-event", "ci-monitor-event", "task-notification")

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
