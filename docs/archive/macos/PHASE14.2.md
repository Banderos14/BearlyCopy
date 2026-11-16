# Phase 14.2 — accurate verification, failure classification, compact Copy with Context

Start: `e3bc4d2` on `claude/loving-mccarthy-ossw3q` (0.6.0 in the tree, not
installed; installed app 0.4.1, plugin 0.4.1; Debug and Release copies both
running throughout, neither touched).

Three real bugs the owner hit using Prompt Relay itself, confirmed from this
session's own captured data (Prompt Relay was capturing this very Claude
Code session, `f2f91e98-c435-435e-85dc-cba4baccbb0e`, turn 4 = the Phase 14.1
report) before any code was changed.

## 1. "4 not verified" ignored two manual checks

**Root cause.** `EvidenceCheck.summary` (the Answer card's chip,
"N observed · N failed · N not verified") and `ReviewChecklist` (the four
checkable items in Evidence & Review, each with its own `isReviewChecked`
tick) are two unrelated structs. The chip's "not verified" count came only
from `EvidenceCheck`'s own fixed claim-rules ("the answer says tests pass,
no passing test observed", "Stop ≠ succeeded", …) — ticking a
`ReviewChecklist` box never touched it, by construction, regardless of how
many of the four items were checked.

**Fix.** Two counts, kept apart everywhere:
- `EvidenceCheck.items(.notVerified).count` — claims Evidence Check itself
  could not confirm. Unchanged in meaning; now also shown with its own
  number in Evidence & Review's "Not verified" section header.
- `AppModel.reviewProgress` (new, `ReviewProgress`) — the user's own
  checklist progress: `total`, `resolvedCount` (checked **or** marked Not
  applicable), `remaining`, and `summary` ("N checks left" /
  "All checks completed"). Recomputed live from `reviewChecklist` +
  `reviewCheckState`; nothing cached, nothing stale.

The Answer chip (`EvidenceChip.combinedSummary`) now reads
"N observed · <failures by kind> · N checks left" — both halves visible,
neither merged into the other. Tapping it still opens every claim and every
checklist item, each labelled with its own state.

**"Checked by you" stays "Checked by you".** Verified (`testCheckedByYouNeverBecomesConfirmedLocally`):
ticking a checklist item never adds a row to `TrustSummary`'s "Confirmed
locally" group; it stays in "Needs verification", labelled "Checked by
you · <reason>". Prompt Relay never re-runs anything and never promotes a
tick into a fact.

**Pending / Checked by you / Not applicable.** Evidence & Review's checklist
rows and the "What can be trusted?" card now show the word explicitly
(`ChecklistRow`, `TrustCard.line`), not just an empty/filled box. The CI
item (`ReviewChecklist.Item.allowsNotApplicable`) is the only one offering
Not applicable, via a small menu instead of a checkbox — ticking it never
counts as "CI passed": `isReviewChecked("ci")` stays false; only
`reviewProgress` treats it as resolved. Checked and Not applicable are
mutually exclusive (setting one clears the other).

**Persistence, independence.** Existing storage was already correct
(`reviewChecks[ref.key]`, keyed per local session + turn, which Phase 12
already scopes per profile even when native session ids collide) — verified,
not changed: close/reopen, Details↔back, project switch, app restart
(new `AppModel` reading the same `stateDefaults`), two profiles with equal
native ids. A new "Not applicable" dict (`reviewChecks.notApplicable.v1`)
follows the same per-ref, 200-most-recent-answers storage pattern.

## 2. What "1 failed" actually meant

**Confirmed from real data**, not assumed: `bin/prompt-relay show --session
f2f91e98-c435-435e-85dc-cba4baccbb0e --turn 4 --json` — the one command with
`exit_code: 1` is

```
plutil -p .../SecurityPrivacyExtension.appex/Contents/Info.plist 2>/dev/null | grep -iE "..." ; echo "---"; grep -il "screen" .../en.lproj/*.strings 2>/dev/null; strings .../PrivacySecurity.searchTerms 2>/dev/null | grep -i "screen" | head -10
```
`kind: "other"`, `compound: true` (a `;`-chain: a zsh glob-expansion failure
on the `*.strings` part aborted the line, not a test or build). Every
`kind: "build"` (×4) and `kind: "test"` (×2) command in that turn exited 0.
So "1 failed" was a diagnostic shell call unrelated to the build or tests
the answer referenced — the UI just never said so.

**Fix: `FailureBreakdown` (`FailureInspector.swift`)** — classifies each
failing command (`FailureInspector.isFailure`) by its recorded `kind`:
`commandsFailed` (neither test nor build), `testsFailed`, `buildsFailed`,
plus `likelyNotAnError` (the existing grep/diff/test/which non-match
heuristic). `.summary` names each kind that actually failed, builds first,
then tests, then commands — never collapsed into one "N failed". When only
the aggregate counts are known (no per-command detail loaded yet),
`.fromAggregate(_:)` reports it as generic commands, never guessed as a
test or build. Wired into:
- `HandoffContentsCard.commands(_:captureOn:detail:)` (the Commands row in
  Copy with Context): "1 command failed" instead of bare "1 failed", or,
  with the real example reproduced in `Phase8Fixture`, "1 build failed ·
  1 command failed".
- `EvidenceCheck.summary` (the chip).

