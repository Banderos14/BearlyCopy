"""Group one session's events into turns (request -> response(s)).

Rules (docs/ARCHITECTURE.md, "Session correlation"):
1. Events of different sessions are never combined: callers pass one session.
2. A response whose ``prompt_id`` matches a captured prompt is linked to it
   with link="prompt_id" (confirmed by Claude Code metadata). Other pending
   prompts stay pending.
   A response whose ``prompt_id`` was never captured is linked by order only
   when exactly one prompt is pending and that prompt has no ``prompt_id``
   of its own (no conflicting evidence); otherwise it gets link="none".
3. A response without ``prompt_id`` is linked by order only when exactly one
   prompt arrived since the previous response: link="sequence" (inferred).
   With no new prompt, a continuation (stop_hook_active, or the previous
   response had background tasks) joins the previous turn (link stays as is
   but ``continued_by_sequence`` is set); otherwise it becomes its own turn
   with link="none". With several new prompts it becomes its own turn with
   link="ambiguous" and those prompts are listed as candidates, never guessed.
4. One prompt may get several responses (stop-hook continuations, background
   work waking the session). The last ``stop`` is the final response; if that
   Stop carried no text, there is no final response (an earlier, superseded
   text is never promoted).
5. ``link_events=False`` (events whose session is unknown) disables linking:
   every event becomes its own turn with link="none".
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional

from prompt_relay.events import Event

LINK_PROMPT_ID = "prompt_id"
LINK_SEQUENCE = "sequence"
LINK_AMBIGUOUS = "ambiguous"
LINK_NONE = "none"

STATUS_AWAITING = "awaiting_response"
STATUS_NO_MATCH = "no_matched_response"
STATUS_STOPPED = "stop_received"
STATUS_BACKGROUND = "stop_received_background_tasks_pending"
STATUS_NO_TEXT = "stop_received_without_text"
STATUS_API_ERROR = "api_error"


@dataclass
class Turn:
    index: int
    session_id: Optional[str]
    prompt: Optional[Event] = None
    responses: List[Event] = field(default_factory=list)
    link: str = LINK_NONE
    candidate_prompts: List[Event] = field(default_factory=list)
    candidate_turns: List[int] = field(default_factory=list)  # indexes of the candidate prompts' turns
    continued_by_sequence: bool = False
    trailing: bool = False  # no response event was received after this turn's prompt
    # Inputs Claude Code delivered inside this turn with the turn's own
    # prompt_id: background-task notifications and subagent hand-backs
    # (observed 2026-10-30, HOOKS_RESEARCH §3). They are not user requests.
    notifications: List[Event] = field(default_factory=list)
    # Observed tool results of this turn (ADR-013), in arrival order.
    tools: List[Event] = field(default_factory=list)

    @property
    def last_stop(self) -> Optional[Event]:
        for ev in reversed(self.responses):
            if ev.kind == "stop":
                return ev
        return None

    @property
    def final_response(self) -> Optional[Event]:
        stop = self.last_stop
        return stop if stop is not None and stop.text is not None else None

    @property
    def last_event(self) -> Optional[Event]:
        if self.responses:
            return self.responses[-1]
        return self.prompt

    @property
    def status(self) -> str:
        if not self.responses:
            return STATUS_AWAITING if self.trailing else STATUS_NO_MATCH
        last = self.responses[-1]
        if last.kind == "stop_failure":
            return STATUS_API_ERROR
        if last.text is None:
            return STATUS_NO_TEXT
        if last.has_background_tasks:
            return STATUS_BACKGROUND
        return STATUS_STOPPED

    @property
    def project_dir(self) -> Optional[str]:
        ev = self.last_event
        return ev.project_dir if ev else None


def build_turns(events: List[Event], link_events: bool = True,
                unlinked_tools: Optional[List[Event]] = None) -> List[Turn]:
    """Tool events never become turns or responses: they join the turn of
    their prompt_id, or the only open turn when they carry none; otherwise
    they go to ``unlinked_tools`` (counted, never exported as a turn's)."""
    turns: List[Turn] = []
    by_prompt_id: Dict[str, Turn] = {}
    since_last_response: List[Turn] = []  # prompt turns created after the last response

    def new_turn(**kwargs: object) -> Turn:
        turn = Turn(index=len(turns) + 1, session_id=_session_of(events), **kwargs)  # type: ignore[arg-type]
        turns.append(turn)
        return turn

    for ev in events:
        if ev.kind == "signal":
            continue  # Phase 12.1: waiting signals are state, never part of a turn
        if ev.kind == "tool":
            owner = by_prompt_id.get(ev.prompt_id) if ev.prompt_id else None
            if owner is None and not ev.prompt_id:
                open_turns = [t for t in since_last_response if not t.responses]
                owner = open_turns[0] if len(open_turns) == 1 else None
            if owner is not None and link_events:
                owner.tools.append(ev)
            elif unlinked_tools is not None:
                unlinked_tools.append(ev)
            continue
        if not link_events:
            if ev.kind == "prompt":
                new_turn(prompt=ev)
            else:
                new_turn(link=LINK_NONE).responses.append(ev)
            continue
        if ev.kind == "prompt":
            owner = by_prompt_id.get(ev.prompt_id) if ev.prompt_id else None
            if owner is not None and owner.prompt is not None and owner.prompt.prompt_id == ev.prompt_id:
                # Same prompt_id as a captured request: an input injected into
                # that turn (task notification, subagent hand-back), not a new turn.
                owner.notifications.append(ev)
                continue
            turn = new_turn(prompt=ev)
            if ev.prompt_id:
                by_prompt_id.setdefault(ev.prompt_id, turn)
            since_last_response.append(turn)
            continue

        target: Optional[Turn] = None
        if ev.prompt_id and ev.prompt_id in by_prompt_id:
            target = by_prompt_id[ev.prompt_id]
            # Confirmed only if the prompt itself carries this id; a link
            # inferred by order is never upgraded by a later response.
            if target.prompt is not None and target.prompt.prompt_id == ev.prompt_id:
                target.link = LINK_PROMPT_ID
            target.responses.append(ev)
            since_last_response = [t for t in since_last_response if t is not target]
            continue
        if ev.prompt_id:
            pending = [t for t in since_last_response if not t.responses]
            if len(pending) == 1 and pending[0].prompt is not None and not pending[0].prompt.prompt_id:
                # The prompt event carried no prompt_id; order is the only link.
                target = pending[0]
                target.link = LINK_SEQUENCE
            else:
                # The prompt for this id was never captured (capture enabled
                # mid-turn, or the prompt event was lost). Do not guess.
                target = new_turn(link=LINK_NONE)
            by_prompt_id[ev.prompt_id] = target
        else:
            pending = [t for t in since_last_response if not t.responses]
            if len(pending) == 1:
                target = pending[0]
                target.link = LINK_SEQUENCE
            elif len(pending) > 1:
                target = new_turn(link=LINK_AMBIGUOUS, candidate_prompts=[t.prompt for t in pending if t.prompt],
                                  candidate_turns=[t.index for t in pending])
            else:
                previous = turns[-1] if turns else None
                continuation = bool(ev.stop_hook_active) or bool(
                    previous and previous.responses and previous.responses[-1].has_background_tasks
                )
                if previous is not None and previous.responses and continuation:
                    target = previous
                    target.continued_by_sequence = True
                else:
                    target = new_turn(link=LINK_NONE)
        target.responses.append(ev)
        since_last_response = []

    for turn in since_last_response:
        if not turn.responses:
            turn.trailing = True
    return turns


def _session_of(events: List[Event]) -> Optional[str]:
    for ev in events:
        if ev.session_id:
            return ev.session_id
    return None
