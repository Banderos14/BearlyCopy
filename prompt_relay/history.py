"""Read-side model: sessions and turn selection for the CLI (and later the UI)."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import List, Optional, Tuple

from prompt_relay.correlation import Turn, build_turns
from prompt_relay.events import Event, from_record
from prompt_relay.store import NO_SESSION_KEY, SessionFile, Store, session_key


class SelectionError(Exception):
    pass


@dataclass
class Session:
    key: str
    session_id: Optional[str]
    events: List[Event]
    turns: List[Turn]
    corrupt_lines: int = 0
    unsupported_lines: int = 0
    foreign_lines: int = 0  # records whose session_id does not belong to this file
    cwds: List[str] = field(default_factory=list)

    @property
    def project_dir(self) -> Optional[str]:
        for ev in reversed(self.events):
            if ev.project_dir:
                return ev.project_dir
        return None

    @property
    def project_name(self) -> str:
        pd = self.project_dir
        return os.path.basename(pd.rstrip(os.sep)) if pd else "(unknown project)"

    @property
    def first_at(self) -> str:
        return self.events[0].received_at if self.events else ""

    @property
    def last_at(self) -> str:
        return max((ev.received_at for ev in self.events), default="")


def load_session_file(store: Store, sf: SessionFile) -> Session:
    result = store.read_path(sf.path)
    events: List[Event] = []
    foreign = 0
    for rec in result.records:
        ev = from_record(rec)
        if ev is None:
            continue
        # Never let a stray line from another session join this one.
        if session_key(ev.session_id) != sf.key:
            foreign += 1
            continue
        events.append(ev)
    session_id = next((ev.session_id for ev in events if ev.session_id), None)
    cwds: List[str] = []
    for ev in events:
        if ev.cwd and ev.cwd not in cwds:
            cwds.append(ev.cwd)
    return Session(
        key=sf.key,
        session_id=session_id,
        events=events,
        # Events without a session id may come from different sessions.
        turns=build_turns(events, link_events=sf.key != NO_SESSION_KEY),
        corrupt_lines=result.corrupt_lines,
        unsupported_lines=result.unsupported_lines,
        foreign_lines=foreign,
        cwds=cwds,
    )


def load_all(store: Store) -> List[Session]:
    sessions = [load_session_file(store, sf) for sf in store.session_files()]
    sessions = [s for s in sessions if s.events or s.corrupt_lines or s.unsupported_lines or s.foreign_lines]
    sessions.sort(key=lambda s: s.last_at, reverse=True)
    return sessions


def _same_or_under(path: Optional[str], root: str) -> bool:
    if not path:
        return False
    a = os.path.realpath(path)
    return a == root or a.startswith(root.rstrip(os.sep) + os.sep)


def filter_sessions(sessions: List[Session], session: Optional[str] = None, project: Optional[str] = None) -> List[Session]:
    result = sessions
    if project:
        root = os.path.realpath(os.path.expanduser(project))
        result = [s for s in result if _same_or_under(s.project_dir, root)]
    if session:
        exact = [s for s in result if s.session_id == session]
        if exact:
            return exact
        matches = [s for s in result if s.session_id and s.session_id.startswith(session)]
        if len(matches) > 1:
            raise SelectionError(f"session prefix '{session}' is ambiguous ({len(matches)} sessions)")
        result = matches
    return result


def select_turn(
    sessions: List[Session],
    session: Optional[str] = None,
    project: Optional[str] = None,
    turn: Optional[int] = None,
) -> Tuple[Session, Turn, List[str]]:
    """Pick a turn. Returns (session, turn, warnings).

    Default: the most recent turn that has received a response event
    (Stop or StopFailure), across the filtered sessions. Newer turns that are
    still awaiting a response are reported as warnings, never skipped silently.
    """
    candidates = filter_sessions(sessions, session=session, project=project)
    if not candidates:
        raise SelectionError("no captured sessions match the selection")
    warnings: List[str] = []
    if turn is not None:
        if len(candidates) > 1 and session is None:
            raise SelectionError("--turn requires --session when several sessions match")
        sess = candidates[0]
        if not 1 <= turn <= len(sess.turns):
            raise SelectionError(f"session has {len(sess.turns)} turn(s); --turn {turn} is out of range")
        return sess, sess.turns[turn - 1], warnings

    best: Optional[Tuple[Session, Turn]] = None
    for sess in candidates:
        for t in reversed(sess.turns):
            if t.responses:
                last = t.responses[-1].received_at
                if best is None or last > best[1].responses[-1].received_at:
                    best = (sess, t)
                break
    if best is None:
        raise SelectionError("no response has been captured yet for the selection")
    sess, chosen = best
    newer = [t for t in sess.turns[chosen.index:] if not t.responses]
    if newer:
        warnings.append(f"{len(newer)} newer prompt(s) in this session have no response yet")
    return sess, chosen, warnings
