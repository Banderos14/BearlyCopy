# Phase 7 — UX stabilization, developer workspace, smart handoff

Branch `claude/loving-mccarthy-ossw3q`, backup ref `refs/backup/phase7-start`
(= `61e4500`). Storage formats, hooks and the plugin are unchanged. The Core
got one minimal, backward-compatible extension: `context` / `copy-context
--detail standard|full` (default `full`, byte-identical to before; golden
files untouched).

## Stage A — defects and their causes

| # | Defect the owner saw | Cause found | Fix |
|---|---|---|---|
| 1 | Tooltips leave the island and cover Xcode | The current code cannot draw a tip outside the island (the island is clipped to its shape, and no `.help` is left). A probe (`scripts/probes/appkit-tooltip.swift`) shows that among `.help`, `.accessibilityHint`, labels, shortcuts, menus and truncated text, **only `.help` opens an AppKit tooltip window** (`NSToolTipPanel`, its own window, able to cover other apps). Builds before the Phase 6 visual pass had `.help` everywhere, and **`~/Applications/Prompt Relay.app` is a stale build from 2026-10-29 19:12** with those tooltips. The likeliest source of what the owner saw is an old build still running. In the current build, a tip near the flared top sides or rounded bottom corners could also sit on a transparent corner and get cut off by the island's clip, and its first frame was placed before it was measured | Tips are placed from their **measured** size inside the black part of the island (below the camera band, 14 pt from the flared sides, clear of the 26 pt bottom corners, width reduced there), below the control or above it, never over it. They follow their control while shown. A test shows **every real tip** on Quick Peek, Details, History, Clipboard, Settings, Full Report, Full Task, Evidence, Preview and Import in the real view tree (30+ tips, two display heights) and checks each drawn frame. Another test fails if `.help(` or an AppKit `toolTip` comes back |
| 2 | Clipboard Images: the cursor is over photo 1, photo 2 lights up or opens | The thumbnails use `.aspectRatio(.fill)` + `.clipped()`. **Clipping hides the overflow but does not stop it from taking hover and clicks**, so a wide screenshot reached into its neighbour. Proved in a real AppKit process (`scripts/probes/thumbnail-hit.swift`): with the Phase 6 code, clicks on the thumbnails did not open the image under the cursor; with the fix, each of 7 clicks opened the right one | `.contentShape` on the visible rounded thumbnail (Clipboard, attachment icons, mockup states). Hover never changes the selection (it never did; only the highlight was wrong). A source test fails if any `.fill` image loses its content shape |
| 3 | Layout and padding | No new overlap found by the existing `HeightBudget`/`PairedRows` tests. The new elements reuse the tokens: the Evidence chip sits in the Answer card's existing "View Full Report" row (no new height), the completeness line goes inside the Attachments scroll area, and the new screens are scroll areas within the budget | — |

## New features

**View Full Task** (expand icon on the Task card; screen "Full Task"). It shows
the whole stored request: Formatted, or Markdown Source (exact characters). It
also says where the request came from (UserPromptSubmit hook, linked by
prompt_id or by order; entered by you for an import). It is marked
**incomplete** when only the Core's 200-character preview is at hand (for a
turn without an answer, `show` is not loaded). An automatic turn is never shown
as your request, and Copy Original Task is off for it. The copy is the stored
text, verbatim. Found on the way: **the Task card's More only ever showed the
200-character preview**; it now uses the full request once it is loaded.

**Full Report**: Plain Text → **Markdown Source** (it always showed the source).
Formatted stays the default, and both share one fixed viewport (no height jump).
Long code lines show a horizontal scroller in the reader. Tables are shown as
their source rows (lossless).

**Copy with Context: Standard / Full** (segmented control on the card and in
Preview; remembered; Standard by default). Answer Only is Copy Answer.
Standard has the request and the answer whole, failed commands, tests, builds
and background starts, changed files, branch and HEAD with a count of
uncommitted entries, attachments and provenance. It leaves out command output,
routine and git commands (counted) and the uncommitted file list, and its
header says so. Full is the package as it was before. Preview shows the chosen
level with its character count. Switching the level rebuilds the open Preview,
and Copy uses that same snapshot. If files or the level changed since, it
builds again. A **Sections** menu jumps to the text's own `##` headings
(request, answer, evidence & commands, files, Git, attachments, limitations).
No second formatter: the Core renders both levels.

