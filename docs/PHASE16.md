# Phase 16 — Daily-driver release (0.7.0)

Branch `phase/16-daily-driver` (worktree `~/Projects/prompt-relay-phase16`),
based on the verified Phase 15.2 commit `708914c`. Goal: one installed
Prompt Relay you open from Applications every day, with the Relay bear as
its icon, a safe update path, and no silent attachment failures.

## 1. Baseline (2026-11-08, before any change)

| What | Found |
|---|---|
| Git | `develop` 17844fe, `main` 775c5c9, `phase/15-mvp-readiness` 708914c = origin; main checkout on the legacy branch with the owner's staged `macos/acceptance/phase9.1/xcode-smoke/REPORT.md` and untracked acceptance folders — left untouched |
| Recovery checkpoint | `~/Backups/PromptRelay/2026-11-08-phase16-start/`: `git bundle` of all refs (verified "okay"), the main checkout's status and staged patch, refs list, SHA256SUMS |
| Running | one copy: Debug ("Prompt Relay Dev", `.debug`) 0.6.0 from `prompt-relay-phase15/macos/build/xcode-debug` (the owner's Phase 15.2 switch worked); installed Release not running |
| Installed | `~/Applications/Prompt Relay.app` **0.4.1**, plus two old copies **in the same folder**: `Prompt Relay.before-phase92-….app` (0.2.0) and `….before-phase94-….app` (0.3.0), same bundle id — Spotlight/Launchpad list three "Prompt Relay" apps and can open a 0.2.0 |
| Plugin | `prompt-relay@prompt-relay` 0.4.1, enabled |
| Tests | Python 249 (+1 skip) + 15 integrations on 3.14 and 3.9.6; XCTest 358 / 0 failures / 16 opt-in skips; Swift Testing 132/132 |

## 2. Installed application architecture

* **Location:** `~/Applications/Prompt Relay.app` — the owner's own
  Applications folder (already used for their other apps), no admin
  password, indexed by Spotlight and Launchpad. `--system` installs in
  `/Applications` instead; the installer warns about a copy in the other
  folder and never installs in both.
* **Bundled:** the Swift app (one Mach-O), the Python Core
  (`Contents/Resources/core`, digest recorded in Info.plist and checked),
  the icon (`Contents/Resources/AppIcon.icns`).
* **External (not bundled):** a Python 3.9+ interpreter — the pin in
  `~/Library/Application Support/PromptRelay/python-path` (here Xcode's
  `python3`; Xcode must be *installed*, not running), else
  `/opt/homebrew`, `/usr/local/bin/python3` (present: 3.14), the python.org
  framework or the Command Line Tools; the Claude Code plugin (installed by
  `claude plugin`, runs its own Core copy for hooks); history in
  `~/Library/Application Support/PromptRelay`.
* **Not needed to run:** Xcode/VS Code sessions, the Git worktree,
  DerivedData, Terminal, shell PATH, a virtualenv. The app finds its Core
  inside its own bundle and runs Python with a fixed minimal environment.
* **Identity:** menu-bar app (`LSUIElement`), no Dock icon (unchanged,
  intentional). The menu-bar item of the installed app is now Relay's
  silhouette (template image); the Debug build keeps the hammer.
  Opening the app again while it runs (Finder, Spotlight, Launchpad)
  opens the island (`applicationShouldHandleReopen`), so a double-click
  always visibly does something.

## 3. The bear icon

`AppIcon` (PromptRelayKit/Notch/AppIcon.swift) draws the icon from
`MascotView.shapes` — the same vector geometry, colours and "smile" face as
the notch bear — on a dark rounded tile (Apple's 824/1024 grid, continuous
corners, sRGB, transparent outside). `scripts/make-app-icon.sh` renders all
ten iconset sizes (16…1024) with the `PromptRelayIcon` tool and runs
`iconutil` → `macos/Resources/AppIcon.icns` (+ `docs/images/app-icon-1024.png`).
Both build paths bundle that one file: the Xcode target (Resources phase,
`CFBundleIconFile = AppIcon` in `macos/Xcode/Info.plist`) and
`scripts/build-macos-app.sh` / `release-build.sh`. Tests check the committed
`.icns` still equals the drawing at every size, that both build paths
reference it, and the installer refuses a bundle without it.

## 4. Installer and updates

See [INSTALL.md](INSTALL.md) for the table. New in Phase 16: Core smoke test
of the bundled Core in a temp data dir; icon and Release-id checks; verified
copy before anything is moved; automatic put-back if the final move fails;
Launch Services registration; success only when the launched process runs
from the installed path, survives 3 s and reports the expected commit;
running Debug copy handled (asked / `--quit-debug`), never killed; stray
copies in Applications reported (`--status`) and moved on request (`--tidy`);
`--system`; `--sign IDENTITY`; one installer at a time; and
`scripts/Update Prompt Relay.command` to double-click. Isolated tests:
`tests/test_install_local.py` (13).

## 5. Fixed

| ID | Sev. | Problem | Fix | Test |
|---|---|---|---|---|
| P16-1 | P1 | "From this turn" → **Add** could do nothing visible: the same bytes already attached under another name returned the old record silently and the row stayed | `accept` reports added / already attached (and selects it) / failed with reason; storage confirmed before "attached" | `addingAFileAlreadyAttachedSaysSoAndSelectsIt` (fails without the fix) |
| P16-2 | P1 | Add failures were written as the **last** row of a scrolling list, usually out of view | outcome shown first in the Attachments card | `addConfirmsStorageAndSaysWhereItGoes` |
| P16-3 | P2 | files Prompt Relay cannot keep (e.g. `.pbxproj`) were offered with an enabled Add that could only fail; Add all stopped reporting after the last item | "Not attachable — …" up front; Add all: "Attached N of M." + each reason | `unsupportedAndMissingFiles…` |
| P16-4 | P3 | a >1 MB text document was called "not a document" | `documentTooLarge` | `oversizedTextDocument…` |
| P16-5 | P3 | names in the answer resolved only at the project root, not the agent's own folder (`<repo>/macos`) | cwd first, then the project; same display root as auto-prepare | `namedFilesResolveInTheAgentsOwnFolderFirst` |
| S8 | P2 (was P3 suspected) | two running copies (Debug + Release) both auto-prepare a new answer's files: a lost update of `attachments.json` **reproduced** with a second process | exclusive `flock` on `<app data>/.store.lock` around every index read-modify-write (re-entrant) | `anotherProcessesIndexWriteIsNeverLost` (fails without the lock) |
| P16-6 | P1 (daily use) | old app copies inside `~/Applications` | `--status` / `--tidy`; backups never inside Applications | installer tests |
| P16-7 | P2 | no app icon in any build | §3 | icon tests |

## 6. Version

0.7.0 for App, Core and plugin manifest. JSON API v1, Context Pack v1 and the
hook contract are unchanged since 0.4.1, so the installed plugin 0.4.1
keeps capturing everything (About says "older but compatible"); updating
the plugin is optional and needs the owner's `claude plugin update`.

## 7. Results (this Mac, 2026-11-08/09)

| Check | Result |
|---|---|
| Python unit + integrations, 3.14 | 262 OK (1 skip) + 15 OK |
| Python unit + integrations, 3.9.6 | 262 OK (1 skip) + 15 OK |
| Installer, isolated (`tests/test_install_local.py`) | 13/13 (part of the above) |
| Hook latency (50 synthetic Stop) | median 38.7 ms, p95 40.4 ms; plugin launcher median 70.5 ms |
| XCTest | 358 run, 0 failures, 16 opt-in skips |
| Swift Testing | 144 tests: 143 passed, 1 failed in the full run — `aHostWithoutSignalsKeepsItsLastConfirmedState` (Phase 12.1, fixture "last event 10 s ago" went stale while the run stalled 33 s under load; code untouched by Phase 16); passes 3/3 alone. Not counted as passed. |
| Phase 16 Swift tests | 12/12; mutation checks: no lock → S8 test fails; no duplicate detection → Add test fails; no put-back → installer test fails |
| Xcode Debug / Release | BUILD SUCCEEDED, 0 compiler warnings; icon byte-identical to `macos/Resources/AppIcon.icns`; 0.7.0; signatures verify |
| Packaged build (`install-local.sh --dry-run`) | verified (Release id, signature, version = Core, digest, icon) + smoke test verbatim; nothing changed. SwiftPM `-c release` took ≈61 min this time (machine busy) |
| Launch probe (packaged app, temp data dir, background) | process in 0.16 s; RSS ≈86 → 83 MB; 0.0 % CPU idle, 0.21 s CPU in 30 s; stopped |
| `git diff --check`, secret/personal-path scan | clean |

**Not verified here (owner, macOS GUI):** Finder/Spotlight icon after a real
install, quit/reopen from Applications, live capture, ChatGPT paste/drag,
Screen Recording grant, restart persistence — see
[PHASE16_ACCEPTANCE.md](PHASE16_ACCEPTANCE.md).

## 8. Remaining risks

* Ad-hoc signing: every update counts as a new app for Screen Recording
  (toggle needed). `--sign "Apple Development"` fixes this locally; it is
  the owner's choice (it uses their certificate). Not notarized: not for
  other Macs.
* The release build can be slow on a busy Mac; the installer replaces
  nothing until it finishes.
* Window links remain in memory (ADR-028): relink after each restart.
* One known timing-sensitive test (above).
