# Prompt Relay for macOS (Phase 3A)

A native SwiftUI + AppKit menu-bar app for reading Claude Code's captured
final answers and copying them with one click. It talks to the Python Core
only through the CLI JSON API v1 (ADR-006, ADR-009). It does not read the
JSONL store, does not re-implement correlation, has no backend and makes no
network connections.

## 1. Build and run

Requirements: macOS 14 or newer, Xcode (or the Command Line Tools with Swift
5.10+), and a Python 3.9+ for the Core. The Core's Python is found the same
way the plugin launcher finds it (§4).

```bash
scripts/build-macos-app.sh            # builds macos/build/Prompt Relay.app
scripts/build-macos-app.sh --install  # also copies it to ~/Applications
swift test --package-path macos       # Swift tests (39; one opt-in render test is skipped)
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
| Empty and error states | no projects yet, no sessions yet, nothing to copy (API error, still waiting, empty answer), Core or Python missing, unreadable Core output, newer API version — each with a short explanation and Try Again |

Wording follows the product invariants: a Stop is "Claude stopped", never
"done"; an inferred request link says "Request inferred from order"; an API
error is never offered as an answer.

## 3. Architecture

```
macos/
├── Package.swift
├── Sources/PromptRelayApp/main.swift        app lifecycle: scenes, menu-bar item, window routing
└── Sources/PromptRelayKit/                  everything reusable (also by the future notch UI)
    ├── Models/APIModels.swift               JSON API v1 types; open enums (unknown values never crash)
    ├── Core/CoreLocator.swift               finds the CLI and a Python 3.9+
    ├── Core/CommandRunner.swift             Process runner: no shell, drained pipes, timeout, size cap, off the main thread
    ├── Core/CoreClient.swift                runs `prompt-relay … --json`, checks version/ok/exit code, maps errors
    ├── Services/ClipboardService.swift      NSPasteboard write + read-back verification
    ├── Services/StoreWatcher.swift          FSEvents on the data dir (events/*.jsonl, config.json)
    ├── Presentation/AppModel.swift          the one @Observable model: data, selection, refresh, copy
    ├── Presentation/LoadState.swift, Formatting.swift
    └── UI/                                  components (rows, status badge, verbatim text view, copy bar,
                                             empty/error states, status screen) and surfaces (panel, window)
```

- **One model, several surfaces.** The menu-bar panel and the window observe
  the same `AppModel`. Phase 3B adds a notch surface that composes the same
  components (`TurnRow`, `CopyBar`, `ResponseDetailView`,
  `ConnectionFooter`); it does not need a second model or a second data path.
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
  other tools' hooks, and never deletes history (Phase 3A has no delete UI).
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

## 8. Known limitations
- Each Core call starts Python (about 40–60 ms); a refresh makes 3–4 calls.
  Fine for the current history sizes; SQLite or a long-lived Core are Phase 4+
  options (ADR-003/006).
- Memory: about 120 MB RSS at idle, above the 50 MB notch target in
  UI_RESEARCH. Not optimized yet.
- No app icon (the menu bar uses an SF Symbol); no settings UI for enabling
  projects, retention or deletion (use the CLI); no launch at login.
- A project path reported through a symlink (for example `/var` vs
  `/private/var`) can show up as two projects; Claude Code reports real
  paths, so this was seen only in tests.
- Offscreen renders cannot draw the sidebar's selected-row vibrancy or the
  key-window accent color; the live app does.
- Not notarized; local builds only.
