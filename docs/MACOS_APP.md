# Prompt Relay for macOS (Phases 3A and 3B)

A native SwiftUI + AppKit menu-bar app for reading Claude Code's captured
final answers and copying them with one click. It talks to the Python Core
only through the CLI JSON API v1 (ADR-006, ADR-009). It does not read the
JSONL store, does not re-implement correlation, has no backend and makes no
network connections.

## 1. Build and run

Requirements: macOS 14 or newer, Xcode (or the Command Line Tools with Swift
5.10+), and a Python 3.9+ for the Core. The Core's Python is found the same
way the plugin launcher finds it (§4).

### In Xcode (development, debugging, Previews)
1. Open **`macos/PromptRelay.xcworkspace`** (Finder double-click, or Xcode →
   File → Open). Use the workspace, not the `.xcodeproj`: only the workspace
   shows the package's test target.
2. Choose the scheme **Prompt Relay** and the destination **My Mac**.
3. ⌘R runs the Debug build (bundle ID `io.github.banderos14.PromptRelay.debug`,
   so its settings are separate from the installed app). ⌘U runs the 70 Swift
   tests. Quit the installed app first, or two menu-bar icons appear.
4. Previews: open `Sources/PromptRelayKit/Previews/PreviewSupport.swift` and
   show the Canvas (expanded and compact notch, menu-bar panel, main window,
   all on built-in sample data; Debug only).

What is in it: `macos/Xcode/PromptRelay.xcodeproj` holds one macOS app target
("Prompt Relay", Debug and Release, `macos/Xcode/Info.plist`, LSUIElement,
ad-hoc signing) that compiles the existing `Sources/PromptRelayApp/main.swift`
and links `PromptRelayKit` from the local package (`..`); no Swift source is
duplicated. A build phase, "Embed Python Core", copies `bin/prompt-relay` and
`plugin/prompt_relay` into `Contents/Resources/core`.
`macos/PromptRelay.xcworkspace` adds the package itself, so its tests run from
the same scheme. The project file is small and written by hand; XcodeGen was
not needed (it would have been one more tool to install).

### From the command line
```bash
scripts/build-macos-app.sh            # builds macos/build/Prompt Relay.app (SwiftPM, release)
scripts/build-macos-app.sh --install  # also copies it to ~/Applications
swift test --package-path macos       # Swift tests (70; one opt-in render test is skipped)
xcodebuild -workspace macos/PromptRelay.xcworkspace -scheme "Prompt Relay" -configuration Release build
```

Then open **Prompt Relay** from `~/Applications` (Finder → Go → Home →
Applications) or with `open "$HOME/Applications/Prompt Relay.app"`. The app
lives in the menu bar (no Dock icon). The main window opens from the panel's
window button.

- The bundle is ad-hoc signed for local use. It is not notarized and is not a
  release.
- `macos/build/` and `macos/.build/` are git-ignored.
- To remove the app: quit it (menu-bar panel → Quit) and move
  `~/Applications/Prompt Relay.app` to the Trash. Your history in
  `~/Library/Application Support/PromptRelay` is untouched.

Development run without a bundle:
```bash
PROMPT_RELAY_CLI="$PWD/bin/prompt-relay" swift run --package-path macos PromptRelayApp
```

## 2. Screens

| Surface | What it shows |
|---|---|
| Menu-bar panel (click the clipboard icon) | project and session pickers, the session's answers newest first with a copy button on each row, the selected answer, **Copy Response** (⇧⌘C) and **Copy Context**, copy confirmation, connection line, Refresh (⌘R), Open Window, Quit |
| Main window | projects → sessions → answers (three columns), the full verbatim answer in a selectable text view, the same copy bar |
| Status window (click the connection line) | `doctor --json`: plugin install record, events received via the plugin, projects with capture on, Python and hook interpreter, history folder, live-update mode, findings, and what cannot be verified |
| Notch island (Phase 3B, opt-in in Settings) | see §2B |
| Settings (menu-bar panel → Settings…, ⌘,) | notch on/off, display, step aside for other notch apps, animation (follow Reduce Motion / smooth / reduced), "notify when an answer is ready" |
| Empty and error states | no projects yet, no sessions yet, nothing to copy (API error, still waiting, empty answer), Core or Python missing, unreadable Core output, newer API version — each with a short explanation and Try Again |

Wording follows the product invariants: a Stop is "Claude stopped", never
"done"; an inferred request link says "Request inferred from order"; an API
error is never offered as an answer.

## 2B. Notch island (Phase 3B)

