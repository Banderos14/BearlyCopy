# Phase 6 — UX redesign, Clipboard workspace, functional polish

Branch `claude/loving-mccarthy-ossw3q`, backup ref `refs/backup/phase6-start`
(= `7538a98`). Core, plugin, JSON API and stored data formats are unchanged;
only the macOS app (`macos/`) changed.

## 6.0 Audit: defects found in the code (with their cause)

| # | Defect the owner saw | Cause in the code | Fix |
|---|---|---|---|
| 1 | Full Report: Plain Text → Formatted breaks the view | `BoundedScroll` was re-created with height 0, so the island reported 93 pt, then 319 pt in the same layout pass. `NotchPresentation.reportContentHeight` compared 319 with the *not yet applied* height (still 319) and dropped it; the queued 93 pt won. Reproduced in the real panel: 373 → 125 pt with the text cut off | Compare with the last *request*; the reader uses one fixed viewport for both modes |
| 2 | Footer / step 2 over Response, View Full Report under text | Details sized its columns from estimated chrome heights; SwiftUI frames do not clip, so taller real content drew over the footer. The same 93-pt race hit every turn switch (the Response scroll was re-created per turn) | `HeightBudget` layout: the island offers its whole budget, header and footer take their size, scroll areas share the rest. Step 2 *replaces* the footer |
| 3 | Dark band at the bottom of History, Settings, lists | `BoundedScroll`'s fade mask (last 10 % to clear) | Mask removed |
| 4 | Step 2 of an old turn stays on another turn | `handoffStep` was never cleared; Copy Files re-read the *current* selection | Step bound to `ref` (project · session · turn, or import) and to the attachment IDs at the copy; cleared by any selection change and on close; a changed choice blocks the old set |
| 5 | Newest answer shown as 2/8 | Stepper counted newest first; the newest turn in the owner's real session was started automatically by Claude Code, so the user's latest was 2/8 | 1…N in time order, automatic turns counted and marked (real history: 7/8 user, 8/8 automatic) |
| 6 | Turn switch jumps | Same as 2 (scroll view re-created, height 0 → re-measure) | Scroll view kept across answers, height animates (0.22 s smooth), text cross-fades, island resize 0.24 s smooth, no bounce |
| 7 | Thumbnails sometimes blurry | Cache keyed by URL only (a 64 px thumbnail reused at 240 px) | Key = size + path |

## State transitions (what stays, resets, animates)

| Transition | Stays | Resets | Animates | Window |
|---|---|---|---|---|
| Resting → Quick Peek (hover) | selection | — | island opens (spring) | opens |
| Peek → Details (click) | selection, step 2 of the shown report | Task collapsed | width + height | stays open |
| Details → Full Report → Back | selection, copy state, step 2 | reader starts in Formatted | opacity | height fixed while in the reader |
| Full Report Formatted ↔ Plain | text, height | — | swap inside a fixed viewport | unchanged |
| Turn A → B (arrows, ←/→) | session, Task collapsed | step 2 of A ends | card heights 0.22 s, text fade, island 0.24 s | follows content |
| Session / project / import switch | — | step 2 ends; Task collapsed | as above | follows content |
| Copy for ChatGPT, no files | — | — | button shows "Copied!" 2 s | — |
| Copy for ChatGPT, files chosen | text on clipboard | — | footer → step 2 (fade) | — |
| Choice of files changed during step 2 | step 2 shown | Copy/Drag disabled | message + "Copy for ChatGPT Again" | — |
| Done | clipboard content | step 2 ends | footer back | — |
| Close the island during step 2 | files, attachments, clipboard | step 2 ends (next open: normal footer) | island closes | closes |
| Clipboard → Images, choose, Copy / Drag / Add | choice while the view is open | choice after Add | "Copied!" 2 s | — |
| Reduce Motion | everything | — | fades of 0.1 s only, no resizing animation | — |

UI state is never the clipboard: Done, closing and switching never clear
the system clipboard.

## What changed in the interface