**Evidence Check** (chip on the Answer card → "Evidence & Review"). It lists:
- **Observed locally**: N commands, "1 command returned exit 1", test/build
  commands that exited 0, files changed, background starts.
- **Reported by AI**: phrases found in the answer ("the answer says tests pass").
- **Not verified**: "Claimed test success: no passing test command was
  observed", visual review needed, Stop ≠ success.
- **Unavailable**: CI not connected; capture off; an import.

A claim found in the text is never turned into a fact.

**Artifact Completeness** (one line in Attachments when something is missing;
details on the same screen). For files it shows attached / chosen / unreadable.
For mockups: "6/7 states captured · 1 missing · Live review required", with the
missing names. "Number of states unknown" when nothing was declared (no
invented total). For a private claude.ai link: "content was not received".
Pages the AI published without a material here count as "known by name only".

**Review Checklist** (same screen; at most 6 items, from fixed rules): check
the interface on a real screen, the animation, missing materials, run the
build/tests yourself, CI, files arriving in the receiving assistant, the right
answer and files. Only you tick an item. A ticked item reads "Checked by you",
apart from the observed facts, and is remembered per answer.

**Import AI Result** (was Import Saved Result): for a finished result from Claude
Cloud, ChatGPT, Gemini or another AI. It is labelled "Imported by you" and never
"captured locally". Stored imports are unchanged (`cloudManualImport` still
decodes).

**Export Bundle** (⋯ → Export Bundle…): asks for a folder, then writes
`Prompt Relay <project> <turn> <time>/` with:
- `context.md`: the same package as Copy with Context, at the chosen level.
- `files/`: the chosen attachments' stored snapshots, byte for byte.
- `manifest.json`: source, project, session, turn, level, each file with
  `included`/`missing`, provenance and SHA-256, materials (listed, never
  fetched), and limitations.

It never overwrites, and a package with possible secrets is not exported.
Finder shows the new folder.

**Multi-agent readiness**: the new components speak of "the AI" and take the
source from `ReportSource`. Claude Code appears only in facts that are specific
to Claude Code (UserPromptSubmit, automatic turns). Future Source Adapters and
Target Profiles are in `docs/PRODUCT_ROADMAP.md`.

## Verification

| Check | Result |
|---|---|
| Swift `swift test` | **221 tests, 0 failures**, 11 opt-in skipped (not counted as passed) |
| Python `scripts/check.sh`, 3.14.0 and Xcode's 3.9.6 | **172 OK** each (1 skipped by design); hook median 36.6 ms |
| Layout recursion | 0 hits |
| Xcode Debug / Release | BUILD SUCCEEDED, 0 warnings |
| Real Core, both detail levels | `CoreIntegrationTests` (answer whole in both) |
| Tooltip placement in the real view tree | automated, every real tip on 10 surfaces, 2 heights |
| Thumbnail hit-testing | real AppKit process probe (synthetic clicks in a key window); in-package layout test |
| **Live NSPanel hover, tooltips on the real screen** | **Not verified.** Synthetic input needs Accessibility permission, which this shell does not have; the probe could not open the island |
| Clipboard images with a real mouse, drag into other apps | **Not verified** (owner) |
| Reduce Motion, CPU on the real screen | **Not verified** (owner); Relay code unchanged |

## Owner checks (about 10 minutes)
1. **Quit every running Prompt Relay** (menu bar → Quit, both icons), and delete
   or replace the stale `~/Applications/Prompt Relay.app` (2026-10-29). Rebuild
   in Xcode (Debug).
2. Hover Copy Answer, History, Clipboard, Settings, ⋯ near the island's edges in
   Quick Peek and Details: one small tip at a time, inside the black island.
   Tell me if a tip ever appears outside the island, and which build was running.
3. Clipboard → Images with 5 screenshots: hover and click each one, choose two,
   Copy, Drag, Attach to Current Answer, remove one.
4. Task card → expand icon → Full Task, on a long pasted Markdown request:
   Formatted / Markdown Source, Copy Original Task, paste.
5. Copy with Context → Standard / Full → Preview → Sections → Copy; paste.
6. Answer card → Evidence chip: observed facts vs. claims; tick a checklist item.
7. ⋯ → Export Bundle… → a folder; check `context.md`, `files/`, `manifest.json`.
8. Reduce Motion on: short fades only.
