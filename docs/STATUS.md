# Status

Last updated: 2026-10-31, local Mac session (Phase 8 committed on the branch, owner validation pending),
branch `claude/loving-mccarthy-ossw3q`.

## Completed
- **Phase 0 — research & architecture**: docs, ADR-001…005, hook schema
  research, data model, threat model, UI foundation research.
- **Phase 1 — cloud-verifiable part**: hook handler, JSONL store,
  correlation, CLI (show / copy / context / copy-context / sessions / turns
  / enable / disable / delete / hook-config / doctor), and automated tests.
- **Core self-review** (`docs/SELF_REVIEW.md`): 14 confirmed defects fixed in
  `1d71087`, each with a regression test. The suite now has 79 tests.
- **Phase 1.5 — Mac validation, partial** (`docs/LOCAL_MAC_VALIDATION.md`
  §10): the main path **Claude Desktop → Stop hook → Prompt Relay → system
  clipboard** passed on a real Desktop run. Remaining checks are listed under
  "Requires macOS validation" below.
- **Phase 2A — Cloud Core for the app** (cloud): JSON API v1
  (`docs/JSON_API.md`, schema, ADR-006), 13 golden cases including the
  redacted real payloads, history management (`retention`, `prune`, `delete`
  preview/confirmation, active-session protection, ADR-007), storage path
  hardening. Two defects fixed with regression tests: the unlink race
  (a hook waiting on the lock of a deleted file lost its event) and a
  damaged duplicate line crashing an append. 105 tests.
- **Phase 2B — Claude Code plugin** (cloud; **main Mac check passed**
  2026-10-29, LOCAL_MAC_VALIDATION §11): plugin
  package `plugin/` plus a marketplace at the repo root (ADR-008,
  `docs/PLUGIN.md`), a POSIX launcher with interpreter pinning
  (`pin-python`, auto-pinned by `enable`), read-only `doctor --json`
  diagnostics (plugin records, settings hooks, double registration, observed
  `via=`), and the Core moved to `plugin/prompt_relay`. One defect found by
  the new tests and fixed: the launcher could not resolve its own directory
  with a minimal `PATH`. 137 tests.
- **Phase 3A — native macOS app** (Mac): SwiftUI + AppKit menu-bar app in
  `macos/` (ADR-009, `docs/MACOS_APP.md`): projects, sessions and answers,
  full verbatim answer, Copy Response / Copy Context through NSPasteboard
  with read-back confirmation, connection status from `doctor --json`, empty
  and error states, FSEvents live updates with a fallback. Integration only
  through the JSON API v1; the Core is bundled into the app. 39 Swift tests.
  The Python Core was not changed.
- **Phase 3B — notch UI and Xcode foundation** (Mac; accepted by the owner
  on the real screen): Dynamic-Island-style island around the MacBook notch
  (custom NSPanel + SwiftUI, ADR-010, `docs/MACOS_APP.md` §2B) over the same
  AppModel; Settings; "answer ready" indicator; coexistence with Coucou;
  `macos/PromptRelay.xcworkspace` with a Debug/Release app target and
  Previews. The first design was rejected in review (too large, window-like)
  and redesigned; a grey shadow halo found in review was removed with a
  regression test. 70 Swift tests. Python Core, plugin and JSON API unchanged.

## Verification matrix
### Verified in Cloud (real code, real processes, Linux)
| Item | Evidence |
|---|---|
| Hook handler: stdin parsing (any key order), event filter, allowlist, exit 0, empty stdout | `test_s01`…`test_s18`, `HookUnitTests` |
| Verbatim storage of Unicode, Markdown, nested fences, >100 KB, CRLF, NUL, lone surrogates | `test_s08`, `test_s09`, `test_lossless_roundtrip…` |
| Session separation, prompt_id linking, sequence/ambiguous labeling | `test_s02`, `test_s03`, `test_s12`, `CorrelationTests` |
| Duplicate delivery, concurrent writers (12 processes), crash-truncated line recovery, lock timeout | `test_s04`, `test_s05`, `test_s18` |
| Storage unwritable → handler exits 0 within bounds | `test_s11`; `test_s11b` passes as non-root (`nobody`) and is skipped as root |
| Background tasks and API-error statuses; API error never exported as a response | `test_s13`, `test_s14` |
| Copy Context: provenance labels, fence escaping, secret-scan blocking, read-only git (`.git` unchanged) | `ExportTests` |
| No network constructs in sources; sockets patched to fail during hook + all export commands | `test_s16`, `SourceSafetyTests` |
| No captured text in the repository or in `git status` | `test_s17` |
| Python 3.9 compatibility (macOS CLT version) | full suite on 3.9.25 and 3.13.17 |
| Documented hook schemas (all documented fields, three JSON encodings, verbatim, single storage) | `SchemaConformanceTests` |
| Hook entry point exits 0 when the package or Python is unusable | `test_hook_entry_point_exits_zero_when_package_missing` |
| Concurrent `enable` without lost updates | `test_concurrent_enable_keeps_every_project` |
| Repo-configured `core.fsmonitor` not executed during git collection | `test_repo_configured_fsmonitor_is_not_executed` |
| Hook latency | `scripts/check.sh`: median 72.6 ms, p95 88.2 ms (cloud VM, 20 KB payload) |