- **Details**: Header (project · session, source) / Content (Task, Response
  | Copy for ChatGPT, Attachments) / Footer (Copy Response, Copy for ChatGPT,
  History · Clipboard · Settings icons, ⋯ menu with Import Report and Quit).
- **Task**: 1–2 lines; "More" expands it into its own scroll area (max
  132 pt); Task and Response scroll independently.
- **Quick Peek**: project · session and a state chip (New answer / Working /
  Stopped / API error), task line (person icon, or gears for an automatic
  turn), Claude's own first line, chips only for real facts ("1 failed run",
  "2× exit 0", "1 document", "3 images", "Visual review required"). Hovering
  a copy button explains what it copies. Step 2 opens right in Quick Peek.
- **Copy for ChatGPT card**: Task & Response, Commands & Checks (not captured
  / capture off / no tools used / N failed / N× exit 0 / N events), Changed
  Files, Git State ("read when you copy"), Attachments.
- **Clipboard** (replaces Recent Copies; menu bar "Clipboard"): Text — last 5
  copies, Copy Again (shows Copied!), remove one, Clear All. Images — last 5
  images, thumbnails, preview, choose several, Copy N (files with readable
  names such as `Screenshot 2026-10-30 at 10.12.04.png`), Drag N, Add N to
  Report, remove, Clear All, turn off. Uses the Phase 5 history (ADR-014);
  exported copies live in its folder and are removed by Clear All.
- **Image history default**: on, but only from the moment its one-time notice
  has been shown (Details or Clipboard), with OK / Turn Off. Owners who
  already chose on or off keep their choice.
- **Style**: tokens in `Island` (text, surfaces, accent teal, success,
  warning, error, review; spacing, radii, motion); cool graphite cards;
  no shadows or fades. Tooltips after 200 ms (app registration domain only).
- **Settings**: Capture, Clipboard, Appearance (notch + Relay + motion),
  Notifications, Privacy, Advanced (diagnostics), About.

Relay (the bear) is unchanged.

## Verification

| Item | Status |
|---|---|
| Swift `swift test` | **186 tests, 0 failures** (9 opt-in skipped) |
| Python `scripts/check.sh` (3.x + 3.9.6) | **168 OK** (1 skipped by design) |
| Layout recursion (`scripts/check-layout-recursion.sh`) | **0 hits** |
| Xcode Debug and Release | **BUILD SUCCEEDED**, 0 compiler warnings |
| Full Report switch in the real panel (offscreen test window) | height constant through 7 switches; text whole |
| No overlap: long/short answers, 6 files, step 2, 300/341/448 pt budgets | automated (`Phase6Tests`) |
| Real history rendered in the new views (read-only) | 4 real answers × 2 display heights, no overlap; order 5/8 … 8/8 |
| The running app on the real screen, Reduce Motion, external display | **Not verified** (owner) |
| Pasting files/images into ChatGPT Desktop / Safari / Chrome | **Not verified** (owner) |
| ⌃⇧⌘4 into the image history with macOS 27's paste prompt | **Not verified** (owner; the history is tested with a private pasteboard) |

## Owner checks (about 10 minutes)

1. Quit both running builds, rebuild in Xcode (Debug), open the island.
2. Details: long answer with files — nothing overlaps; step through answers
   with ‹ › and ←/→: numbers go 1…N, newest is N/N, heights change smoothly.
3. Full Report: Formatted → Plain Text → Formatted several times quickly.
4. Copy for ChatGPT with files → step 2 in the footer; switch turn → step 2
   gone; back, copy again, untick a file → "files changed".
5. The notice about images appears once; take 2–3 screenshots with ⌃⇧⌘4,
   open Clipboard → Images, choose two, drag them into ChatGPT; Copy 2 and
   paste. Tell me what arrived (V8).
6. Hover the icons: tooltips appear quickly; System Settings → Accessibility
   → Reduce Motion on: only short fades.

## Phase 6 polish (2026-10-31)

Backup ref `refs/backup/phase6-polish-start` (= `f1074db`). App only; the
Core (including its package heading "Copy for ChatGPT", see
`docs/PRODUCT_ROADMAP.md`) is unchanged.

