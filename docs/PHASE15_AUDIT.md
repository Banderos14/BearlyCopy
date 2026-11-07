# Phase 15 — Independent audit of Phases 14–14.2, defect register

Date: 2026-11-07. Auditor: Claude Opus 5.5 (Claude Code, on the owner's Mac).
Branch: `phase/15-mvp-readiness` (worktree `~/Projects/prompt-relay-phase15`),
from `develop` = `17844fe`. Companion files: [Git recovery](PHASE15_GIT_RECOVERY.md),
[test results](PHASE15_TEST_RESULTS.md), [MVP acceptance](PHASE15_MVP_ACCEPTANCE.md),
[handoff](PHASE15_HANDOFF.md), [next-chat prompts](PHASE15_NEXT_CHAT_PROMPT.md).

Legend for every claim below: **Auto** = verified by automated tests on this
Mac · **Mac** = verified on real macOS (not mocks) · **Mock** = verified with
mocks/injected state · **Owner** = needs the owner's interaction · **No** = not
verified.

## 1. Phase 14.2 claims, re-checked

| Claim (Phase 14.2 report) | Result |
|---|---|
| HEAD `17844fe`, source 0.6.0 | ✅ confirmed (`git rev-parse`, `plugin/prompt_relay/__init__.py`) |
| Installed app/plugin 0.4.1 | ✅ `~/Applications/Prompt Relay.app` 0.4.1 `0dffa80`; plugin cache 0.4.1 highest |
| XCTest 339 / 0 failed / 16 skipped | ✅ reproduced exactly (baseline run) |
| Swift Testing 123/123 | ✅ reproduced |
| Python 249+15 on 3.9 and 3.14 | ✅ reproduced (3.9.6 `/usr/bin/python3`, 3.14.0) |
| Debug / Release build | ✅ both BUILD SUCCEEDED; **but** 2 compiler warnings existed (now removed) |
| 20 tests in `Phase142Tests.swift` | ✅ 20; 4 of them were weak (§3) |
| `reviewProgress` separate from `EvidenceCheck.items(.notVerified)` | ✅ correct design, kept |
| Ticks persist across restart | ✅ for ticks; Not applicable was untested (now tested); **pruning defect D1** |
| `FailureBreakdown` separates command/test/build | ⚠️ partially: **D2** (piped/chained helpers counted as build/test failures) and grep exit 1 still shown as "command failed" |
| Two full Copy with Context rows at 330–568 pt | ✅ re-measured by the strengthened test (all 8 two-column heights actually measured) |
| Window links don't survive restart (ADR-028) | ✅ `PickedWindow`/bindings are memory-only; doc correction in 14.2 is right |

## 2. Confirmed defects (fixed in Phase 15)

### D1 · P1 · Review marks could vanish once 200 answers had marks
- **Symptom:** after more than 200 answers with a Review Checklist mark, a new
  tick (or Not applicable) could disappear immediately or after the next
  write; which older marks survived was random per launch.
- **Root cause:** `reviewChecks`/`reviewNotApplicable` setters pruned with
  `newValue.prefix(200)` on a Swift `Dictionary`. Dictionary order is the
  per-process seeded hash order, so this kept an arbitrary 200, not "the 200
  most recent" as the comment said.
- **Files:** `macos/Sources/PromptRelayKit/Presentation/EvidenceCheck.swift`.
- **Fix:** a recency list `reviewChecks.recent.v1` (UserDefaults, keys only,
  no text) updated on every mark; pruning keeps the most recently marked
  answers; entries from before Phase 15 rank as oldest, deterministically by
  key. No migration, no data rewritten until the user marks something.
- **Regression:** `Phase15Tests.testATickMadePast200MarkedAnswersIsKeptAndTheOldestAreDropped`,
  `…KeepingMostRecentFollowsTheOrder…`, `…RemarkingAnOldAnswer…`.
  Mutation (restore hash-order pruning) → 4 assertion failures. **Auto.**

### D2 · P1 · A clean build piped into grep was shown as "1 build failed"
- **Symptom:** the very common `swift build 2>&1 | grep -E "error|warning"`
  — a clean build makes grep find nothing and exit 1 — appeared in the
  Answer chip and the Copy with Context Commands row as **"1 build failed"**.
  Likewise `swift build && swift test` failing in the test step counted as a
  build failure; `pytest | tee log` as a test failure.
- **Root cause:** the Core labels a line by its *first* test/build part
  (`tools.command_kind`), but the exit code is the *last* part's.
  `FailureBreakdown` (14.2) trusted the label. Additionally the part splitter
  cut `2>&1` into a fake part "1" and split quoted `"a|b"`, so
  `grep -E "a|b" f` and `grep x 2>&1` were never recognised as grep.
- **Files:** `Presentation/FailureInspector.swift` (and the wording helper in
  `Notch/FailureViews.swift`).
- **Fix:** `FailureBreakdown` now has `buildsUnclear` / `testsUnclear` (the
  line's exit code belongs to another program — "1 build unclear") and a
  separate `likelyNotAnError` bucket (grep no-match, diff, `test` false —
  "1 likely not an error"), each named in the summary, none hidden; `total`
  still counts every non-zero exit. A quote- and redirection-aware
  `FailureInspector.segments` replaces the naive split. The Swift copy of
  the Core's prefix table is pinned to `tools.py` by a test.
- **Wording change visible to the user:** the Phase 8 fixture chip reads
  "5 observed · 1 build failed · 1 likely not an error · 3 checks left"
  (was "… · 1 command failed · …"). The real Phase 14.1 `plutil … | head`
  line stays "1 command failed" (its last program is `head`).
- **Regression:** 6 tests in `Phase15Tests` (D2 section). Mutation (exit
  always attributed to the label) → 7 assertion failures. **Auto.**
- **Not changed:** the Core and the Copy with Context text (it already lists
  each command with its exit code and the pipe caveat, and never says "build
  failed").

### D3 · P2 · `docs/SECURITY.md` said no Screen Recording permission is used
Wrong since Phase 9.4 (window snapshots). Rewritten §4: what uses the
permission, that the app never changes it, Debug/Release separate grants.

### D4 · P3 · Two compiler warnings in the Xcode/SwiftPM build
`EvidenceViews.swift` (`@ViewBuilder` with explicit `return`, added in 14.2)
and `IslandViews.swift` (unused `facts`). Removed; no behaviour change.

## 3. Weak tests in `Phase142Tests.swift` (strengthened)

| Test | Problem | Now |
|---|---|---|
| `testSingleRowFallbackWhenGenuinelyNothingElseFits` | asserted nothing (`XCTAssertNoThrow` on a struct literal) | `PairedRows.split` extracted as pure arithmetic; test checks two rows when room, < two rows (never two half rows) when tight, single-row card never padded, nothing negative |
| `testALaterPassingTestRunAfterAnEarlierFailureIsObservedNotClaimedAsFixed` | the wording check was only a comment | `FailureCard.laterText` extracted; asserts "exited 0", "not proof that the cause is fixed", no "fixed/resolved/recovered", earlier failure still counted |
| `testCopyWithContextShowsAtLeastTwoFullRowsWhenThePhysicalSpaceAllows` | `guard … else { continue }` could skip every height and pass | asserts the measured heights are exactly 330…568 |
| `testVerificationSurvivesCloseReopenDetailsToggleAndRestart` | only the tick; Not applicable never restarted; "close/reopen" is only navigation | adds progress count and Not applicable across a second restart. Real panel close/reopen remains **Owner** |
| `testAnswerTaskAttachmentsAndContextPackSizesAreUnaffected` | only checks Task = Copy with Context height | left as is (weak but true); Phase 14 layout suites cover the rest |

## 4. Subsystem audit summary

| Area | Findings | Evidence |
|---|---|---|
| Hook handler | stdout empty and exit 0 for empty, non-JSON, array, missing session id; traversal-shaped session id stored under a hashed name; storage failures logged without text; no network imports in Core; no subprocess in hook/store | Python 249+15 ×2 **Auto**; probe in isolated data dir **Mac** |
| Verbatim capture | 300 KB Cyrillic + emoji + two code fences + CRLF/tab: `copy --stdout` byte-identical | probe **Mac** |
| StopFailure / Stop semantics | StopFailure stored as API error, Stop never "succeeded"; EvidenceCheck always lists "Stop means Claude stopped…" | existing tests **Auto** |
| Opt-in / plugin-first | capture only in enabled projects (`project_not_enabled` logged); app never writes Claude settings | tests **Auto**; code read |
| Sessions / profiles | per-profile session keys; per-ref review state; Needs Input ends on next confirmed activity | Phase 12/12.1/12.2 suites **Auto**; live waits **Owner** |
| Auto final screenshots | memory only, once per final answer, superseded when a newer answer of the same window arrives, skipped when another active conversation may share the window, permission denial ≠ closed window | Phase 14 suites **Mock**; live **Owner** |
| Screen Recording recovery | never reads "Settings opened" as granted; Check Again does one real discarded capture; mismatch → Restart required | Phase 14.1 suite **Mock**; System Settings pane **Owner** |
| Hover / resize corridor | not changed; suites pass | `Phase14HoverTests` **Mock**; real mouse **Owner** |
| Copy / clipboard | Copy Response verbatim; secret warning before context export; no delivery claimed | existing suites **Auto** |
| Attachment picker | see §5 | code read |
| Logging / diagnostics | app has no `print`/`NSLog`/`Logger`; `handler.log` holds time, event, outcome only | grep + probe |
| Git exposure | 76 unpushed commits scanned before pushing: only a synthetic `sk-ant-…xxxx` test string, the author email, and the repo path; PNGs are synthetic renders; repo is **private** | scan |

## 5. Attachment picker ("a file was selected")

Code facts (`LiveFilePicker`, `chooseFiles`, `chooseAttachments`,
`ReportStore.addFile/addAttachment`, `ReportAttachment.isSelected`):
1. The picker is the system `NSOpenPanel` with no `directoryURL`: macOS
   reopens the last folder and **highlights the file chosen last time**.
   Nothing is attached until the user presses **Add**.
2. The target report is captured when 📎/Files… is clicked, so a new answer
   arriving while the dialog is open cannot redirect the file to another
   session. Cancel attaches nothing.
3. A file that *is* added starts **chosen to send** (`selected ?? true`),
   which shows as the checked box in Attachments — that is "will be handed
   over", not "selected in a list".
Verdict: **not a defect**; the highlight is macOS behaviour and the checked
box is the hand-off choice. Possible P3: open the panel in the project
folder and label the box "Send". Owner check: MVP acceptance item 33.

## 6. Suspected risks (not fixed — no reproduction)

| ID | Sev. | Risk | How the owner can verify |
|---|---|---|---|
| R1 | P2 | Any non-permission capture error (`.failed`, `.noImage`) unlinks the window as "no longer available". A minimized window or a window on another Space might hit this and lose its link. | Link a window, minimize it, finish a Claude answer; see whether the link survives (acceptance 16) |
| R2 | P2 | `EvidenceCheck.Claims` is literal phrase matching (EN/RU); unusual phrasing is missed (no "Task outcome unknown" line). Never upgrades anything, only misses a warning. | Read the chip on a few real answers |
| R3 | P2 | Phase 12.1 question/plan/permission waits were documented, partly observed live (12.2); not every host/version observed. | Acceptance 8 |
| R4 | P3 | Swift copy of the Core's command-kind table (now guarded by a test). | — |

## 7. Not done in Phase 15 (out of scope or needs consent)
Installing 0.6.0 (app or plugin), merging to `main`, deleting
`claude/loving-mccarthy-ossw3q`, any release/tag, any live GUI/mouse/permission
check, any ChatGPT paste.
