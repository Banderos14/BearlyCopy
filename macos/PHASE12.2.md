# Phase 12.2 — First-interaction Drag, native focus, live acceptance

2026-11-06. Start: HEAD `643f27b`; installed app and Claude Code plugin
0.4.1. Neither was replaced in this phase. No push, merge, tag or release;
staged `REPORT.md` and acceptance files untouched; no hooks, credentials,
trust records or other apps' settings changed.

Categories: **Automated passed** · **GUI live passed** (real app/events on
this Mac) · **Requires owner** · **Environment blocked**.

## 1. Why Drag failed on the first try

The island opens on hover **without becoming key** (`expanded(focused:
false)`, `NotchPanel` is a non-activating panel). The Drag control
(`FileDragButton` → `FileDragSource.DragView`, an AppKit `NSDraggingSource`)
overrode only `mouseDragged`. `acceptsFirstMouse(for:)` kept AppKit's
default `false` (measured: `NSView` and `NSHostingView` both `false`), so
AppKit used the first press to make the panel key and did not deliver that
press sequence to the view: no `mouseDragged`, no drag. The second attempt
worked because the panel was key by then.

Reproduced through the real `NotchPanel.sendEvent` before the fix: attempt
1 → 0 drag sessions (panel became key), attempt 2 → 1 session. SwiftUI
buttons in the same non-key panel already fired on the first click
(measured), so the defect was local to the drag source.

## 2. The fix (only the drag source)

`FileDragSource.DragView` (`Notch/DetailsViews.swift`):
- `acceptsFirstMouse(for:) → true` — the first press reaches the drag source;
- `shouldDelayWindowOrdering(for:) → true` — the press does not reorder or
  activate before the drag (standard for drag sources in inactive apps);
- a 3 pt movement threshold — a click is never a drag, hand jitter is ignored;
- one session per press; state reset when the session ends (drop, or Esc).

Click handling elsewhere is unchanged: the hosting view still answers
`acceptsFirstMouse == false`, buttons and menus behave as before (tested).

## 3. First drag with an inactive window

| Check | Result |
|---|---|
| Non-key `NotchPanel`, first press + move on Drag → session starts | **Automated passed** (real panel event path; session recorded, not started) |
| Click without movement / 1–2 pt jitter → no drag | Automated passed |
| Repeated drags after drop and after Esc, panel non-key each round | Automated passed |
| A SwiftUI button still fires on the first click | Automated passed |
| Empty selection → nothing | Automated passed |
| Real drag from the notch into ChatGPT/Claude.ai/Finder with another app in front, fast/slow, after Details/Inbox, external display, no stuck preview | **Requires owner** — no GUI driver can produce a real cross-app drag here |
| SwiftUI `.onDrag` rows (an attachment row in Details, the Preview image, Clipboard images) | **Requires owner** — they use SwiftUI's own drag path, which cannot be recorded in a test; the explicit **Drag** buttons (fixed) cover the same items |

## 4. What is dragged

Automated passed (`testDragOffersFilesAndInMemoryImagesWithoutWritingThem`,
real `ReportStore`): a Markdown file and a PNG file go as **file URLs**
(hand-off copies); an **in-memory window snapshot** goes as image data on a
pasteboard item **without a file URL**; no PNG was written. Whether the
receiving app accepts a file URL or image data is the receiver's choice
(Phase 10/11 notes: data-only items do not paste into Finder).

## 5. Needs Input — real events (Claude Desktop, this Mac, plugin 0.4.1)

From this very Claude Desktop session (capture enabled), metadata only:

| Sequence | Real records | Result |
|---|---|---|
| AskUserQuestion → answered → Working | 06:06:18 PreToolUse AskUserQuestion · 06:06:19 PermissionRequest AskUserQuestion · 06:06:25 Notification permission_prompt · 06:10:08 PostToolUse AskUserQuestion · Bash results | **GUI live passed** |
| ExitPlanMode → approved → Working | 06:24:16 PreToolUse ExitPlanMode · PermissionRequest ExitPlanMode · 06:24:22 permission_prompt · 06:26:41 PostToolUse ExitPlanMode | **GUI live passed** |
| PermissionRequest → Allow → Working | 06:26:47 PermissionRequest Bash · 06:26:53 PostToolUse Bash; `attention` read while the command ran: open; afterwards: none | **GUI live passed** |
| PermissionRequest → Deny | not produced | Requires owner |
| Two sessions, one waiting, one working | not produced | Requires owner (Automated passed with synthetic data) |
| Cancelled question / May Need Input | not produced | Requires owner (Automated passed) |