A Dynamic-Island-style surface around the MacBook camera housing. It is off
until the user turns it on in Settings, and the menu-bar item always stays.

| State | Window | What is drawn |
|---|---|---|
| Hidden | none | notch disabled, no notched display chosen, or display asleep |
| Resting (compact, nothing new) | exactly the notch (e.g. 185 × 32 pt) | a black shape slightly smaller and rounder than the housing, so it stays invisible behind it; the window is the hover target |
| Compact, answer ready | notch + two 26 pt ears | left ear: a small glyph; right ear: a green dot. Static — no animation while closed |
| Expanded | exactly the island: 400 pt wide, notch height + 110–270 pt content | project (left of the notch) and "Stopped 4m" (right), the answer's first lines, size and link note, ‹ n of N › through earlier answers, **Copy Response** (white, the only accent), Context, and ↗ Open Full Window |

- **Opening and closing.** Hover opens after 0.15 s (a pass along the top edge
  does nothing); leaving closes after 0.35 s, and coming back cancels it, so
  the edge never flickers. Click or ⌃⌥⌘P opens with keyboard focus: ← → older
  / newer answer, ↩ Copy Response, Esc closes. Hover never takes focus from
  the app you type in. An open "possible secrets" alert keeps it open.
- **Morph.** The island grows from the notch: width, height and both corner
  radii animate (spring, about 0.35 s); content fades in shortly after.
  With Reduce Motion (or "Reduced" in Settings) it is a short fade. No shadow:
  a hardware notch has none, and a shadow showed as a grey halo on light
  desktops (fixed in review, covered by `NotchAppearanceTests`).
- **Look.** The island is black in both appearances so it merges with the
  housing; its text uses the dark appearance. No blue selection, no pop-up
  menus, no fixed-height empty areas. Statuses state facts only ("Stopped",
  "Tasks running", "API error"); a Stop never reads as "done" or "tests
  passed". The island shows the first six lines; the full text is in the
  window, and Copy Response always copies the Core's full `show` text.