**Task outcome unknown.** New `EvidenceCheck` rule: the answer claims the
work is "done"/"working" with neither a passing test nor a successful build
observed (and no separate tests/build claim already covering it) adds
"Task outcome unknown: the answer says it is done, but no test or build
command confirms it" to Not verified — named, not silently absent.

**Not touched, confirmed still correct:** `FailureInspector`'s existing
per-command detail (`FailureCard` — command, exit code, duration, time,
pipe/chain caveat, output tail if safe, a later same-command/same-tool run
with its own exit code and the explicit "not proof the cause is fixed"
line, unavailable fields) already matched every UI requirement in Part II §5;
nothing there needed to change.

## 3. Copy with Context: two full rows when there is room

**Root cause, found by rendering, not arithmetic**
(`IslandHost` + real `layoutFrames`, `Phase8Fixture`'s 5-row scenario):
`PairedRows`' top-row cap (`topCap = max(natural(0, left), budget * 0.32)`)
used **only Task's own natural height**, never the right card's. At common
compact heights (330–360 pt) Task's one-line natural height and 32 % of the
budget were both small (~80 pt — measured, not assumed), while the *actual*
constraint protecting the Answer (`budget − spacing − minBottom`) had slack
left (~136 pt) that nothing was using. Copy with Context's own `BoundedScroll`
(Phase 14) correctly snapped to 1 row + "+4 more" inside whatever it was
given — the card behaved correctly; it was given too little.

**Fix.** `PairedRows` gained `rightMinRows` / `rightRowHeight` /
`rightRowSpacing` (0 by default — no behavior change for other callers).
When set, the top-row cap also floors at enough height for `rightMinRows`
rows of the right card, with the "chrome" (header + padding) derived from
the right card's own already-computed `smallest()` measurement minus one
row height — no new magic constant, no guess at Copy with Context's
internals from outside. The floor never exceeds the right card's own full
natural height (fewer real rows never get padded out) and is still capped
by the existing Answer-protection term, so a genuinely tiny budget still
falls back to one row + "+N more", never two half ones. Details' call site
passes `rightMinRows: 2` using `HandoffContentsCard`'s own `rowHeight`/`rowSpacing`.

**Measured, before and after** (`Phase8Fixture`, 5 rows: Request & answer,
Commands, Files changed, Git status, Attachments):

| height | rows visible, before | rows visible, after | island height |
|---|---|---|---|
| 330 pt | 1/5 ("+4 more") | 2/5 ("+3 more") | 362 pt (unchanged) |
| 341 pt | 1/5 | 2/5 | 373 pt (unchanged) |
| 360 pt | 1/5 | 2/5 | 392 pt (unchanged) |
| 388–448 pt | 2/5 (already) | 2/5 | unchanged |
| 500–568 pt | 3/5 (already) | 3/5 | unchanged |

The island's own height is identical before/after at every size: this
redistributes the existing budget between Task and Copy with Context,
never grows the window. The Answer card (`card.response`) stayed ≥ 130 pt
at every size (`minBottom` protection intact). No half-visible rows at any
height (every row frame is wholly inside its viewport or wholly below it —
asserted, not assumed). Content order, Copy with Context's actual export
text, and Context Pack were not touched — this is presentation only.

## 4. Verification

**Automated, passed:** XCTest 339/0 (16 opt-in skips, +20 new in
`Phase142Tests`), Swift Testing 123/123, Python 249+15 ×2 (3.14, 3.9),
Xcode Debug and Release build, `git diff --check` clean — see `docs/STATUS.md`
for the exact run. A mutation check on both new mechanisms (collapsing the
failure-kind switch; dropping `PairedRows`' new floor) makes the relevant
tests fail (14 and 1 respectively), confirming they exercise the real logic,
not just re-assert the implementation.

**Offscreen, passed:** `IslandHost` real AppKit/SwiftUI layout at 268, 300,
330, 341, 360, 388, 410, 448, 500, 568 pt, Task/Answer/Attachments sizes
compared against the unmodified Phase 14 fixture (unaffected). Hover-resize
(`NotchController`'s corridor protection, Phase 14.1) was not touched this
phase; its own suite (`Phase14HoverTests`, 8 tests) still passes unchanged —
confirmed by re-running it, not by assumption.

**Requires owner (live GUI):** everything already listed in
`ACCEPTANCE_PHASE14.md` and `ACCEPTANCE_PHASE141_PERMISSION.md` (mouse
behavior, the real System Settings pane, Screen Recording grant/restart,
ChatGPT paste/drop) — none of that changed this phase. New, short checklist
for this phase's own changes: `ACCEPTANCE_PHASE14.2.md`.

**Documentation fix.** `ACCEPTANCE_PHASE141_PERMISSION.md` step 7 claimed the
window link survives a Quit & Reopen; ADR-028 and the code (`PickedWindow`,
`AutoCaptureLinksView`'s own "Links last until Prompt Relay quits") say
links are memory-only and never survive a restart. Corrected to expect
re-linking, not persistence.

## 5. Version

Stays **0.6.0** — not installed or published yet (per the owner's own
framing: 0.6.0 "ещё не опубликована"), so this is folded into it rather than
bumped, consistent with how Phase 14.1 (the hover-corridor fix) was folded
in rather than becoming 0.6.1. JSON API v1 and Context Pack format v1
untouched (nothing here changes either format).