**Defect found from the real sequence and fixed:** Claude Desktop sends a
`PermissionRequest` for AskUserQuestion and ExitPlanMode themselves, and
then `permission_prompt`. The Core let those replace the wait's kind, so a
question would have shown as "Permission required". Now a permission signal
inside an open question/plan wait keeps its kind and only refreshes
`last_signal_at` (`api.attention`, regression tests). This fix is in the
checkout; the **installed** app still has the old Core until reinstalled.

Also learned: `PostToolUse` does fire for AskUserQuestion and ExitPlanMode
(undocumented). `PermissionRequest` carries no `tool_use_id` (as documented).
Recorded in `docs/HOOKS_RESEARCH.md`.

## 6. The two scroll-wheel tests

Claim verified: on 2026-11-06 ~05:30 Z both failed with the screen locked
and the displays asleep (`CGSessionCopyCurrentDictionary`
`CGSSessionScreenIsLocked = 1`, `CGDisplayIsAsleep = true`), identically on
the unchanged `f8a7f9a` (temporary worktree). With the screen unlocked both
passed. They now call `requireLiveScreen()` and **skip** with "Environment
blocked: the screen is locked/asleep" instead of failing; no timeout was
changed. Status: **Automated passed** (unlocked), Environment blocked when
locked.

## 7. Automated runs (final code; logs in `macos/acceptance/phase12.2/`)

| Run | Result | Exit |
|---|---|---|
| Targeted Swift (Phase122/121/12, attachments/hand-off, Phase 10 snapshots, island layout, adaptive height, notch controller, Phase 9) | XCTest 57, 2 skipped (opt-in visual dump, real file dialog), 0 failures; Swift Testing 46/46 | 0 |
| Full `swift test` | XCTest **278**, 16 skipped (env-gated by design: visual dumps, audits, real paste, real dialog, perf), **0 failures**; Swift Testing **102/102**; prefs files 11,331 → 11,331 | 0 |
| `scripts/check.sh` Python 3.14.0 / 3.9.6 | 232 + 15 each, OK (1 skipped: Linux-only launcher case) | 0 |
| `xcodebuild` Debug / Release | BUILD SUCCEEDED | 0 / 0 |
| `git diff --check` | clean | 0 |

The opt-in timing test (`PROMPT_RELAY_TIMING=1`) is skipped in the default
run (Phase 12.1 §9: 15 ms measured alone and serially).

## 8. For the owner (≈ 15 min, after installing this commit)

1. Another app in front; hover the notch; Details → Attachments (or step 2
   of a hand-off) → press **Drag** and move at once into a ChatGPT/Claude.ai
   message box: it must start on the first try. Repeat: fast, slow, after
   closing and reopening, after Details and after the Inbox, on an external
   display; press Esc mid-drag; just click Drag (nothing happens).
2. Drag an in-memory window snapshot into a browser chat; then
   `find ~/Library/Application\ Support/PromptRelay -name '*.png' -newer /tmp/start`
   → nothing new.
3. Drag an attachment row and the Preview image (SwiftUI path).
4. Needs Input: Deny a permission → Claude stops → no stale amber; two
   sessions (one asks, one works); Esc on a question → after 30 min "May
   need input".
5. Quick Peek / Details, Inbox, Go To, shortcuts, Copy with Context, Copy
   Files still behave as before.

## 9. Git

Commits of this phase follow `643f27b`; see `git log` (code + tests, then
this report). Files: `Notch/DetailsViews.swift` (drag source),
`plugin/prompt_relay/api.py` (wait kind), tests `Phase122Tests.swift`,
`TestSupport.swift`, `IslandLayoutTests.swift`, `NotchControllerTests.swift`,
`tests/test_phase121.py`; docs `PHASE12.2.md`, `HOOKS_RESEARCH.md`,
`STATUS.md`.

## 10. Can Phase 12.1 / 12.2 be closed?

By code: yes — all automated checks green; the first-interaction drag defect
reproduced and fixed at its cause; three Needs Input sequences confirmed with
real events. Formally: after the owner installs this commit (the
question-kind fix needs the new Core in the app) and runs §8 — real
cross-app drags, Deny, two sessions and a cancelled question are not
verified live.
