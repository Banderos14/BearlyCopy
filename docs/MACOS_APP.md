# BearlyCopy for macOS

A native SwiftUI + AppKit app whose whole interface is one island in the
MacBook notch (floating below the menu bar on displays without one). It
shows Claude Code's captured final answers and copies them, or a Review
Pack, with one click. It talks to the Python Core only through the CLI JSON
API v1 (ADR-006, ADR-009), has no backend and makes no network connections.

The product rules, every view and every control are in
`docs/PRODUCT_UX_SPEC.md`. This file covers building, architecture, data,
clipboard behavior, limits and verification.

## 1. Build and run

Requirements: macOS 14 or newer, Xcode (or the Command Line Tools with Swift
5.10+), and a Python 3.9+ for the Core (found as in §8).

### In Xcode (development)
1. Open **`macos/PromptRelay.xcworkspace`** (not the `.xcodeproj`: only the
   workspace shows the package's tests).
2. Scheme **BearlyCopy**, destination **My Mac**. ⌘R runs the **Debug**
   build, ⌘U the Swift tests.
3. Previews: `Sources/PromptRelayKit/Previews/PreviewSupport.swift`
   (Quick Peek, Expanded, compact; sample data, Debug only).

### Debug and Release: one at a time
The two builds are different apps to macOS: Debug is
`io.github.banderos14.PromptRelay.debug`, shown as **BearlyCopy Dev**
with a hammer menu-bar icon; Release is `io.github.banderos14.PromptRelay`,
"BearlyCopy". They have separate preferences (projects list, notch
settings, copy history) but share the history and imports in the data dir.
On 2026-10-29 both were running at once, which looked like two different
apps. The safe routine:

- While developing, quit the Release app and use only ⌘R in Xcode.
- To try a finished state, quit the Debug app, then
  `scripts/build-macos-app.sh --install` and open the Release app.
- If both run anyway: the Release build steps aside at the notch (no two
  islands on top of each other), ⚙ gets a small orange dot, and Settings →
  About names the other build with a "Quit …" button. Nothing is quit
  automatically. None of this is visible in a Release build used alone.

### From the command line
```bash
scripts/build-macos-app.sh            # builds macos/build/BearlyCopy.app (SwiftPM, release)
scripts/build-macos-app.sh --install  # also copies it to ~/Applications
swift test --package-path macos       # Swift tests (one opt-in render test is skipped)
xcodebuild -workspace macos/PromptRelay.xcworkspace -scheme "BearlyCopy" -configuration Release build
```

The bundle is ad-hoc signed for local use; it is not notarized and is not a
release. `macos/build/` and `macos/.build/` are git-ignored. Removing the app
leaves `~/Library/Application Support/PromptRelay` untouched.

## 2. Surfaces

| Surface | Role |
|---|---|
| Island (notch, or floating) | the interface: resting, Quick Peek on hover (520/560 pt), Details on click / ⌃⌥⌘P (640/680 pt, ≤ 38 % of the display), with Project and Session, Observed Work, Mockup States, Clipboard Images, Recent Copies, History, Import, Settings (Capture inside) and Full Report |
| Menu-bar item | a small fallback menu: Open BearlyCopy, Recent Copies, History, Import Cloud Report…, Settings…, Quit; each opens the island on that view |

There are no regular windows any more. The Phase 3A main window, menu-bar
panel and status window and the Phase 3C settings window were removed in
Phase 4 after everything they did moved into the island (their code is in
git history and in `refs/backup/phase4-start`).

### Phase 5 (2026-10-30)
- `Notch/DetailsViews.swift`: Details (two columns), the session switcher,
  Observed Work, attachments with suggestions, mockup states, clipboard
  images, step 2 of the hand-off (Copy N Files, Drag All, Show in Finder).
- `Presentation/AppModel+Handoff.swift`: materials (links, mockups),
  suggestions from the turn's observed tool events, hand-off names and order.
- `Services/ReportStore.swift`: typed snapshots (document, PDF, image),
  `materials.json` for links and mockups, state images.
- `Services/ClipboardImageHistory.swift`: optional, off by default (ADR-014).
- `Notch/Mascot.swift`: `RestingPose` (bounded head at rest), `Breathing`
  (Core Animation on the render server). See PHASE5_PROPOSAL §7.1.
- Session pinning: a chosen session (`selection.pinned` in the app's
  defaults) is kept across launches; Settings → Capture → "Stay on the
  session I choose" turns following the newest answer back on.

## 3. Architecture

```
macos/
├── PromptRelay.xcworkspace, Xcode/          app target (Debug/Release), embeds the Core
├── Sources/PromptRelayApp/main.swift        lifecycle: the island coordinator and the menu-bar fallback
└── Sources/PromptRelayKit/
    ├── Models/APIModels.swift               JSON API v1 types (open enums)
    ├── Models/Reports.swift                 ReportRef, ReportSource, ImportedReport, ReportAttachment, CopyRecord
    ├── Core/                                CoreLocator, CommandRunner, CoreClient (CLI adapter)
    ├── Services/ClipboardService.swift      NSPasteboard: text (read back), text + images, one image
    ├── Services/ReportStore.swift           app-owned data: imports and attachments (§4)
    ├── Services/SecretScanner.swift         the Core's secret heuristics, for imported text
    ├── Services/StoreWatcher.swift          FSEvents on events/*.jsonl and config.json
    ├── Services/AppBuild.swift              which build this is; other builds running
    ├── Presentation/AppModel.swift          the one @Observable model: data, selection, routes, copy, history
    ├── Presentation/ReviewPack.swift        Review Pack for imports; attachments section
    ├── UI/Markdown.swift                    display-only Markdown blocks (headings, lists, code, tables)
    ├── UI/Components.swift                  status colors, verbatim text view, secrets alert
    └── Notch/                               geometry, interaction state machine, controller (panel,
                                             tracking, mascot), island views, settings view, mascot
```

- **One model, one navigation.** `AppModel` holds the data, the selection
  (a local turn or an import: `currentRef`) and the island's route with
  Back. The island is the only view of it.
- **Core adapter.** `CoreClient` runs `python -I -S -B <cli> … --json` with a
  minimal environment (no `PYTHON*`, no user site packages, no bytecode in
  the bundle), from the home folder; 30 s timeout; 256 MiB output cap.
  Decoding: parse → `api_version` 1 → `ok` and exit code → payload.
- **Navigation never starts Python.** Opening views reuses loaded data. The
  Core runs on history changes (FSEvents), on selection changes that need a
  turn list or a full text, on copy, on Diagnostics, and when History
  searches (once per changed session, then cached).

## 4. Data the app keeps

| What | Where | Contents |
|---|---|---|
| Captured history | `<data dir>/events/` | written by the hook, read through the Core only |
| Imported reports | `<data dir>/app/imports/<id>.json` | the pasted text verbatim, optional task, project, cloud session label, import time, SHA-256 |
| Attachments | `<data dir>/app/attachments/` + `attachments.json` | private copies of images the user chose; name, MIME type, size, SHA-256, report, provenance |
| Recent Copies, pins, added folders, last seen answer | app preferences | references only (`ReportRef`), never text |

`<data dir>` is `~/Library/Application Support/PromptRelay`. `app/` is
0700 and its files 0600, written atomically. The Core never reads `app/`;
its prune and delete commands only touch `events/`. Nothing in `app/` is
deleted unless the user deletes that import or removes that image (removing
an import removes its images). A Recent Copy or pin whose report is gone says
"No longer in history" and cannot be copied.

## 5. Clipboard and export

- **Copy Response** writes the complete original text (`final_response.text`
  from `show`, or the imported text) as one plain-text item and reads it
  back scalar for scalar; only then does the island say "Copied the complete
  response: N characters". A preview or rendered Markdown is never copied.
- **Review Pack**: for a local report, the Core's `context` packet (title
  "Review Pack", "Source: Claude Code on this Mac", the linked request, the
  full answer in a fence longer than any inside it, read-only git state with
  its collection time, provenance labels, "Not verified" for tests and CI,
  and a request for an independent review). For an import,
  `ReviewPack.render(imported:)` writes the same structure with "Source: …
  imported manually", "[Supplied by you]" for the task, project and session,
  and "[Unavailable]" for git. Attachments are listed by name, type and size
  only, never with a local path. Likely secrets (the Core's findings for
  local reports, `SecretScanner` for imports: the same patterns, checked
  against the Core in a test) stop the copy until the user confirms; such a
  pack is not added to Recent Copies.