| # | Defect | Cause | Fix |
|---|---|---|---|
| 1 | History: clicking the open session does not close it | Expansion *was* the selection; `focusSession` returns early for the selected session | `historyExpandedKey` by session key: open ↔ close, A → B closes A; refresh and search leave it alone |
| 2 | Answer switch still abrupt | While the new full text loaded, the card showed the short preview (16 pt in the test) and then the full text: two jumps. Task and Attachments changed without animation | Previous answer stays (dimmed) until the new one is ready; cards and island move on one curve: 280 ms `smooth` (Island.geometryDuration), text cross-fades 200 ms; the regression test fails with the fix removed |
| 3 | Tooltips sometimes, sometimes not | AppKit tooltips (`.help`) show only while the app is active; the island is a non-activating accessory panel | In-island tooltips: 180 ms, switch at once between neighbours, hidden on leave, click, close or view change, never hit-testable; accessibility hints kept |
| 4 | Copy confirmation not everywhere | Only the two main buttons used the global feedback | One token per copy, set only after the clipboard read-back (files are read back too); History, Clipboard Text and Images, step 2 all show "Copied!" for 2 s; the size (`6,126 chars`) appears beside the buttons only when it fits |

**Names.** Copy Answer / Copy for Review (central `Labels`); Import Saved
Result (it imports one pasted result, not a conversation); Attach to
Current Answer (its tooltip names the target answer; disabled with none).
Review card rows: Request & answer (original text), Commands (n failed / n
completed / none run / not recorded / capture off), Files changed, Git
status (checked when you copy), Attachments; "What's in it" explains each
part and its limits in place.

**Quick Peek.** The permanent explanation line is gone (it repeated the
tooltip). Facts in plain words, only when they exist: "1 failed command",
"3 commands completed" (exit 0 of a test/build command, never "passed"),
"2 files changed", "1 document".

**Themes** (Settings → Appearance → Theme; renders in
`docs/images/phase6-themes/`, real SwiftUI renders of the same fixture
content, not mock-ups): **Soft Spectrum** (default: lavender accent and
main button, mint success, amber, coral, lilac; tinted card captions),
**Material Calm** (M3-style tonal roles), **Classic** (Phase 6's first
look). Text and state colors ≥ 4.5:1 on cards in all three (tested).

