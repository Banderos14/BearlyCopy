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

# Phase 7.1 — persistent hand-off, intelligent import, Living Relay

Backup ref `refs/backup/phase7.1-start` (= `47ed7f8`). Core, hooks, plugin
and JSON API unchanged; two optional, backward-compatible fields on imports
(`assistant`, `importedAs`) and a `handoffs.json` next to the reports.

## Running copies (found at the start)
Three copies ran at once: `~/Applications/Prompt Relay.app` (the Oct 29 build,
started Oct 30) and two Debug builds from DerivedData (13:07 and 14:31). None
was quit. Each copy draws its own panel. That is the **double (or triple)
Relay**: two copies with the same bundle ID never stepped aside for each other
(only Release → Debug did), and the old build has no rule at all.
**Fix:** within a bundle ID, the newest launch keeps the notch (ties: the
higher PID); Release still yields to Debug. Builds from before 7.1 do not follow
the rule, so Settings → About lists every running copy (PID, executable,
start time) and offers Quit. Security review: copies are recognised by bundle
ID only (ad-hoc builds have no Team ID), so stepping aside stays under the
user's "step aside" setting.

## Defects and causes
| # | Defect | Cause | Fix |
|---|---|---|---|
| 1 | Step 2 lost after switching to ChatGPT | Closing the island (and mouse-leave) called `endHandoff()` | Steps are kept per answer, bound to the copied text and the chosen files. Closing marks the step "Continue Transfer"; another answer hides it, and returning restores it. A restart keeps it while its files exist. Only Done ends it |
| 2 | Tooltips too wide | `.frame(maxWidth:)` takes the whole maximum: "Back (Esc)" sat in a 208-pt box (probe: 208 → 54 pt) | `TipTextLayout`: the ideal width, wrapping at the maximum |
| 3 | Step 2 below the island on the smallest displays | At the 300-pt floor (one column) the header, picker, Task, Answer and step 2 did not fit; step 2 ended 15 pt low (new test) | While step 2 shows, the Task card moves to the For Review pane; Copy Text Again is an icon in the one-row footer; there is a two-row fallback |
| 4 | Old wording claimed "Claude Code cloud session" for every import | Hard-coded in `ReviewPack` | Names the source you chose, or "not specified" |

## Persistent hand-off and the character count
Step 2 reads **"Text copied · 12,486 characters · Now 3 files"** (compact
**"12,486 chars copied · 3 files next"**). After a close it reads
**"Continue Transfer · 3 Files"**. The count is of the text the clipboard
confirmed, using one rule for the whole app (`CharacterCount`, Unicode
scalars); file sizes are never added. When another copy has replaced the text,
**Copy Text Again** puts the same snapshot back (not rebuilt). Copy with
Context without files shows "Copied! · 12,486 characters" beside the button
when it fits, "12,486 chars" when narrow, otherwise nothing; the island never
grows for it. Copy with Context defaults to **Full** now; the choice is
remembered.

## Living Relay
- **2.5D head.** Yaw and pitch move the bear's own layers by depth: the nose
  and muzzle most, then the eyes, then the outline, and the ears against the
  turn. The far eye and the far ear are foreshortened, and the muzzle
  flattens with the pitch. The flat tilt is smaller (3°).
- **Following.** The head follows with spring inertia and the eyes ease
  faster (unchanged followers, 30 updates/s only while moving). Subtle turns
  the head to 65 %, Expressive to 100 %.
- **Idle (`RelayLife`).** One timer, nothing between beats: a glance, a look
  around, a curious tilt or a smile every 16–34 s (Expressive: 9–18 s), and a
  sleepy face after 5 quiet minutes. The pointer and events win at once, and
  any activity wakes it.
- **Reactions.** A new answer → curious. Copy → happy hop. Done on a hand-off
  → a short happy hop. A capture error → concerned. The pointer near the
  island → it looks.
- **Settings → Appearance:** Relay Subtle / Expressive / Off, Idle moments,
  Follow the pointer, Relay on displays without a notch. Off and Reduce
  Motion keep the bear still and stop the timers. With following off, the
  pointer monitor does not run at all (security review).
- **Without a notch:** a centred 76 × 32 pill under the menu bar, on the
  display Prompt Relay uses. It is the same single panel, so there is no
  second bear. It follows "Open on hover".
- **Renders:** `docs/images/phase71-relay/relay-poses.png` (real drawing code,
  offscreen; not motion on the live screen).
- **CPU (Debug, this machine, `PROMPT_RELAY_PERF=1`):**

  | State | App CPU | Memory |
  |---|---|---|
  | Rest | 0.93 % | 59 MB RSS |
  | Pointer still | 4.8 % | |
  | Pointer moving | 9.3 % (31 gaze updates/s) | |
  | Relay off | 0.32 % | |

  The test loop alone takes 3.6 %. Release was not measured.

## Import AI Result
- **Report:** kept whole, with a character count. It scrolls inside a card
  of bounded height, or shows the exact full text inside the card; Clear is
  there too.
- **Task:** typed by you, or a suggestion you click. Suggestions come only
  from a Prompt Relay package's "Original user request" block or a single
  `## Task`-style heading, never from service blocks or automatic turns.
- **Project:** Manual, or Suggest from Report. Suggestions come only from
  explicit Project / Repository fields matched to local projects; several
  matches mean you choose, none means Unassigned.
- **Source:** Claude Cloud, Claude Code, ChatGPT, Gemini, Codex or Other; a
  detected source is marked as suggested.
- **Own package:** Import as historical context (Copy with Context then
  explains that its labels belong to the original machine) or as plain text.
  Its labels are never treated as local checks.
- **Duplicates:** a warning appears before importing a text that is already
  there.

## Capture Health (Settings → Advanced)
It shows the current project's capture, the last hook event and the command
events for the answer shown. It tells apart "this turn ran no tools", "capture
off" and "not recorded".

## Incident
At about 15:40 a line in a new test (`NSPasteboard.general.declareTypes([])`)
**cleared the owner's system clipboard once**. It was removed straight away;
no test touches the general pasteboard now.

## Verification
| Check | Result |
|---|---|
| Swift tests | 243, 0 failures (12 opt-in skipped) |
| Python 3.14 / 3.9.6 | 172 OK each |
| Layout recursion | 0 |
| Xcode Debug / Release | BUILD SUCCEEDED, 0 warnings |
| Live panel, real mouse hover/drag, idle feel, external display, ProMotion, Release CPU | **Not verified** (owner) |

## Owner checks
1. Quit the old copies (Settings → About shows them), rebuild Debug, and check
   that only one Relay is on screen.
2. Copy with Context with 3 files → ChatGPT → paste → come back: "Continue
   Transfer · 3 Files" → Copy Files / Drag → Done (Relay hops).
3. Watch Relay for a few minutes: glances and look-arounds, never while you
   move the pointer. Try Subtle / Expressive / Off and Reduce Motion.
4. On an external display without a notch: the pill under the menu bar;
   hover opens Quick Peek.
5. Import AI Result: paste a ChatGPT answer with "Project:" in it, and paste
   one of your own Copy with Context packages.
