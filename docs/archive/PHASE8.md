# Phase 8 — audit, Living Relay 2.0, UI reliability, developer hand-off

Backup ref `refs/backup/phase8-start` (= `88df2d1`, the reported Phase 7.2
HEAD; confirmed). Branch `claude/loving-mccarthy-ossw3q`, tree clean at start.
Python Core, hooks and plugin: **unchanged**. Data formats: unchanged.

## 1. State before Phase 8 (checked, not assumed)
| Area | Implemented | Tested | Real data | Notes |
|---|---|---|---|---|
| Core (hook, store, correlation, JSON API) | yes | 172 Python tests, OK on 3.14 and 3.9.6 | Phase 1.5/2B Mac runs | not touched |
| Tool capture / exit codes / output tail | `tools.py`: tail only for failed tests/builds, secret-scanned | Python suite | yes | enough for Failure Inspector, no Core change |
| Island (Quick Peek, Details, routes) | yes | Swift layout tests at 341/448 | offscreen renders | **268-pt floor not checked before** → defect 4 |
| Tooltips | one in-island mechanism (`IslandTooltips`) | placement tests | — | defects 1–3, 5 |
| Copy with Context / Preview | always Full, one snapshot | yes | real pack audit (7.x) | Preview showed only the source |
| Persistent hand-off | per `ReportRef`, persisted, selection-change and missing-file guards | `AttachmentHandoffTests`, 7.1 tests | owner | reviewed, no change |
| Relay | `RelayMotion` + CA layers on a display link | bench | — | defect 6 |
| Report-ready indicator | a 6-pt accent dot when unseen | model tests | owner | no "working", automated turns look like new tasks |

Claims of 7.2 re-checked here: 59.5 fps on the bench (measured again, below),
Debug/Release build (built again), Standard/Full gone (confirmed in code).

## 2. Confirmed defects and causes (reproduced on real SwiftUI renders first)
1. **Evidence chip covered "View Full Report"** — the chip was an
   `.overlay` on the link's row, so it took no layout space. Fix: link and chip
   share a row when both fit (`ViewThatFits`), else the chip gets its own row.
2. **Tooltips too wide, with an empty strip on the right** — `TipTextLayout`
   used the full maximum as soon as text wrapped. Fix: the narrowest width that
   keeps the same line count (binary search on the measured height).
3. **Tooltips over Copy Answer / footer icons, touching the island edge** —
   placement knew only "below, else above" and a 14-pt side inset equal to the
   island's visible edge. Fix: candidates below / above / above-or-below the
   whole row / beside, scored by how much of *other registered controls* they
   cover (row neighbours ×12), fitting candidates first; 20-pt side inset.
   Long help texts shortened.
4. **At the 300-pt island floor the footer ended 3 pt past the island**
   (one-column Details). Fix: on displays under 300 pt of content the Task is
   one inline row; the Answer row never gets less than its fixed rows.
5. **Black box over Observed Work's file list** — reproduced exactly: a
   command withheld by the secret scan has no text, so its row's tip was `""`
   and the overlay drew an empty black background (14 × 21 pt) under the row.
   Fix at the root: a blank tip is never registered or shown; the row now says
   why its command is withheld. Regression test `testBlankTipIsNeverShown`.
6. **Relay barely reacted to vertical movement** — `gaze.y = tanh(dy/160)`
   per axis; Relay is at the top, the pointer is 200–900 pt below it, so `y`
   stayed 0.96–1.0. Fix: below.
7. Found by the full run: the new ear parallax lifted the ears 0.25 pt above
   the screen in the notch ear when looking down; fixed (ears move only when
   looking up). `RelayRestingTests` guards it.

## 3. Living Relay 2.0 (same bear, same Core Animation architecture)
- Gaze = *direction* to the pointer × `tanh(distance/170)`, measured from a
  point 90 pt below Relay (so the menu bar reads as "up"). Continuous, no
  thresholds; on Relay itself it fades to looking at you (no jitter).
- Up/down drawn as clearly as left/right: pitch parallax 0.06 → 0.085, eyes
  move more vertically, eyes flatten slightly, muzzle squashes more, ears drop
  back when looking up, the open-band head nods fully.
- Eyes lead (exponential), head follows on its spring, ears lag (now also on
  nods). Expressive: livelier spring (ω 13.5, ζ 0.64; overshoot measured
  higher than Subtle, still < 12 %), more ear swing. Subtle unchanged.
- New small reactions: a nod on a new answer; a perk when the pointer lands on
  Relay (≤ once per 4 s); an occasional look up as an idle moment. The copy
  hop (Copy Answer / Copy with Context) is kept. Off / Reduce Motion: all
  reactions gated as before.