- **New answers.** With the notch or notifications on, each refresh also
  runs `sessions --json` once and takes the newest session whose
  `last_turn.status` is a Stop (the Core's correlation, not re-derived). An
  answer newer than the last one seen raises the ears; opening the island
  selects it and marks it seen. "Seen" is remembered across restarts, so old
  answers are never announced again. The optional notification names the
  project only, never the text.
- **Displays.** One island at most, on the chosen display: Automatic = the
  built-in notched display. A display without a notch (external monitor,
  closed lid) gets no island; the menu-bar item remains. Unplugging the chosen
  display falls back to Automatic. Screen-parameter changes (plug in/out,
  resolution, scaling, arrangement), wake from sleep and Space changes re-lay
  it out. The panel joins all Spaces including full-screen ones, sits at
  `statusBar + 1`, and only ever covers the notch (plus ears) while closed.
- **Coexistence with Coucou / NotchBuddy.** Both draw in the notch. When
  Coucou (`fr.louisraille.Coucou`, `fr.louisraille.NotchBuddy`) is running and
  "Step aside when another notch app is running" is on (default), Prompt
  Relay shows no notch target; ⌃⌥⌘P and the menu bar still open the island.
  Turning that off shares the spot (hover may reach either app); Settings
  then suggests turning off Coucou's island in Coucou's own settings. Prompt
  Relay never changes Coucou, its hooks or its settings.
- **Cost.** No polling: hover is an `NSTrackingArea` on a window the size of
  the notch; the window is resized for each phase. FSEvents drives updates
  (`startBackgroundObservation` never starts the fallback timer). Opening the
  island does not start Python when FSEvents already keeps data current.
  `stop()` removes the window, tracking area, all six observers, the hot key
  and timers (tested over 25 start/stop cycles).

Debug builds only: `PROMPT_RELAY_DEBUG_CAPTURE_DIR=<dir>` makes the app draw
its own notch window (real display, real data) to PNGs a few seconds after
launch. It renders only its own window (no Screen Recording permission), so
the menu bar and hardware notch around it are not in the images.

## 3. Architecture

```
macos/
├── Package.swift
├── PromptRelay.xcworkspace                  Xcode entry point: the app project + this package
├── Xcode/PromptRelay.xcodeproj, Info.plist  macOS app target (Debug/Release), embeds the Core
├── Sources/PromptRelayApp/main.swift        app lifecycle: scenes, menu-bar item, Settings, notch coordinator
└── Sources/PromptRelayKit/                  everything reusable
    ├── Models/APIModels.swift               JSON API v1 types; open enums (unknown values never crash)
    ├── Core/CoreLocator.swift               finds the CLI and a Python 3.9+
    ├── Core/CommandRunner.swift             Process runner: no shell, drained pipes, timeout, size cap, off the main thread
    ├── Core/CoreClient.swift                runs `prompt-relay … --json`, checks version/ok/exit code, maps errors
    ├── Services/ClipboardService.swift      NSPasteboard write + read-back verification
    ├── Services/StoreWatcher.swift          FSEvents on the data dir (events/*.jsonl, config.json)
    ├── Presentation/AppModel.swift          the one @Observable model: data, selection, refresh, copy
    ├── Presentation/LoadState.swift, Formatting.swift
    ├── UI/                                  components (rows, status badge, verbatim text view, copy bar,
    │                                        empty/error states, status, Settings) and surfaces (panel, window)
    ├── Notch/                               NotchGeometry (pure layout), NotchInteraction (state machine),
    │                                        NotchController (panel, tracking, observers), NotchViews,
    │                                        NotchSettings, NotchCoordinator, HotKey
    ├── Services/ReadyNotifier.swift         optional "answer ready" notification (project name only)
    └── Previews/PreviewSupport.swift        Xcode Previews with sample data (Debug only)
```

- **One model, several surfaces.** The menu-bar panel, the window and the
  notch island observe the same `AppModel`; selection, copy feedback and data
  are shared, never duplicated. The island has its own compact composition
  but the same model, Core adapter, clipboard service and watcher.
- **Core adapter.** `CoreClient` runs
  `python -I -S -B <cli> <command> … --json` with a minimal environment
  (`HOME`, `PATH=/usr/bin:/bin`, UTF-8 locale). `-I -S` match the plugin
  launcher (no `PYTHON*` variables, no user site packages); `-B` keeps
  `__pycache__` out of the signed bundle. The working directory is the home
  folder and `doctor` always gets `--no-project`, so the Core never inspects
  an arbitrary project. stdout and stderr are drained concurrently; a call
  times out after 30 s; stdout is capped at 256 MiB.
- **Decoding order** (JSON_API.md §6): parse → `api_version` must be 1 →
  `ok` and exit code → payload. A traceback or empty output is
  `malformedOutput`; `ok: false` becomes `api(code, message)`.
- **Copy Response** always copies `final_response.text` from `show` (the full
  verbatim text), never a preview. The row buttons fetch `show` for their
  turn. The clipboard is written as plain text and read back; the
  confirmation appears only when the read-back matches scalar for scalar.
- **Copy Context** uses `context --json`. If the Core reports
  `sensitive_findings`, nothing is copied until the user confirms in an alert
  that lists kind, section and line (never the value), the same rule as
  `copy-context --allow-sensitive`.

## 4. Finding the Core and Python

CLI, first match wins: the `PromptRelayCLIPath` user default →
`$PROMPT_RELAY_CLI` (development) → the copy inside the bundle,
`Contents/Resources/core/bin/prompt-relay` (with `core/plugin/prompt_relay`
beside it, the repository's layout).

Python, first one that passes a `>= 3.9` check:
`PromptRelayPythonPath` user default → the pin in
`<data dir>/python-path` (only if the file is yours) →
`/opt/homebrew/bin/python3` → `/usr/local/bin/python3` → the python.org
framework → `/usr/bin/python3` only when `xcode-select -p` succeeds.

`PROMPT_RELAY_HOME` in the app's environment selects another data dir (tests
only).

## 5. Updating data

- `StoreWatcher` uses FSEvents (file-level events, 0.4 s latency) on the data
  dir and reacts only to `events/*.jsonl` and `config.json`. `handler.log` is
  ignored because every hook run writes it, even for projects that are not
  enabled.
- A change triggers one refresh: projects → sessions → turns → the selected
  answer. Refreshes coalesce (at most one running plus one queued). The full
  text is fetched again only when the selected turn changed.
- A file being appended while the Core reads it is handled by the Core
  (torn lines are skipped and counted); the next event triggers another
  refresh.
- Fallback: if the data dir does not exist yet or FSEvents fails, a 30 s
  timer runs **only while a surface is visible** and retries watching.
  Refresh (⌘R) always works. The status screen and the footer say which mode
  is active.
- There is no polling while the app is idle with no window open.

## 6. Privacy and safety
- No network code; no telemetry; nothing is logged by the app (no
  `os_log`/`print` of texts).
- The app never writes Claude Code settings, never touches the plugin or
  other tools' hooks (Coucou included), and never deletes history (there is
  no delete UI).