| JSON API: one ASCII document, empty stderr, schema-valid, `ok` ⇔ exit 0, usage errors as JSON, lossless Unicode | `test_api.JsonApiTests`, every golden query |
| Golden cases (13) incl. real Desktop/CLI payloads | `test_api.GoldenTests` |
| History management: preview by default, `--yes`, retention never automatic, active protection, changed-since-plan kept | `test_api.HistoryManagementTests` |
| Path safety: symlinked files/`events/` refused, foreign names ignored, nothing outside `events/` deletable | `test_api.PathSafetyTests` |
| Concurrent hooks + deletes: no lost event, no corruption | `test_concurrent_hooks_and_deletes_never_corrupt`, `test_hook_waiting_for_lock_survives_concurrent_delete` |
| GitHub Actions (Linux, Python 3.9 + 3.13) | green up to `7ef3368` (Phase 2A); Phase 2B run: see the final report |
| Plugin package accepted by the **real Claude Code 2.1.312 parser** | `claude plugin validate plugin --strict --json` (no errors, no warnings), marketplace validates, `claude --plugin-dir plugin plugin details` → "Hooks (3) UserPromptSubmit, Stop, StopFailure", ~0 tokens. Isolated HOME, no install, no API call (`ClaudeCliValidationTests`) |
| Plugin launcher: verbatim capture from a root with spaces/Unicode, cwd-independent, pin fallback, no-Python exit 0, missing package exit 0, `PYTHONPATH` injection ignored, root change after update keeps history | `test_plugin.LauncherTests` (launcher run as `/bin/sh <root>/hooks/run-hook`, like Claude Code) |
| Plugin + settings hook at the same time → event stored once | `test_double_registration_stores_each_event_once` |
| Foreign (NotchBuddy-like) hooks: counted, never printed, settings bytes unchanged | `test_plugin.CoexistenceAndDiagnosticsTests` |

Test run, Phase 2B (2026-10-29, cloud): Python 3.13.17 — 137 run, OK,
1 skipped (root-only permission test); Python 3.9.25 — 137 run, OK,
1 skipped; as user `nobody` — 137 run, OK, 0 skipped. Failures: 0.
Hook latency: `bin/prompt-relay hook` median 72.5 ms, plugin launcher median
88.0 ms, p95 106 ms.

### Verified on macOS (2026-10-29, real Mac, real Claude Desktop)
| Item | Evidence |
|---|---|
| Environment | macOS 27.0.1 arm64 M3 Pro; Python 3.9.6 (Xcode), 3.11.14, 3.14.0; CLT installed; CLI 2.1.268; Desktop 4.29.0 with Claude Code 2.1.309 (D4) |
| Automated suite | 81 tests (79 + 2 added in Phase 1.5), OK, **0 skipped**, on all three Pythons. First run found one test defect (`test_s17` hard-coded the Linux data path), fixed |
| Real clipboard, byte-exact | 11 cases incl. Cyrillic, emoji/ZWJ, Markdown, nested fences, CRLF, C0 controls, **NUL (D5: preserved)**, 1.18 MB; read back via `pbpaste` and NSPasteboard |
| Real Desktop hooks | UserPromptSubmit + Stop fired from the sandbox `.claude/settings.local.json` and were stored in the isolated data dir |
| `prompt_id` on Stop (D1) | present and equal to the prompt's → `link=prompt_id` |
| Full final response | Stop `last_assistant_message` equals Claude's final text in the session transcript, byte for byte |
| `agent_id` on a main turn (D6, partial) | absent on both events of a main-session turn |
| CLI shows the right session and text; `copy --verify` | passed on the captured Desktop answer (real pbcopy) |
| Real CLI UserPromptSubmit | stored via `claude -p --settings`; `prompt_id` present |
| Data isolation | `hook-config --data-dir` keeps Desktop hooks in the validation dir; the default data dir was never created |
| Hook latency | median 37.1 ms, p95 39.3 ms |
| `~/.claude/settings.json` unchanged | SHA-256 identical before and after; other tools' global hooks untouched |

Real payloads (redacted) are fixtures: `tests/fixtures/real_*.json`.

### Verified on macOS — Phase 2B plugin (2026-10-29)
| Item | Evidence |
|---|---|
| Phase 2A + 2B suite on macOS | 137 tests on 3.9.6 / 3.11.14 / 3.14.0, OK, 1 skipped by design (no-Python path, covered on Linux); `ClaudeCliValidationTests` ran against CLI 2.1.268 |
| Official install from the local marketplace | `claude plugin marketplace add` + `install`, scope user; `details`: 3 hooks |
| Desktop → plugin → Stop → storage → copy → clipboard | `via=plugin` UserPromptSubmit + Stop, same `prompt_id`, full final text, `copy --verify` passed |
| No double write | 2 records, no `duplicate`; Prompt Relay ran once per event (`stop_hook_summary`) |
| Coexistence with NotchBuddy | both ran on Stop, `hookErrors: []`; `hooks`/`permissions` in `~/.claude/settings.json` identical |
| Launcher interpreter | pinned Xcode Python 3.9.6 used (`doctor`: hook python ok) |

### Verified on macOS — Phase 3A app (2026-10-29)
| Item | Evidence |
|---|---|
| Build | `scripts/build-macos-app.sh` (Xcode 27.0, Swift 6.4, macOS SDK 27.0), ad-hoc signed; signature still valid after use (`-B`: no bytecode in the bundle) |
| Swift tests | 39 run, 0 failures, 1 opt-in render test skipped by default |
| Real Core from the app | integration tests against the checkout's Core with a temp data dir; the bundled Core lists the real session |
| Real history in the UI | offscreen renders with the user's history (read-only): the Phase 2B plugin answer, status screen with 5 `via=plugin` events |
| Owner's check | menu-bar icon opens the panel; **Copy Response** copied the answer; ⌘V pasted it without loss |
| Idle cost | 0 % CPU, ≈120 MB RSS |

### Verified on macOS — Phase 3B notch UI (2026-10-29)
| Item | Evidence |
|---|---|
| Xcode | workspace scheme "Prompt Relay": Debug and Release BUILD SUCCEEDED; `xcodebuild test`: 70 tests, 0 failures (1 opt-in render test skipped) |
| `swift test` | 70 tests, 0 failures, stable across repeated runs |
| Real panel geometry | Debug capture on the built-in display: resting 185 × 32 at the notch; expanded 400 × 142 = the island; back to 185 × 32; nothing on the external display |
| No halo | only black and transparent pixels around the island (264 anti-aliased edge pixels); `NotchAppearanceTests` fails if a shadow returns |
| Idle cost | notch on: 0 % CPU, ≈119 MB RSS, no Python in 30 s of sampling; notch off ≈118 MB |
| Owner's visual check | island opens from the physical notch; geometry and look correct; no grey halo; answer shown in the notch and main window |