- Render sheet `p8-relay-pointer-sheet.png`: 7.2's middle and bottom rows are
  identical; Phase 8's change with height.

### Frame pacing (bench: the real panel in the test process, synthetic pointer at 120 Hz, built-in 120 Hz ProMotion display reported; load average ≈ 5, WindowServer ≈ 45–52 %)
| Run | fps moving | interval p50 / p95 / p99 / max | > 25 ms | CPU moving* | CPU rest | frames at rest | RSS |
|---|---|---|---|---|---|---|---|
| 7.2 code, today | 59.5 | 16.64 / 19.30 / 20.56 / 21.3 ms | 0 / 595 | 9.3 % | 0.64 % | 0 in 2 s | 56 MB |
| Phase 8, Subtle | 60.0 | 16.67 / 20.34 / 22.27 / 23.7 ms | 0 / 600 | 8.7 % | 0.86 % | 0 in 2 s | 56 MB |
| Phase 8, Expressive (run 1) | 59.9 | 16.67 / 18.68 / 24.76 / 65.8 ms | 4 / 599 | 10.1 % | 0.45 % | 13 (a blink) | 55 MB |
| Phase 8, Expressive (run 2) | 60.2 | 16.67 / 16.81 / 19.30 / 22.3 ms | 0 / 602 | 10.6 % | 0.70 % | 13 (a blink) | 55 MB |

\* includes the bench's own pointer loop, 2.1–4.4 % (measured with Relay off).
The 4 long intervals of Expressive run 1 did not repeat. **Bench, not the live
app**; 60 Hz external display vs ProMotion on the live screen: owner check.

## 4. Failure Inspector
`FailureInspector` (pure, tested) + `FailureSection` at the top of Observed
Work, opened from "N failed" in Copy with Context, the Quick Peek fact and
the Commands row. Per command that did not exit 0: command text (or why it was
withheld), time, exit code, duration, the stored last lines (failed test/build
only, after the Core's secret scan), what that exit code usually means (grep/rg
exit 1 = no match, diff, `test`, 126/127/130/137/143, test vs build), caveats
for pipes/`;`/`||`/`&` and `&&` chains, after-Stop and subagent runs, a later
run of the *same command* or *same test/build tool* with its exit code ("an
exit 0 is what was observed, not proof that the cause is fixed"), and what was
not recorded. Nothing is re-run, nothing is called fixed, no new data is
captured.

## 5. Report Ready indicator (right ear)
`AppModel.readyIndicator`: `.ready(sessions, automated, backgroundPending)`
— a small light dot, a ring when Claude Code started that turn itself, an
amber ring if background work was still running, a count when several sessions
have unseen answers; `.working(sessions)` — three dim dots while a prompt
waits for Claude (only if active in the last 20 min: an interrupted turn
never gets a Stop). Opening the island marks it seen and opens the newest
answer's session (existing `revealReadyAnswer`). No "done"/"success" wording.
One soft scale-in, no looping animation. "Automated" is known only when that
session's turns are loaded (no extra Core call); otherwise shown as a normal
answer.

## 6. Copy with Context
- Preview: **Formatted** and **Markdown Source** over the same `BuiltPack`
  snapshot; switching never rebuilds; Copy copies the source. Sections jump in
  both views. Formatted is lazy: first layout 68 / 68 / 72 / 84 ms for
  10k / 30k / 100k / 300k characters (test machine).
- ⓘ explanations: every row answers *What · Source · Checked here · Not
  known*, inside the card (no overlay). "Files changed" says the files were
  not opened or compared.

## 7. Verification
| Check | Result |
|---|---|
| Swift tests (full) | 269 run, 0 failures, 16 opt-in skipped (renders, perf bench, real-data audits, real panel, paste kit). First full run found defect 7; fixed, rerun green |
| Python 3.14.0 / 3.9.6 | 172 OK each, 1 skipped by design; hook median 38.6 ms |
| Xcode Debug / Release | BUILD SUCCEEDED (no code warnings) |
| Renders | offscreen renders of the real views; not screenshots of the running app |
| On the live screen | **Not verified** (owner) |

## 8. Owner checks on the Mac
1. Quit old copies, build Debug. Hover Copy Answer, Copy with Context, View
   Full Report, History, ⋯: tips are short, inside the island, not on buttons.
2. An answer with a failed command: "View Full Report" and the Evidence chip
   do not touch; click "1 failed" in Quick Peek → Failure Inspector.
3. Move the pointer slowly from the menu bar to the bottom of the screen:
   Relay's eyes and face go from up to down; Settings → Relay → Expressive.
4. Send Claude a prompt: three dim dots right of the notch while it works,
   a light dot when it stops; open the island → the dot goes.
5. Preview → Formatted / Markdown Source → Copy → paste: the source text.