- **Images.** "Copy Text + Images" writes several pasteboard items: the text
  first, then one item per image (its own type, TIFF, and a file URL to the
  private copy). Whether a paste carries the images depends on the
  destination app: **not yet verified with ChatGPT** (§9). The reliable
  paths are the per-image menu (Copy Image, Show in Finder) and dragging a
  thumbnail into the destination. Copy Response stays text-only, so the
  one-click text path never depends on images.
- The clipboard is written only on an explicit click, and read only by the
  import's explicit Paste button. Nothing watches the system clipboard.

## 6. Cloud sessions (manual import)

Claude Code cloud sessions run on Anthropic-managed VMs ("Use Claude Code in
the cloud", code.claude.com docs). The hooks installed on this Mac never see
them, so BearlyCopy cannot capture them automatically. What the docs offer
and why it is not used:

- `claude --teleport` pulls a cloud session into a local terminal, but it
  requires a clean git state, checks out the session's branch, and does not
  copy messages that were compacted. It changes the repository, so Prompt
  Relay never runs it. After a teleport, new turns in that local terminal
  are captured as usual (they are local Claude Code turns).
- `claude -p … --cloud <id>` only sends a message to a cloud session; it
  does not return its answers.
- No documented interface returns a cloud session's final messages to a
  local tool. BearlyCopy does not read Claude Desktop caches, tokens,
  cookies or undocumented APIs.

So the supported path is **Import**: copy the report in the cloud session,
then Import → Paste Report from Clipboard → optional task, project and
session ID → Import Report. The text is saved exactly as pasted (it cannot
be edited in the island), marked "Cloud · imported by you", and appears on
Home, in History and in Recent Copies like a local report. Importing the same
text and task again shows the existing record instead of a second copy.

## 7. The mascot

Relay, a small bear cub: original vector art drawn with SwiftUI `Canvas`
(`Notch/Mascot.swift`), nothing from Coucou/Mochi or other assets. It sits
in the left ear at rest and at the left of the band when open, 28 pt. Moods
map to facts only: *curious* when a new answer was captured, *pleased* after
a copy (hop, happy closed eyes), *concerned* after a failed copy (head
shake) or when the Core is unavailable, *idle* otherwise; none suggests
that work or tests succeeded.

**Following the pointer** (`Notch/PointerFollower.swift`). A global
`NSEvent` monitor for mouse movement (other apps' windows; mouse events need
no Accessibility permission, key events are never monitored) plus a local
one (the island's own window). Each event reads `NSEvent.mouseLocation`;
at most 30 updates a second reach the controller, always ending on the
latest position; only that position is kept. The controller turns it into
a gaze toward the bear's place on screen (`tanh` per axis, one coordinate
space for every display) and eases the face toward it at 30 fps only until
it arrives. Monitors run only while the bear is on screen, motion is
allowed, the displays are awake and no dialog is up.

*Compared with Coucou* (MIT; read for principles only, no code or art
taken): Coucou reads `NSEvent.mouseLocation` in a 30 Hz timer and draws its
mascot every display frame in a `TimelineView` + `Canvas`, pausing while
the screen sleeps. BearlyCopy is event-driven instead: no timer while the
pointer is still. A SwiftUI spring on the gaze first redrew the panel at
the display's full rate (≈ 26 % CPU while moving in the benchmark); the
30 fps easing costs ≈ 2 %.

Measured (opt-in `RelayPerformanceTests`, `PROMPT_RELAY_PERF=1`: the real
panel, pointer events at 120 Hz for 10 s; the loop alone 2.5 %): still ≈ 0 %
over the loop, moving ≈ 2.2 %, 29–30 gaze updates a second.

## 8. Finding the Core and Python; updating data

CLI: the `PromptRelayCLIPath` default → `$PROMPT_RELAY_CLI` (development) →
the copy in the bundle (`Contents/Resources/core`). Python, first that
passes `>= 3.9`: `PromptRelayPythonPath` → the pin in `<data dir>/python-path`
(only if the file is yours) → Homebrew → `/usr/local/bin` → python.org →
`/usr/bin/python3` only when `xcode-select -p` succeeds.
`PROMPT_RELAY_HOME` selects another data dir (tests only).

FSEvents on the data dir triggers one coalesced refresh per change; the full
text is fetched again only when the selected turn changed. If the data dir
is missing or FSEvents fails, a 30 s timer runs only while the island is
open. Nothing polls while idle.

## 9. Verification (2026-10-29, MacBook Pro M3 Pro, macOS 27.0.1, Xcode 27.0)

Phase 4, on this Mac:
- `swift test` and `xcodebuild test` (scheme): 109 tests, 0 failures
  (1 opt-in render test skipped); Xcode Debug and Release BUILD SUCCEEDED.
  Python: `scripts/check.sh`, 141 tests OK (1 skipped by design), hook
  median 37 ms.
- Real Core, temp data dir: a 100 KB+ report (Markdown, tables, nested
  fences, TypeScript/Python/JSON/Swift, Cyrillic, emoji, CRLF) through the
  real hook twice (duplicate delivery): one turn, the task linked by
  `prompt_id`, the list carries only a preview, Copy Response byte-identical
  on a private pasteboard, the Review Pack contains the report exactly once.
- Imports (verbatim with NUL and U+2028 after a restart, dedup, 0600/0700),
  attachments (private copy, checksum, dedup, non-image refused, removed
  with the import), Review Pack honesty (no invented task, no local paths),
  the Swift secret scanner equal to the Core's on the same samples, Recent
  Copies (five references, restart, re-copy fetches again, removed report),
  pins, search (imports in full, local previews, cached), projects never
  mixing, text + image clipboard items, the mascot (ears, blinking only while
  visible, no gaze outside, Reduce Motion, reactions), menu and folder-picker
  pinning, the floating fallback.
- Real island on the built-in display (Debug build, the owner's data; the
  window is exactly the island in every state): resting 237 × 32 with the
  bear, Quick Peek 460 × 158, Home 460 × 292, Projects 231, Recent Copies
  148, History 195, Import 354, Settings 584 (scrolls), Full Report 162,
  then back to resting.
- Idle: 0 % CPU over 30 s, no Python child processes, ≈164 MB RSS (Debug;
  ≈137 MB before Phase 4: Markdown, images and the mascot).

Real-session audit (2026-10-30): a real answer of this Claude Code session,
captured by the installed plugin, is byte-identical to the transcript, to
Copy Response and inside the Review Pack (`RealSessionAuditTests`, opt-in:
`PROMPT_RELAY_AUDIT_SESSION`, `_TURN`, `_EXPECTED`). Release idle ≈91 MB.

UI polish (2026-10-30): visual examples of Home (top and scrolled), a
short display, Quick Peek, the Full Report and Relay's states:
`PROMPT_RELAY_VISUALS=<dir> swift test --package-path macos --filter IslandLayoutTests/testWriteVisualExamples`.
The real-session audit also writes the real Review Pack
(`real-review-pack.md`) when `PROMPT_RELAY_AUDIT_RENDER` is set, and checks
the response *extracted* from the pack, not the whole pack, against the
transcript.

Real AppKit checks (opt-in): `PROMPT_RELAY_REAL_DIALOG=1` opens the real
`NSOpenPanel` from the island twice (closed with Esc, then Cancel) and checks
that the island steps aside and comes back; keyboard focus needs a real
click and is checked on the Mac. Always on: scroll-wheel events routed
through the real `NotchPanel` (hit test → the answer's scroll view).

Manual image-paste check (`PasteInteropKit`, opt-in): it overwrites the
general clipboard with a test text and image, then you paste into ChatGPT:
`PROMPT_RELAY_PASTE_TEST=text-image swift test --package-path macos --filter PasteInteropKit`
(also `image` or `text`).

Earlier phases (3A–3D.1): the owner confirmed Copy Response → ⌘V without
loss and the island geometry on the real screen; details in STATUS.

**Not verified yet:** pasting text + images into ChatGPT (desktop app and
web); a real Claude Code turn and a real cloud report through the new UI;
the floating island on a real external display; hover and focus with a real
pointer after the redesign. These need the owner (STATUS).

## 10. Known limitations
- Image paste into ChatGPT is unverified; until it is, treat "Copy Text +
  Images" as best effort and use Copy Image or drag-and-drop.
- History search covers imports in full but captured reports only through
  the Core's previews (the first 200 characters of each task and answer).
- The Markdown reader is a simple block renderer (tables show as
  monospaced text); "Plain Text" shows the exact text.
- Each Core call starts Python (≈40–60 ms). Memory ≈160 MB is above the
  50 MB goal in UI_RESEARCH; not optimized.
- Coexistence with Coucou is unit-tested but was not observed live.
- No app icon, no launch at login; not notarized.