### Verified with Mocks
| Item | Mock |
|---|---|
| Copy Response / Copy Context to the clipboard, byte-exact, `--verify` read-back | file MOCK clipboard (`PROMPT_RELAY_CLIPBOARD=file:…`) |
| pbcopy invocation: exact argv, UTF-8 bytes, UTF-8 locale, no shell | `subprocess.run` patched (`test_pbcopy_backend_sets_utf8_locale`) |
| macOS default data path | `paths.data_dir(platform="darwin")` |
| Same directory under another spelling (case-insensitive APFS) | `os.stat` patched (`test_enabled_project_matched_by_identity`) |
| Hook payloads | synthetic fixtures copied from the documented examples, not captured from a real Claude run |

### Implemented, requires macOS validation
| Item | How to validate |
|---|---|
| Manual ⌘V paste of a copied answer into another app (TextEdit) | M2 — not done: the clipboard was overwritten before pasting |
| CLI Stop (`claude --settings`) | M3 — blocked: the CLI's OAuth session had expired (log in first) |
| Interrupt with Esc → no Stop, turn stays pending | M6 |
| Background task: `stop_received_background_tasks_pending` and the wake-up Stop (D3) | M3/M4 prompt 3 |
| Multi-tool final text (D2) | M3/M4 prompt 2 |
| Several messages in one session; two parallel sessions (M5) | M4/M5 |
| StopFailure from a real API error (M8). Observed: an expired-OAuth failure in CLI 2.1.268 fired **no** StopFailure | M8 |
| `agent_id` with a subagent turn (D6) | M3 prompt 5 |

| JSON API consumed by a Swift client (`JSONDecoder`, surrogate pairs) | Phase 3 |
| Plugin: CLI hooks via the plugin; update/reload (M14); disable and uninstall keep history (M15) | LOCAL_MAC_VALIDATION §11 |
| Launcher fallback without a pin (Homebrew / CLT order) on macOS | M11 with `pin-python --clear` |

### Not Implemented (by design in this phase)
App settings for enabling projects, retention and deletion (the app has interface settings only), launch at login, app icon, notarization, settings-merge installer (not needed: plugin
first, ADR-008), ChatGPT integration, clipboard import, encryption at rest,
SessionStart/SessionEnd/Notification handling, automatic pruning (deliberately
never automatic), per-record expiry inside a session.

## Known risks
1. Real payloads may differ from the docs (for example `prompt_id` missing
   on Stop). Mitigation: order-based fallback with explicit labels; real
   payloads will become fixtures.
2. `last_assistant_message` may hold only the final text block of a
   multi-tool turn (D2). Prompt Relay copies exactly what Claude Code
   provides.
3. pbcopy and NUL / unusual characters (D5).
4. The Core needs some Python 3.9+ on the Mac (the CLT's `/usr/bin/python3`,
   Homebrew or python.org; ADR-004). The app will need the same path (ADR-006).
5. History is stored unencrypted (SECURITY §3).
6. The OpenNook API is not frozen, and it requires macOS 15+ (UI_RESEARCH).
7. `git status` can run a clean filter configured in a project's
   `.git/config` (SECURITY T9). The risk equals running git there yourself.
8. Without `prompt_id`, an interrupt or a prompt blocked by another hook
   makes the next answer `ambiguous` (by design).
9. JSON API v1 is not frozen until the first app build (JSON_API.md §6.6).
   After that, changes follow the compatibility rules.
10. Each JSON call starts Python (about 50–100 ms). The app must cache and
    refresh on file changes, not poll in a tight loop.
11. The 30-minute active-session grace is a heuristic (ADR-007).

## Cloud environment notes
- Swift toolchain unavailable: `download.swift.org` is blocked by the
  egress policy (HTTP 403). This drove ADR-004.
- No real Claude request was made to test hooks. The installed Claude Code
  2.1.312 binary contains the expected field names (HOOKS_RESEARCH §1).

## Phase 1.5 changes
- `hook-config --data-dir DIR`: the hook runs as `/usr/bin/env
  PROMPT_RELAY_HOME=DIR <python> bin/prompt-relay hook` (exec form, no shell),
  so isolated checks work in Claude Desktop, which does not pass the shell
  environment to hooks. Test: `test_hook_config_data_dir_isolates_hooks_without_env`.
- `test_s17` now resolves the platform data dir instead of the Linux path.
- Validation guide: every step uses an isolated `$PR_VAL/data`; the cleanup
  removes only the marked validation workspace and never runs `delete --all`
  on the default data dir.
- Real redacted fixtures and `test_real_desktop_turn_links_by_prompt_id`.

## Phase 2A changes
- New: `api.py` (JSON API v1), `retention.py` (history management),
  `docs/JSON_API.md`, `docs/api/api-v1.schema.json`, `tests/test_api.py`,
  `tests/jsonschema_lite.py`, `tests/golden/`.
- CLI: `--json` on projects/sessions/turns/show/context/delete/prune/retention;
  new `prune` and `retention`. `delete` now previews without `--yes`
  (still exit 2), has `--dry-run`, and keeps active sessions unless
  `--force-active` (exit 6). `--session` also accepts a `session_key`. Text
  output of the existing commands is unchanged, except that context
  timestamps now have microseconds.
- Store: `O_NOFOLLOW`; symlinks and non-session names in `events/` are
  ignored; a symlinked `events/` is refused; `safe_unlink`; reopen after a
  concurrent unlink; damaged-epoch dedup fix. `Store.delete_path` and
  `delete_all` were removed in favour of `retention`.
- config.json: optional `retention_days` (old readers ignore it).

## Phase 2B changes
- Layout: `prompt_relay/` → `plugin/prompt_relay/` (git mv). `bin/prompt-relay`
  and the tests import from `plugin/`. `hook-config` defaults to the
  checkout's `bin/prompt-relay`.
