"""History management: plan, preview and execute deletion of session files.

Rules (docs/ARCHITECTURE.md, "History management"):
- Granularity is a whole session file; lines are never rewritten.
- Nothing is deleted automatically. ``plan_*`` only reads; ``execute`` is
  called by the CLI only with an explicit ``--yes``.
- Only plain ``*.jsonl`` files directly inside events/ can be deleted
  (``Store.safe_unlink`` re-checks this under the file's exclusive lock).
  Symlinks are never followed; config, logs and anything else stay.
- A session is *active* when its last activity (the later of its last event
  and its file modification time) is less than ``ACTIVE_GRACE_S`` ago. Active
  sessions are kept unless the caller forces it; ``prune`` never forces.
- Age uses the same "last activity" value. Touching a file therefore only
  ever delays deletion; it can never cause it.
- A file that changed between planning and execution is kept ("changed").
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import List, Optional

from prompt_relay.history import SelectionError, Session, filter_sessions, load_session_file
from prompt_relay.store import SessionFile, Store, StoreError

ACTIVE_GRACE_S = 30 * 60
DAY_S = 24 * 60 * 60

WOULD_DELETE = "would_delete"
DELETED = "deleted"
SKIPPED_ACTIVE = "skipped_active"
SKIPPED_CHANGED = "skipped_changed"
SKIPPED_UNSAFE = "skipped_unsafe"
VANISHED = "vanished"
FAILED = "failed"


@dataclass
class Item:
    file: SessionFile
    session: Session
    last_activity_epoch: float
    action: str
    reason: str = ""

    @property
    def active(self) -> bool:
        return self.action == SKIPPED_ACTIVE


@dataclass
class Plan:
    kind: str  # "prune" or "delete"
    now: float
    older_than_days: Optional[int] = None
    session: Optional[str] = None
    all_sessions: bool = False
    force_active: bool = False
    items: List[Item] = field(default_factory=list)

    @property
    def cutoff_epoch(self) -> Optional[float]:
        return None if self.older_than_days is None else self.now - self.older_than_days * DAY_S

    def count(self, *actions: str) -> int:
        return sum(1 for it in self.items if it.action in actions)


def last_activity(sf: SessionFile, session: Session) -> float:
    event_epoch = session.last_event_epoch
    return max(sf.mtime, event_epoch if event_epoch is not None else 0.0)


def _item(sf: SessionFile, session: Session, now: float, force_active: bool) -> Item:
    activity = last_activity(sf, session)
    if now - activity < ACTIVE_GRACE_S and not force_active:
        minutes = max(0, int((now - activity) // 60))
        return Item(sf, session, activity, SKIPPED_ACTIVE,
                    f"last activity {minutes} min ago (< {ACTIVE_GRACE_S // 60} min); use --force-active to include")
    return Item(sf, session, activity, WOULD_DELETE)


def _load(store: Store):
    return [(sf, load_session_file(store, sf)) for sf in store.session_files()]


def plan_prune(store: Store, older_than_days: int, now: Optional[float] = None) -> Plan:
    if older_than_days < 1:
        raise ValueError("older_than_days must be >= 1")
    plan = Plan("prune", time.time() if now is None else now, older_than_days=older_than_days)
    cutoff = plan.cutoff_epoch
    for sf, session in _load(store):
        if last_activity(sf, session) >= cutoff:  # type: ignore[operator]
            continue  # not old enough: not part of the plan at all
        plan.items.append(_item(sf, session, plan.now, force_active=False))
    plan.items.sort(key=lambda it: (it.last_activity_epoch, it.file.key))
    return plan


def plan_delete(store: Store, session: Optional[str] = None, all_sessions: bool = False,
                force_active: bool = False, now: Optional[float] = None) -> Plan:
    """Raises history.SelectionError when ``session`` matches nothing or is ambiguous."""
    if not all_sessions and not session:
        raise ValueError("plan_delete needs a session or all_sessions=True")
    plan = Plan("delete", time.time() if now is None else now, session=session,
                all_sessions=all_sessions, force_active=force_active)
    loaded = _load(store)
    if all_sessions:
        chosen = loaded
    else:
        by_session = {id(s): (sf, s) for sf, s in loaded}
        matches = filter_sessions([s for _, s in loaded], session=session)
        if not matches:
            raise SelectionError(f"no captured session matches '{session}'")
        chosen = [by_session[id(s)] for s in matches[:1]]
    for sf, sess in chosen:
        plan.items.append(_item(sf, sess, plan.now, force_active))
    plan.items.sort(key=lambda it: (it.last_activity_epoch, it.file.key))
    return plan


def execute(store: Store, plan: Plan) -> Plan:
    """Delete every ``would_delete`` item; each outcome is recorded on the item."""
    for it in plan.items:
        if it.action != WOULD_DELETE:
            continue
        try:
            outcome = store.safe_unlink(it.file)
        except StoreError as exc:
            it.action = SKIPPED_UNSAFE if exc.code == "unsafe_path" else FAILED
            it.reason = exc.code
            continue
        if outcome == "deleted":
            it.action = DELETED
        elif outcome == "vanished":
            it.action, it.reason = VANISHED, "already removed"
        else:
            it.action, it.reason = SKIPPED_CHANGED, "written to since the plan was made; run again to re-check"
    return plan