| Check | Result |
|---|---|
| Swift `swift test` | 195 tests, 0 failures, 10 opt-in skipped (not counted as passed) |
| Python (3.14 and Xcode's 3.9.6) | 168 OK each, 1 skipped by design |
| Layout recursion | 0 hits |
| Xcode Debug / Release | BUILD SUCCEEDED, 0 compiler warnings |
| Real history in the new views (offscreen, read-only) | no overlap; 3/3 newest, automatic turn 2/3; API-error turn shown as error |
| Relay CPU (one Debug run) | rest 0.82 % app; moving 6.4 % with the 2.2 % loop |
| On the real screen, Reduce Motion, tooltip feel, paste into assistants | **Not verified** (owner) |

### Owner checks (polish)
1. Rebuild in Xcode, quit the old builds.
2. History: click a session twice — it closes; click another — the first closes.
3. Step through answers ‹ › on a long and a short answer, with and without
   files: one smooth change, no jump to a short preview; footer never covered.
4. Hover icons in Quick Peek *without clicking first*: tooltips after a
   moment, every time.
5. Copy Answer, Copy for Review, History copy, Clipboard Copy Again / Copy
   images: each shows "Copied!" for about 2 s.
6. Settings → Appearance → Theme: compare Soft Spectrum, Material Calm, Classic.
7. Reduce Motion on: no moving or resizing animation, short fades only.

## Phase 6 visual pass (2026-10-31)

Backup ref `refs/backup/phase6-visual-start` (= `93cfad5`). Renders (real
SwiftUI, fixture content): `docs/images/phase6-warm-cocoa/`.

| # | Problem | Cause | Fix |
|---|---|---|---|
| 1 | Tooltips over other apps | Only AppKit tooltips (their own window) can leave the island; the polish build had none, except the fallback path used outside the island environment | Fallback removed (accessibility hint only); compact tip (10.5 pt, 6×3 padding, 82 % black, no shadow, wraps at 220 pt); placement clamped to the island on every edge, above the control when there is no room below (tested) |
| 2 | Task More/Less snaps, then animates | Expanding replaced a `Text` with a new scroll view whose height starts at 0 | One scroll view for both states; expanded up to 168 pt, scrolls inside |
| 3 | Unbalanced cards | Two independent columns | `PairedRows`: each row is as tall as its taller card's natural height; Answer keeps ≥ 140 pt when space is short; the top row never below its cards' minimum (tests caught a 6-pt overlap at 300 pt); below 330 pt one column at a time |
| 4 | Step 2 too tall on short displays | Two-line footer | One row when it fits (Details), two rows otherwise (Quick Peek) |
| 5 | Real data, 14-inch: Answer squeezed to ~45 pt by the Copy with Context card | The top row followed that card's five rows | Its rows scroll inside the card; the top row follows Task (≤ 42 % of the space) |

**Warm Cocoa** (Settings → Appearance → Theme; default for new installs and
for anyone who never chose a theme; an explicit choice is kept): cards
`#292725`, text `#F4EEE5`, caramel accent and Copy Answer `#C59468` on dark
`#1E140B` text, sand `#E9D7BC` for materials, green `#93C79F`, amber
`#E8C077`, coral `#EC968E`; selected files get a soft caramel row. All text
and states ≥ 4.5:1 on both card surfaces. The camera area and Relay are
unchanged.

**Copy with Context** (was Copy for Review). The Core's package heading is
now `# Copy with Context: Claude Code result for an independent check`
(golden files: that line only). Structure and provenance labels unchanged.

**Preview.** Copy with Context card → Preview builds the package with the
same builder the copy uses (`AppModel.buildPack`: the Core's `context` for
a local answer, `ReviewPack` for an import) and shows its exact text. Copy
from Preview copies that snapshot byte for byte (Git status and time as
read when it was built; said in the view). If the chosen files changed
since, Copy builds it again so text and files agree. Possible secrets still
ask before copying. Another answer drops the preview.

**Attachment preview.** Click an attachment (or ⋯ → Preview): image
(enlarged, drag), text documents up to 1 MB (exact text, read-only), PDF
(PDFKit); Copy, Drag, Show in Finder; Back. HTML is shown as source and
never run; mockup states say that motion and clicks are not checked.
Opening a preview changes neither the answer, the session nor the choice of
files (tested).

**Selected answer.** Details: Answer header shows characters · time · N/M;
Quick Peek: N/M beside the state chip, time in the band.

| Check | Result |
|---|---|
| Swift `swift test` | 202 tests, 0 failures, 11 opt-in skipped (not counted) |
| Python 3.14 / 3.9.6 | 168 OK each (1 skipped by design) |
| Layout recursion | 0 hits |
| Xcode Debug / Release | BUILD SUCCEEDED, 0 compiler warnings |
| Real history in the new views (offscreen render, read-only) | no overlap; 4/4 newest |
| Relay CPU (one Debug run, busy machine) | rest 1.15 %; moving 10.1 % with a 4.2 % loop — noisier than the earlier run; Relay code unchanged |
| Live NSPanel on the real screen | **Not verified** (two builds already running; no third started) |

### Owner checks (visual pass)
1. Rebuild in Xcode; Settings → Appearance → Theme → Warm Cocoa (new
   installs get it; an earlier explicit choice is kept).
2. Hover Copy Answer, Copy with Context, History, Clipboard, Settings near
   the island's edges: small tips, always inside the island.
3. Task More / Less, quickly several times: no snap.
4. Copy with Context → Preview → scroll → Copy; paste somewhere: the same text.
5. Click a Markdown, PNG and PDF attachment: preview, Back.
6. On a long and a short answer, with and without files: the two rows end
   on one line; nothing overlaps the footer.