- New: `plugin/.claude-plugin/plugin.json`, `plugin/hooks/hooks.json`,
  `plugin/hooks/run-hook`, `plugin/hooks/prompt_relay_hook.py`,
  `.claude-plugin/marketplace.json`, `runtime.py`, `integration.py`,
  `docs/PLUGIN.md`, `tests/test_plugin.py`, ADR-008.
- CLI: `doctor --json --project/--no-project` (new `doctor_data` in schema
  v1, a compatible addition), `pin-python`. `enable` pins the running
  interpreter if no valid pin exists.
- `handler.log` lines gain `via=plugin|direct` before the outcome.
- Version 0.2.0 (package and plugin manifest).

## Phase 2B Mac validation (2026-10-29)
- Main path passed: Claude Desktop → plugin hook → storage → Copy Response →
  clipboard (LOCAL_MAC_VALIDATION §11, M10–M13).
- Discrepancy fixed in the docs: a local-path marketplace install is copied
  into `~/.claude/plugins/cache/…/<version>/`; it is not loaded in place
  (PLUGIN.md §2, ARCHITECTURE). No code defect was found; no code changed.
- The plugin stays installed (user scope) with capture on for the sandbox
  only.

## CI fix after Phase 2B (cloud, 2026-10-29)
GitHub Actions run 40910039983 (`ab57b74`) failed on Linux / Python 3.13:
`test_context_git_section_and_read_only` saw `.git/objects` mtime change.

- **Cause:** a race in the test setup, not a write by `gitinfo.collect()`.
  The test's own `git commit` starts `git maintenance run --auto`, which on
  git ≥ 2.47 (the runner has 2.56.0) detaches. It holds
  `.git/objects/maintenance.lock` after `commit` returns and removes it
  later. This was confirmed in git 2.56 sources: `run-command.c`
  `prepare_auto_maintenance` and `builtin/gc.c` `maintenance_run_tasks`.
  Locally (git 2.43) maintenance runs in the foreground, so the failure
  could not show there.
- **Fix:**
  - Fixture repos are created with `maintenance.auto=false`/`gc.auto=0`.
  - The `.git` snapshot got stricter: SHA-256 and size per file, in
    addition to all mtimes.
  - Hardening: `gitinfo` passes the same two settings, so no future git
    version can start maintenance from the read-only collection.
- **Regression tests:**
  - `test_git_fixture_starts_no_maintenance`;
  - `test_git_collection_never_starts_maintenance` (trace2, repo with
    auto-maintenance on);
  - `test_git_dir_snapshot_detects_transient_writes`.

  Both fixes were checked by mutation: with either one removed, the
  matching test fails.
- **Not reproduced:** the exact detached race on git 2.56 in the cloud.
  Building git 2.56 here was not permitted, so CI on git 2.56 is the check.

## Phase 3A changes
- New: `macos/` (Swift package), `scripts/build-macos-app.sh`,
  `docs/MACOS_APP.md`, ADR-009.
- No change to the Python Core, the plugin or the JSON API.
- Known limitations: `docs/MACOS_APP.md` §8 (Python start per call, ≈120 MB
  RSS, no settings UI or app icon, local signing only).

## Phase 3B changes
- New: `Sources/PromptRelayKit/Notch/` (geometry, state machine, controller,
  views, settings, coordinator, hot key), `UI/PreferencesView.swift`,
  `Services/ReadyNotifier.swift`, `Previews/PreviewSupport.swift`,
  `macos/Xcode/` (project, Info.plist, shared scheme),
  `macos/PromptRelay.xcworkspace`, ADR-010.
- AppModel: ready-answer tracking across projects (one extra `sessions`
  call, only while the notch or notifications are on), remembered "seen"
  answer, `revealReadyAnswer`, background observation without the fallback
  timer, `refreshNow` now waits for a refresh already running (a defect found
  by the new tests), and no Python call when a surface opens while FSEvents
  is live.
- Known limitations: `docs/MACOS_APP.md` §8 (Coucou coexistence not observed
  live, black island in both themes by design, ≈120 MB RSS).

## Phase 3C changes (implemented, not committed)
- Settings → Projects: Add Project (folder picker, path only, capture off),
  capture switch through `prompt-relay enable|disable`, inherited capture,
  removal of added-only folders (history untouched). Settings → Status:
  Core/Python, plugin, selected project's capture, last captured answer,
  with actions when something is missing.
- The app opens on and follows the newest finished answer unless the user
  is looking at another one; copy hides nothing.
- 82 Swift tests at the end of 3C. The owner's real check (add a project in
  Settings, new answer in the notch, Copy Response, capture off) has not
  been confirmed in chat yet.

## Phase 3D.1 changes (redesigned, not committed, awaiting visual review)
- First version (tabs Answer / Projects / History in a fixed 440 × 340
  workspace, plus the old windows) was **rejected** by the owner: it looked
  like a shrunken desktop app. Backups of that state and of Phase 3C are in
  the session scratchpad (`tracked.patch`, `untracked.tar`).
- Redesign (`docs/PRODUCT_UX_SPEC.md`): one island. Resting / Quick Peek /
  Expanded; Home = project picker, status, request, answer, Copy Response,
  Review Pack, Recent, All Responses, ⚙, ⋯ (Quit). Projects (capture
  switches, Add Project with the island held open), Recent, All Responses,
  Settings (General, Capture, Connection, About) and Full Response open
  inside the island with Back/Esc. Navigation: `AppModel.route`.
- Height follows content in every state (56–388 pt below the band, ≤ 60 %
  of the display); lists scroll inside with a fade.
- Displays without a notch: the same island floats below the menu bar,
  opened from the menu bar or ⌃⌥⌘P.
- App shell: no regular windows; the menu-bar item is a small menu (Open,
  Recent, All Responses, Settings…, Quit). "Open on hover at the notch" is
  now on by default (the island is the interface).
- Debug/Release: Debug is named "Prompt Relay Dev" (display name) with its
  own menu-bar icon; Release steps aside at the notch while Debug runs; a
  dot on ⚙ and Settings → About name the other build and offer to quit it
  on request.
- Fixed with a regression test: a relayout re-showed the resting panel
  with hover turned off.