- The global shortcut uses the Carbon hot-key API: it sees only ⌃⌥⌘P, never
  other keystrokes, and needs no Accessibility permission.
- It reads only the Core's JSON output. It never opens project files; Copy
  Context's git summary comes from the Core's read-only git collection.
- The clipboard is written only on an explicit click.

## 7. Verification (2026-10-29, MacBook Pro M3 Pro, macOS 27.0.1, Xcode 27.0, Swift 6.4)
- `swift test`: 39 tests, 0 failures (1 opt-in render test skipped by default).
  They cover: decoding of every golden API answer; Unicode, Markdown,
  ambiguous, API-error and empty-store cases; unknown fields and enum values;
  Core errors (missing Python or CLI, traceback output, API version 2,
  `ok:false`, timeouts, launch failures, 3 MB output); the locator's Python
  rules (CLT stub, foreign pin, overrides); the clipboard service on a
  private pasteboard (NUL, CRLF, combining marks, emoji, 1.4 MB); the model's
  defaults, empty and error states, full-text copy, API-error blocking and
  the sensitive-context confirmation; FSEvents filtering; and an integration
  run against the real Python Core with a temporary data dir.
- Offscreen renders of all surfaces in light and dark (`SnapshotTests`,
  opt-in with `PROMPT_RELAY_SNAPSHOT_DIR`, `PROMPT_RELAY_SNAPSHOT_LIVE=1`
  for the user's own history, read-only), including the real Desktop answer
  captured through the plugin in Phase 2B.
- The installed app launched from `~/Applications`, idled at 0 % CPU, about
  120 MB RSS, and the bundle signature stayed valid after use.
- **Confirmed by the owner on the Mac:** the menu-bar icon opens the panel,
  Copy Response copies the answer, and ⌘V pastes it without loss.

Phase 3B (same Mac; two displays: built-in notched + external 4K):
- Xcode: workspace scheme "Prompt Relay" builds Debug and Release; ⌘U /
  `xcodebuild test` and `swift test`: 70 tests, 0 failures (1 opt-in render
  test skipped). New tests: state machine (dwell, grace, rapid hover with at
  most one timer, focus, pin, hidden), geometry and display choice with mock
  displays (external only, re-arranged, disconnected choice, small screen),
  settings persistence and Reduce Motion, controller lifecycle (frames per
  phase, display changes, 25 start/stop cycles without leaks, tracking area
  replaced not accumulated), yielding to Coucou, ‹ › navigation,
  ready-answer arrival/announce-once/restart, coordinator, and the no-halo
  rendering check.
- Real app on the real display (Debug capture): resting window 185 × 32 at
  the notch; expanded window 400 × 142 = exactly the island; only black and
  fully transparent pixels around it (264 anti-aliased edge pixels, no grey);
  back to 185 × 32 after closing; nothing placed on the external display.
- Idle with the notch on: 0 % CPU, ≈119 MB RSS (release) / ≈124 MB (Debug);
  0 Core (Python) processes in 30 one-second samples. Notch off: ≈118 MB, as
  in 3A.
- **Confirmed by the owner on the real screen:** the island opens from the
  physical notch, geometry and look are right, no grey halo, and the answer
  shows in the notch and in the main window.

## 8. Known limitations
- Coexistence with Coucou is implemented and unit-tested but was not observed
  live: Coucou was not installed or running on the test Mac (its hook files
  and `settings.json` hooks remain and were left alone).
- The island is black in light and dark mode by design; the window and
  menu-bar panel follow the system theme.
- Hover, animation and geometry were judged visually by the owner; the
  automated checks cover frames, states and pixels, not motion quality.
- Each Core call starts Python (about 40–60 ms); a refresh makes 3–4 calls.
  Fine for the current history sizes; SQLite or a long-lived Core are Phase 4+
  options (ADR-003/006).
- Memory: about 120 MB RSS at idle (unchanged by the notch), above the
  50 MB target in UI_RESEARCH. Not optimized; reaching it would mean a
  different architecture, which is not justified now.
- No app icon (the menu bar uses an SF Symbol); no settings UI for enabling
  projects, retention or deletion (use the CLI); no launch at login.
- A project path reported through a symlink (for example `/var` vs
  `/private/var`) can show up as two projects; Claude Code reports real
  paths, so this was seen only in tests.
- Offscreen renders cannot draw the sidebar's selected-row vibrancy or the
  key-window accent color; the live app does.
- Not notarized; local builds only.