- Verified on this Mac: `swift test` 98 tests, 0 failures (1 opt-in render
  test skipped); Xcode Debug and Release BUILD SUCCEEDED; `xcodebuild test`
  98 tests, TEST SUCCEEDED; the real panel captured on the built-in display
  (Debug build, real data): resting 185 × 32, peek 440 × 131, Home 440 ×
  188, Projects 171, Recent 94, All Responses 125, Settings 388 (scrolls),
  Full Response 122, back to 185 × 32; idle 0 % CPU, ≈137 MB RSS.
- Not verified: a real pointer (hover, clicks while open, the ⋯ menu, the
  folder picker) and the floating island on a real external display — the
  capture drives the same state machine without a mouse. Needs the owner's
  check on the real screen.

## Phase 4 changes (implemented and tested; owner validation pending)
- Recovery point before any change: `refs/backup/phase4-start` (all tracked
  and untracked work of 3C and 3D.1), plus patch/tar copies in the session
  scratchpad.
- Single island, redesigned (`PRODUCT_UX_SPEC.md`, ADR-011): Home answers
  project / task / answer / which button; graphite cards on black; one white
  primary action; Projects, Recent Copies, History (search, pins, imports),
  Import, Settings (plain language; Diagnostics only there) and Full Report
  (formatted or exact text, always complete) inside the island. Removed:
  the main, status and settings windows, the old menu-bar panel, the ⋯ menu,
  the duplicate "Recent answers" view, the Debug badge.
- Reports: `ReportRef` for local turns and imports; Review Pack gets a
  "Review Pack" title and a "Source" line in the Core (the only Core change;
  goldens updated) and an app-written pack for imports in the same format.
- Cloud: researched in the official docs (cloud sessions run on Anthropic
  VMs; local hooks cannot see them; `--teleport` changes the repository);
  manual Import with verbatim storage, dedup and provenance labels.
- Attachments: images added by the user, private copies with checksum;
  Copy Image, drag, Copy Text + Images (multi-item pasteboard).
- Relay the bear: original vector mascot, facts-only moods, pointer gaze
  only inside the island, blinking only while visible, Reduce Motion and an
  off switch.
- Debug/Release: Debug is "Prompt Relay Dev" with its own icon; Release
  steps aside at the notch while Debug runs; Settings → About offers to quit
  the other build on request. Root cause: two bundle IDs launched at once.
- Verified on this Mac: `swift test` and `xcodebuild test` 109 tests,
  0 failures (1 opt-in skipped); Xcode Debug/Release BUILD SUCCEEDED;
  Python 141 tests OK; a 100 KB+ report through the real hook (twice) copied
  byte-identical; real island captured in every view; idle 0 % CPU,
  ≈164 MB RSS (Debug).
- **Not verified (needs the owner):** text + images pasted into ChatGPT
  (desktop and web); a real cloud report import; a real long local report
  through the new UI; the floating island on an external display; real
  pointer hover/focus after the redesign.

## Phase 4 real-session audit (2026-10-30)
- Found: the prompt-relay repository itself was not captured (only the two
  sandboxes were enabled). Capture was enabled for it with `prompt-relay
  enable` (the previous `config.json` is kept in the session scratchpad).
- **Real capture, byte-level:** the final answer of this Claude Code session
  (Desktop, installed plugin 0.2.0) was stored by the hook: 4040 UTF-8 bytes,
  SHA-256 `b047601d…`, byte-identical to the same message in the session
  transcript. Its request is labeled unavailable (the prompt came before
  capture was on).
- Through the app's own code on the real store (read-only, private
  pasteboard; opt-in `RealSessionAuditTests`): Full Report text, Copy
  Response bytes and the Review Pack (the report exactly once) equal the
  transcript bytes; the Formatted reader drops no line.
- Defects found and fixed, each with a regression test:
  1. Sending the next prompt hid the previous answer: the session's last
     turn was "awaiting response", so the newest answer fell back to an
     older session in another project and the island would switch to it.
     The newest finished answer of such a session is now kept (one cached
     `turns` call). Seen on the real store: "Last capture" showed
     sandbox-a; it now shows this session.
  2. Recent Copies named the folder Claude ran in (possibly a subfolder),
     not the enabled project.
  3. A code block inside a list item kept the list's indent on every line.
- Manual paste kit for ChatGPT: `PasteInteropKit` (opt-in) writes a known
  text and a generated test image to the general pasteboard with the app's
  own clipboard code. Not run by the agent (it would overwrite the owner's
  clipboard); the result is pending.
- Memory: Release build idle ≈91 MB; Debug with the real data and the
  island open in every view ≈149 MB; 0 % CPU idle.
- Not verifiable by the agent: real pointer hover and the mascot's eye
  movement, image paste into ChatGPT, a real cloud import.

## UI/UX polish, Review Pack and mascot (2026-10-30)
- **Spacing:** the content was laid out from the window edge, but the notch
  outline's sides stand 14 pt in from it, so cards sat ≈4 pt from the
  visible side. One rule now (`IslandMetrics`, measured from the visible
  side): 22 pt sides, 22 pt bottom, 12 pt between blocks; tighter on short
  displays and in Quick Peek; band and cards share one left edge; island
  480 pt wide. Regression tests render the real views and check blocks and
  buttons against the outline (also with the copy line shown, on a 380 pt
  display).
- **Response scrolls inside its card** (76–260 pt by display height), Home
  never clips; the wheel scrolls only the answer (no nested scroll); a
  different answer starts at its top; View Full Report kept; Copy Response
  copies the original whatever is scrolled. Tested with real scroll-wheel
  events on the rendered view.
- **File picker:** it opened under the island (the panel is above normal
  windows). Now the island steps aside synchronously before `NSOpenPanel`
  shows and returns as it was (view, report, frame, keyboard) on a choice,
  Cancel or Esc; one dialog at a time; images go to the report the picker
  was opened for; unreadable files are named. Same path for Add Project.
  Tested with an injected picker; the real dialog needs the owner.
- **Relay:** 22/24 pt (≈ +25 %), redrawn eyes with highlights, ears perk
  when curious; smooth eye and head movement toward the pointer (tilt ≤ 7°),
  back to neutral on exit; copy: hop + happy closed eyes; failure: worried
  brows + head shake (no success reaction). Reduce Motion respected.
- **Review Pack tests:** the response is now read back out of the pack
  (`ReviewPackReader`) and compared byte for byte; the whole pack is not.
  Real data: this session's turn 2 (request «продолжи где остановился»,
  linked by `prompt_id`): captured 5253 bytes, SHA-256 `528b4684…`, equal to
  the transcript, to Full Report, to Copy Response and to the response
  extracted from the Review Pack; appears once; reader drops no line.
- "Continue where you stopped": proposal only (PRODUCT_UX_SPEC §12); needs a
  Core change, not made.
- Swift 125 tests (4 opt-in skipped), `scripts/check.sh` OK, Xcode Debug and
  Release build. Release idle, island not drawn (yields to the running Debug
  build), same conditions: before 20 MB footprint / 87 MB RSS, after 21 MB /
  91 MB; 0 % CPU both.
- Not verified by the agent: real pointer hover, eye/head following and the
  copy reaction in the running app; the real NSOpenPanel above/under the
  island; memory with the island open on a long real report.

## UX polish 2: attachments, file picker, Relay, Review Pack audit (2026-10-30)
- Context: the owner's real-Mac check ran the Debug build started 12 h
  earlier from `2c7249d`, i.e. without the first polish. Both rounds are in
  the working copy; backup ref `refs/backup/ui-polish-1` (first round).
- **Defects found and fixed:**
  1. Images showed nearly island-wide: a `Menu` with an image label is drawn
     by AppKit at the image's own size. Now compact file cards (thumbnail
     decoded at 96 px, name, type, size, ⋯, ×) in one sideways row.
  2. NSOpenPanel under the island (the panel's level is above normal
     windows). The island steps aside before the dialog shows and returns
     after it; the shortcut and the menu bar bring an open dialog forward.
  3. Attachments were typed by file extension and a damaged PNG was
     accepted; now typed by content, damaged and permission-denied files
     are named. Removal could leave a record pointing at a deleted file and
     never reported failures; now index first, file only when unused,
     errors shown. A stored name in the index could point outside the
     folder; now refused.
  4. Copy Image / file drags used the private name ("3f2a….png"); now
     hand-off copies under the original names (`<data dir>/app/handoff/`,
     rebuilt on each use).
  5. Pasted prompts showed `<pasted_content id="…">` in the Task card and
     History (seen on the real store); display now drops the wrapper (copies
     and the Review Pack stay verbatim).
  6. A spring animation on Relay's gaze redrew the panel at the display
     rate: ≈ 26 % CPU while the pointer moved. Now eased at 30 fps until it
     arrives: ≈ 2 %.
  7. Home overflowed on short displays (≈ 420 pt, "Larger Text") with
     images: compact cards and a one-line task there.
  8. The local Review Pack listed images after "Request for review"; now
     before "Tests and CI" (anchored on the Core's own last heading).
- **Relay** follows the pointer anywhere on screen (global + local mouse
  monitors, no permission, no key events, ≤ 30 updates/s, no stored
  positions; stops when hidden, asleep, under Reduce Motion or a dialog),
  28 pt, ears 38 pt.
- **Review Pack audit** (real turns 2 and 3 of this session): Copy Response
  = transcript bytes (5253 B `528b4684…`; 8573 B `df3b8dbe…`); the response
  read back from the pack is identical, once, fenced longer than its own
  fences; source, project, session, turn, status and git state correct and
  labeled; Claude's claims [Not verified]; imports labeled as pasted by the
  user; images listed by name/type/size, "sent separately", no claim they
  were sent. Finding: the Project line includes the absolute path (user
  name) — Core change proposed in ADR-012 with earlier requests of the
  session for «продолжи где остановился»; not implemented (Core change).
- Tests: Swift 142 (6 opt-in skipped), Python 141 (`scripts/check.sh` OK),
  Xcode Debug and Release build. Real AppKit checks: scroll-wheel routing
  through the real panel; the real NSOpenPanel (opt-in, Esc and Cancel).
  Release idle (island yields to the running Debug build): 19 MB footprint,
  89 MB RSS, 0 % CPU.
- **Not verified by the agent (needs the owner):** keyboard focus of the
  real dialog after a real click on 📎; trackpad scrolling by hand; Relay
  following the real pointer; pasting or dropping images into ChatGPT (app
  and web) by each method.

- **Owner check (2026-10-30):** the owner checked both polish rounds on the
  real Mac and reported "All good"; committed on the branch, not pushed.

## Phase 5 implementation (2026-10-30; committed on the branch, not pushed)
Plan: `docs/PHASE5_PROPOSAL.md` rev 3.1 (R1–R11), ADR-013…016. Commits:
`7312d1c` (plan, ADRs), `7182436` (Core), `859c044` and `8679c76` (app),
plus this documentation commit. Backup refs `refs/backup/phase5-*`.

**Stages:** 5.0 done · 5.1 done in a Claude Desktop sandbox (the CLI is
logged out; V1 latency at scale and V5d `-p` teardown not observed) · 5.2,
5.3, 5.4, 5.5, 5.6, 5.7, 5.8 (step 2 hand-off; the ChatGPT paste matrix V8
is the owner's), 5.9 implemented · 5.10 (local rendering of mockup states)
not started: it waits for a separate security approval · 5.11 partly (see
below).

**Defects found in real payloads and fixed (regression tests):**
1. Background-task notifications and subagent hand-backs arrive as
   UserPromptSubmit with the turn's `prompt_id`; the Core made each a new
   turn "awaiting response" after Claude had stopped.
2. Publishing an Artifact arms a `monitor` background task that keeps
   running; every later Stop was "background tasks pending", shown as
   "tasks still running" (5 of 12 real Stops on this Mac). Monitors are now
   reported as watchers, not work in flight.
3. Opening the island revealed the newest answer of any session and
   replaced the session the user was reading (`revealReadyAnswer`).
4. `ClipboardImageHistory.poll()` worked while the mode was off (guarded).
5. Truncated labels and a duplicated time found in renders of the real
   history.
Also: the island's preference keys (`IslandFramesKey`, `BoundedScrollHeight`)
replaced by geometry callbacks; the scroller no longer depends on the
measured height; the window no longer forces a display inside SwiftUI's
layout pass. The Xcode warnings themselves were **not reproduced** here
(they are not in the system log of the test process): the owner's Xcode
console is the check.

| Item | Status |
|---|---|
| Python suite (3.11+ and Xcode's 3.9.6), `scripts/check.sh` | **Automated: 155 tests OK** (1 skipped by design); hook latency median ≈ 40 ms |
| Real plugin validation | `claude plugin validate plugin --strict`: no errors (CLI 2.1.268, no install) |
| Tool events in a real Desktop session (sandbox, capture-only hooks) | **Verified on this Mac** (22 events, redacted fixture) |
| Plugin 0.3.0 with the tool hooks installed for real | **Not done**: the owner installs it (`claude plugin` commands) |
| Swift `swift test` | **Automated: 161 tests, 0 failures** (6 opt-in skipped) |
| Xcode Debug and Release builds | **BUILD SUCCEEDED** both |
| Session switching, pinning across launches, "New in …" | Automated (fake Core); real history rendered: the two real `prompt-relay` sessions are separate and titled |
| Copy for ChatGPT on a real turn of this session | Verified with the real Core: response once, byte-exact, no absolute paths, "Watchers at Stop: 1" |
| Typed attachments, mockup states, hand-off names and order, suggestions | Automated (real files, real ImageIO/PDF, temp store) |
| Clipboard image history | Automated with a private pasteboard; **not verified** against macOS 27's paste-privacy prompt (V6) |
| Relay at rest: bounds, no camera overlap, no clipping | Automated: math for every pose and the **rendered** SwiftUI view at 4× (9 gazes × moods) |
| Relay motion feel, breathing, copy joy on the real screen | **Not verified**: needs the owner's eyes |
| Relay CPU (Debug test harness, pointer at 120 Hz) | idle ≈ 0 % over the loop; moving ≈ +6–8 points over the loop (Phase 4 code, same harness: +3.4). Release app not measured |
| Paste of text and files into ChatGPT Desktop / Safari / Chrome (V8) | **Not verified**: the owner's matrix |
| Local rendering of mockup states (5.10) | **Not implemented** (needs approval) |

## Phase 5.11 stabilization (2026-10-30; committed on the branch, not pushed)
Commits `564740b`, `44be234`, `44891a3`, `d573218`, `8b9b97b` and this
documentation commit. Backup ref `refs/backup/phase5.11-start` (= `ee9d359`).

**Plugin 0.3.0.** The `prompt-relay` marketplace is a `directory` source
pointing at this checkout. Claude Desktop already ran the working tree's
0.3.0 hooks (tool events stored `via=plugin`) while the registry still said
0.2.0; `claude plugin update prompt-relay@prompt-relay` recorded 0.3.0
(`Hooks (5)`), `~/.claude/settings.json` unchanged (SHA prefix 49269c3b).
Registry backup: `~/Library/Application Support/PromptRelay/backups/`.

**End-to-end on this Mac (real Claude Code, two sessions of project
`~/prompt-relay-validation/e2e-511`).** The worker session ran `echo`
(exit 0), a failing command (exit 4), `unittest` (exit 0), an Edit, a
script that wrote `blue.png` and a Write of `REPORT.md`; the viewer session
only answered. Stored: 4 commands with the right exit codes, 2 files
changed, each session separate. Copy Response = stored answer byte for
byte; Copy for ChatGPT holds the answer once, `exit 4`, the files and Git
state. `RealHandoffE2ETests` (opt-in) on that turn: suggestions for all
three files with their real source, pack, and step 2 — the three files on
a private pasteboard are byte-identical to the originals. Pasting into
ChatGPT was **not** verified (owner, `docs/OWNER_CHECKS_5_11.md`).

**Defects found and fixed (each with a regression test):**
1. A turn Claude Code starts itself (side session reporting back) was
   exported as "Original user request" with `<system-reminder>` /
   `<side-sessions-event>` text. Origin classification, ADR-017.
2. Titles and the Task card showed a leading `<system-reminder>`; requests
   carry `display_preview`; titles drop harness blocks; a session not
   started by the user takes Claude Code's title when one exists.
3. A failed non-test command left the chip at "1× exit 0":
   `observed.commands_nonzero`, failures shown first.
4. A file made by a script and named in the answer was not suggested; now it
   is, labelled "named in Claude's answer … not seen being written
   [Reported by Claude]" (never "Confirmed").
5. The step-2 bar pushed the copy line out of Details.
6. "layout during layout": traced with lldb (`_NSDetectedLayoutRecursion`)
   to `NotchController.resize` changing the window frame inside SwiftUI's
   layout pass; now done right after the pass. `scripts/check-layout-recursion.sh`: 0 hits.
7. "Invalid frame dimension": negative resting size without a notch.
8. Relay CPU while the pointer moves (below).

**Xcode warnings, real app log (`log show`, owner's Xcode runs).** Runs at
11:23 and 15:00 (before Phase 5) logged `Bound preference IslandFramesKey /
BoundedScrollHeight … multiple times per frame` and the layout recursion.
The Phase 5 Debug build started 16:02 ran 4.5 hours with **no**
preference warnings; it still logged the layout recursion once (fixed in
`d573218`, needs a rebuild to confirm on screen).

**Relay CPU** (same harness for Phase 4 `f72a8ce` and Phase 5, optimized
`-c release` test build with DEBUG test hooks, pointer at 120 Hz, medians of
4 alternating runs): moving minus the harness loop — Phase 4 4.50, Phase 5
before 6.05, after 5.15 percentage points; at rest 1.04 vs 1.07 %; RSS 57 MB
both. Frames published while moving fell from ≈ 19 to 11–12 per second
(gaze/head published only for steps ≥ 0.07 pt or on arrival). A main-thread
sample at rest shows no periodic work. Breathing runs in WindowServer; its
cost could not be separated from the system's (≈ 44 % WindowServer
background). The Release app itself was not profiled.

| Item | Status |
|---|---|
| Python suite (3.11+ and 3.9.6), `scripts/check.sh` | **Automated: 168 tests OK** on both (1 skipped); hook median 40 ms |
| Swift `swift test` | **Automated: 172 tests, 0 failures** (7 opt-in skipped); `plugin validate --strict` passed |
| Xcode Debug and Release (`Prompt Relay` scheme) | **BUILD SUCCEEDED**, 0 compiler warnings |
| Tool events, two sessions, Copy Response / Copy for ChatGPT | **Verified on this Mac** (real Claude Code turn) |
| Files to the clipboard (step 2) | **Verified** on a private pasteboard, byte-identical |
| Paste into ChatGPT Desktop / Safari / Chrome (V8) | **Not verified** (owner) |
| Relay feel on the real screen, Reduce Motion | **Not verified** (owner) |
| Clipboard image history vs macOS 27 paste prompt (V6) | **Not verified** (owner) |
| Local rendering of mockup states (5.10) | **Not implemented** (deferred) |

## Phase 6 (2026-10-31; committed on the branch, not pushed)
UX redesign, Clipboard workspace and functional polish; details, defects,
state table and owner checks in `docs/PHASE6.md`. Backup ref
`refs/backup/phase6-start` (= `7538a98`). App only: Core, plugin, JSON API
and stored data unchanged.

| Item | Status |
|---|---|
| Swift `swift test` | **Automated: 186 tests, 0 failures** (9 opt-in skipped) |
| Python suite, `scripts/check.sh` | **Automated: 168 OK** (1 skipped) |
| Layout recursion check | **0 hits** |
| Xcode Debug and Release | **BUILD SUCCEEDED**, 0 compiler warnings |
| Real history in the new views (offscreen, read-only) | no overlap; answer order verified |
| Running app on screen, Reduce Motion, external display | **Not verified** (owner) |
| Paste into ChatGPT Desktop / Safari / Chrome (V8), ⌃⇧⌘4 history (V6) | **Not verified** (owner) |

## Phase 6 polish (2026-10-31; committed on the branch, not pushed)
History toggle, answer-switch motion, in-island tooltips, one copy
confirmation, Copy Answer / Copy for Review, plain-language facts, three
themes (Soft Spectrum default). Details: `docs/PHASE6.md` § Phase 6 polish;
proposals for a public release: `docs/PRODUCT_ROADMAP.md`. Swift 195 tests
0 failures (10 opt-in skipped), Python 168 OK on 3.14 and 3.9.6, Xcode
Debug/Release succeeded, layout recursion 0. On-screen checks are the owner's.

## Phase 6 visual pass (2026-10-31; committed on the branch, not pushed)
Warm Cocoa (default), paired card rows, Task motion, compact in-island
tooltips, Copy with Context with a real Preview, attachment preview,
neutral package heading in the Core. Details: `docs/PHASE6.md` § Phase 6
visual pass. Swift 202 tests 0 failures (11 opt-in skipped), Python 168 OK
on 3.14 and 3.9.6, Xcode Debug/Release succeeded, layout recursion 0. The
live panel on screen is the owner's check.

## Phase 7 (2026-10-31; committed on the branch, not pushed)
UX stabilization and developer workspace; defects, causes, features and
owner checks in `docs/PHASE7.md`. Backup ref `refs/backup/phase7-start`.
Implemented: tooltip placement inside the visible island, thumbnail
hit-testing, View Full Task, Markdown Source, Standard / Full Copy with
Context (Core `--detail`), Preview sections, Evidence Check, Artifact
Completeness, Review Checklist, Import AI Result, Export Bundle.

| Check | Result |
|---|---|
| Swift tests | 221, 0 failures (11 opt-in skipped) |
| Python 3.14 / 3.9.6 | 172 OK each (1 skipped by design) |
| Layout recursion | 0 hits |
| Xcode Debug / Release | BUILD SUCCEEDED, 0 warnings |
| Live NSPanel hover, real mouse, Reduce Motion, paste into assistants | **Not verified** (owner) |

## Phase 7.1 (2026-10-31; committed on the branch, not pushed)
Persistent hand-off with the copied character count, one Relay across
running copies, tooltip width, short-display step 2, Living Relay (2.5D head,
idle machine, settings, no-notch pill), Intelligent Import AI Result,
Capture Health, About details, Full as default. Details, the clipboard
incident and owner checks: `docs/PHASE7.md` § Phase 7.1. Swift 243 / 0 failures, Python 172 OK ×2,
Debug/Release built. Live-screen behaviour is the owner's check.

## Phase 7.2 (2026-10-31; committed on the branch, not pushed)
Relay on a display link with Core Animation layers: 59 fps while moving
(was 12), paused at rest, ≈ 4 % CPU for Relay while following on the bench.
Coucou studied (MIT techniques, no artwork). Copy with Context always Full,
header fixed, audit fixes, display choice and Reduce Motion observer.
Details and measurements: `docs/PHASE7.md` § Phase 7.2.

## Phase 8 (2026-10-31; committed on the branch, not pushed)
Audit, tooltip/Answer/footer layout fixes, the black box in Observed Work
(a blank tooltip), Living Relay 2.0 (vertical tracking), Failure Inspector,
Report Ready indicator (working / unseen / automated / count), Preview
Formatted + Markdown Source, structured ⓘ explanations, product analysis in
`PRODUCT_ROADMAP.md`. Details, measurements and owner checks:
`docs/PHASE8.md`. Core unchanged (Python 172 OK ×2). Backup ref
`refs/backup/phase8-start`.

## Next agreed stage
Phases 7–8 are committed locally; the owner checks `docs/PHASE8.md` § 8 (first:
quit old copies). Push only when the owner asks. Verification Timeline,
multi-turn export, Target Profiles, ADR-012 and source adapters wait for approval.
