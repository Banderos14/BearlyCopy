# Phase 11 — installable app, first-run setup, release preparation, polish

2026-11-05. Starting HEAD `a10de9b` on `claude/loving-mccarthy-ossw3q`
(Phase 10 commits `d8cc33f`, `a10de9b` confirmed). The staged
`macos/acceptance/phase9.1/xcode-smoke/REPORT.md` and every untracked
`macos/acceptance/` item were left exactly as found (not committed, not
moved). The installed `~/Applications/Prompt Relay.app` (0.3.0, `6c004a2`)
was **not** replaced, quit or reconfigured; the running Xcode Debug build
(PID 17008) was not touched. No hook, plugin, trust record, Claude Code or
Codex setting was changed. No push, merge, release or notarization.

Legend: **Verified with tests** = automated, on this Mac · **Verified
(build/script)** = the script or build ran here with the stated result ·
**Measured** = read-only observation · **Requires owner** = needs a person,
a certificate or consent · **Not implemented**.

---

## 1. Local install without Xcode (P0)

Problem confirmed: the installed app was `6c004a2` while HEAD was `a10de9b`
and Xcode was running a fresh Debug build — nothing told the owner which was
which.

**New: `scripts/install-local.sh`** (details: `docs/INSTALL.md`, ADR-020).

| Mode | Does |
|---|---|
| `--dry-run` | build Release, verify, print the plan, change nothing |
| (none) | same, ask `[y/N]`, quit the running Release copy normally (TERM only after a second yes), back up the old app, install, open, check exactly one Release copy runs |
| `--yes` | consent up front (non-interactive) |
| `--no-build` | install `macos/build/…` as is — refused if its commit ≠ HEAD or its Core ≠ checkout |
| `--status` | checkout vs installed build vs running copies |
| `--rollback` / `--list-backups` | restore the newest backup (current app is backed up first) |

Verification before any change: code signature; app version = bundled Core
`__version__`; Core digest (new `scripts/core-digest.sh`, SHA-256 over
`bin/prompt-relay` + `plugin/prompt_relay/*.py`) = digest recorded at build
= this checkout; recorded commit = HEAD. Backups go to
`~/Library/Application Support/PromptRelay-AppBackups/` (0700), never into
the data dir (the script refuses such paths). Running copies are found by
bundle ID through LaunchServices (`lsappinfo`), not by process name.

Build stamp (`build-macos-app.sh`, Xcode "Embed Python Core" phase,
`release-build.sh`): `PRGitCommit`, `PRGitDirty`, `PRBuildDate`, and
`PRCoreDigest` (scripts). The Xcode project version was 0.2.0 while the
Core is 0.3.0 — fixed to 0.3.0. `build-macos-app.sh --install` now hands
over to `install-local.sh` (it used to `rm -rf` the installed app without
asking or keeping a copy).

**Settings → About** now shows version, build kind, commit (+ uncommitted
changes), build date, location, bundled Core version (and the Core actually
answering, when different) and Python, plus mismatch notes derived only
from facts the bundles record (`AppBuild.diagnose`):
- running the Xcode build while `~/Applications` (or `/Applications`) holds
  another commit → names both and the update command;
- the app at this path was replaced while running → "Quit and reopen";
- bundled Core ≠ app version, or the Core answering reports another
  version (a `PROMPT_RELAY_CLI` override).
Builds that did not record a commit produce no claim.

| Check | Result |
|---|---|
| `install-local.sh --status` | reported installed `6c004a2` vs checkout `a10de9b` + changes, Debug PID 17008 — **Verified (script)** |
| `install-local.sh --dry-run` | built, verified, printed plan; exit 0; nothing changed — **Verified (script)**, log `acceptance/phase11/install-local-dry-run.log` |
| Tampered bundled Core + `--no-build --dry-run` | refused ("code signature … does not verify"), exit 1 — **Verified (script)** |
| Real install, quit, launch, one-instance check, rollback | **Requires owner** (no permission to replace the installed app in this phase) |
| About mismatch rules | 5 tests — **Verified with tests** |

## 2. GitHub Release preparation (P0)

- `scripts/release-build.sh`: universal binary (arm64 + x86_64), Developer ID
  signature inside-out (no `--deep` signing), Hardened Runtime with **no**
  entitlement exceptions (`macos/Release/PromptRelay.entitlements`), secure
  timestamp, zip (`ditto -c -k --sequesterRsrc --keepParent`), DMG with an
  Applications link (signed), SHA-256 file. Refuses: dirty tree, missing or
  non-"Developer ID Application" identity.
- `scripts/release-notarize.sh`: preflight (Developer ID authority, runtime
  flag, timestamp) and a printed plan; `--submit` runs `notarytool submit
  --wait`, `stapler staple/validate`, `spctl`. Refuses unsigned test files.
- `--unsigned-test`: same packaging, ad-hoc, every name marked
  `UNSIGNED-NOT-FOR-RELEASE`.
- Docs: `docs/RELEASE.md` (checklist, clean-Mac Gatekeeper check).

| Check | Result |
|---|---|
| Signing identities on this Mac | only `Apple Development: …` — **no Developer ID Application certificate**; nothing was signed for distribution |
| `release-build.sh --unsigned-test` | exit 0; `lipo`: x86_64 arm64; `flags=0x10002(adhoc,runtime)`; DMG 5.8 MB, zip 5.0 MB, app 20 MB unpacked (universal) — **Verified (script)** |
| `spctl -a` on that app | `rejected` (expected for ad-hoc) |
| `release-notarize.sh` on the unsigned DMG | refused, exit 1 |
| A bug found by running it | `codesign -d | grep -q` under `pipefail` reported "runtime flag missing" although it was set (SIGPIPE); fixed in both scripts by capturing the output first |
| Developer ID signing, notarization, stapling, Gatekeeper on a clean Mac | **Requires owner** (certificate, Apple account, decision to publish) |

**Python** (ADR-019): option 3, a checked system dependency, for the first
beta. Reason in one line: a bundled CPython (+45–60 MB per architecture,
every Mach-O to sign, CPython security updates on us) would help only the
app, not the hook, which runs inside Claude Code/Codex through the plugin
launcher. Verified in code: the app (`CoreLocator`) and the launcher
(`run-hook`) use `/usr/bin/python3` only when `xcode-select -p` succeeds,
so a clean Mac never gets the CLT installer prompt from Prompt Relay; the
app says "Python 3.9 or newer: Not found" with the install command.
**Not verified on a clean Mac** (requires owner).

## 3. First-run setup for Claude Code and Codex (P0)

New island page **Set Up** (`SetupView`), reachable from the empty Home
("Set Up" / "Check Setup") and Settings → Agents & Projects → Set Up Agents;
"Skip for Now" returns to Home. One page, four steps:

1. **Agents on this Mac** — Claude Code, Codex · Terminal, Codex · Xcode,
   each with a status and, when expanded, the specific problem and the safe
   next step.
2. **Enable a project** → the existing capture switches.
3. **Verify capture** → Check Again (refreshes doctor + sessions).
4. **First result** → appears when an answer exists; Open Answer.

Status rules (`AgentFacts.state`, ADR-021): Not detected · Installed ·
Configuration required · Trust required · Capture disabled · Waiting for
first event · Connected — events observed · Error. **Connected only with a
stored event from that agent and host**; a plugin record or hook definition
never counts; a Codex CLI delivery never connects Xcode. Detection is
path-existence only (`~/.claude`, `claude`/`codex` commands, Claude.app,
`~/.codex`, Xcode's `CodingAssistant/codex`); no credentials are read.

Connect = the exact commands, what they change, how to undo, Copy Commands:
- Claude Code: `claude plugin marketplace add Banderos14/prompt-relay`,
  `claude plugin install prompt-relay@prompt-relay`; undo `claude plugin
  uninstall …`. User scope (never `--scope project`).
- Codex: `configure-codex.py` preview, then `--apply` (keeps other hooks,
  writes a backup); undo `--disable --apply`.

Prompt Relay itself runs none of these (invariant 9, ADR-008). Why not a
"Connect" button that runs `claude plugin install`: a GUI app has no
reliable PATH to the user's `claude`, the GitHub marketplace fetch is
network I/O the app otherwise never does, and a silent configuration change
is what the owner asked to avoid. Cost: one paste.

Core change: the handler-log diagnostics now attribute Codex runs per host
(`codex:terminal`, `codex:xcode`, …, allowlisted labels only) instead of
only Xcode — needed so CLI and Xcode get separate statuses. Regression test
added (`test_adapters.py`), including a forged `host=evil` label being
ignored.

| Check | Result |
|---|---|
| Status evaluation (7 tests: none installed, Claude path to Connected, Codex definitions → trust → delivery, CLI never connects Xcode, rejected event = Error with reason, Core problem, reversible/scoped commands) | **Verified with tests** |
| Setup page rendering | built and type-checked; part of the full suite render paths only via the route switch — **not screenshot-verified** |
| Real Claude/Codex connection through Setup, real trust prompt | **Requires owner** |
| Codex setup without a source checkout | **Not implemented** — the hook command points at a checkout's `run-hook` (beta blocker, below) |

## 4. In-memory window snapshots — live check

**Not verified live in Phase 11.** No interactive GUI session was driven:
the system window picker, the Screen Recording consent and a real paste
into another app need a person at the Mac. The implementation was not
rewritten. What is covered automatically (Phase 10 tests, re-run green in
this phase): listed + selected by default, bytes from memory, never in the
data dir / index / hand-off folder, limits, Copy Image as data (no file
URL), text + image in one write, files + snapshot in one write, auto-capture
bound to agent + host + project with no fallback, expired snapshot fails
honestly, gone after restart.

### Owner scenario (≈ 15 min, Release build from `install-local.sh`)

| # | Step | Expected | Record |
|---|---|---|---|
| 1 | Settings → Clipboard & Handoff → Auto-capture final window → On → Choose Window… | macOS picker; consent dialog the first time | screenshot of what macOS shows |
| 2 | Pick the agent's window (e.g. Xcode for Codex · Xcode) | row reads "Window for Codex · Xcode in <project>" | |
| 3 | Let that agent finish a task | Attachments: "Final window … · in memory", checked | |
| 4 | Answer card → paperclip → Capture Final Window… | manual capture works the same | |
| 5 | Preview the snapshot | image shown, note "not saved" | |
| 6 | Copy with Context → paste in ChatGPT / Claude.ai / Gemini | text arrives verbatim | which apps |
| 7 | Step 2 → Copy Files → paste in the same chat | image arrives | which apps accept it |
| 8 | Drag the snapshot from Attachments into a browser chat | image arrives | |
| 9 | Paste into Finder | nothing (data-only items; expected) — use Export instead | |
| 10 | Cancel the picker (Esc) | nothing captured, no error loop | |
| 11 | Remove the snapshot (… → Remove) | gone from the list | |
| 12 | `find ~/Library/Application\ Support/PromptRelay -name '*.png' -newer /tmp/start` | no new PNG | |
| 13 | Quit and reopen | snapshot gone; everything else kept | |
| 14 | Another agent finishes in the same project | **no** capture (binding is agent + host) | |

Known limits (unchanged, documented in Phase 10): receivers that accept only
file URLs get nothing from a data-only item; the pasteboard/Universal
Clipboard and the receiving app may keep copies.

## 5. UI polish (P1)

Changed, without a redesign:
- **Type floor 11 pt.** 67 text sites at 9.5–10.5 pt → 11 pt (Details,
  Evidence, Clipboard, Preview, History rows, tooltips, Integrations).
  Icons were left at their sizes. Two tooltip-geometry tests encoded the old
  10.5 pt line height (one line 22 → < 23 pt, two lines 34 → 36 pt); updated
  with a note. The containment tests (tips stay inside the island on every
  edge) pass unchanged.
- **Hit targets.** Attachment row "…" menu 24 × 24 pt (was the ~16 pt
  glyph), mockup-state "…" 24 × 24, paperclip menu 24 × 22, row info button
  22 × 22 (was 16).
- **Radii unified**: `Island.cardRadius` 12 (cards), new `rowRadius` 8
  (rows, hover/selection fills, inner panels; was 7/8/9), new
  `smallRadius` 6 (thumbnails, code chips; was 5/6). 30 sites.
- **Quick Peek source line** drops "· This Mac" (the laptop icon says it,
  and it is the only possible value today); the full label stays in the
  tooltip. "Codex · Xcode" instead of "Codex · Xcode · This Mac".
- **Copy buttons explain themselves** (tooltips): Copy Answer = "Only the
  answer, exactly as written · ⇧⌘C"; Copy with Context = "Answer + request,
  project, checks; files next · ⌥⌘C".
- **Empty Home** leads to Set Up instead of a dead end.

Not changed (and why):
- **Evidence / Completeness / Checklist** overlap. Proposal (not built,
  needs the owner's choice because it removes surfaces): one "Can the
  reviewer trust this?" card with three rows — *Confirmed locally* (commands
  and files observed), *Reported by the agent* (claims), *Open items* (the
  checklist's unchecked entries) — and the existing Evidence page as its
  detail. Copy with Context output would not change, so nothing is lost.
- Retina vs non-Retina external displays, real pointer feel, adaptive height
  after the 11 pt change on a real screen: **Requires owner** (adaptive
  height and layout suites pass offscreen).

## 6. Settings (P1)

New order and grouping (same settings, nothing reset, same keys):
**General** (open on hover, display, other notch apps, stay on
conversation + pinned row, notifications) · **Appearance & Motion** (theme,
motion, Relay; Relay's four options behind a "Relay options" disclosure) ·
**Agents & Projects** (Set Up Agents with "n of m connected", Projects,
Connection details disclosure with the previous Integrations panel) ·
**Clipboard & Handoff** (auto-select result files, auto-capture window,
image history, Open Clipboard) · **Privacy & Permissions** (privacy
statement, Screen Recording explained, clipboard text list) ·
**Diagnostics** (was "Advanced") · **About**. Help texts cut to one
sentence each. Defaults unchanged (auto-capture off, image history off,
notifications off, capture opt-in).

## 7. Test UserDefaults leak — fixed at the root (P1)

Cause: every Swift test made `UserDefaults(suiteName:)`; `cfprefsd` writes
one plist per suite into `~/Library/Preferences` and keeps it even after
`removePersistentDomain` (Phase 10 measured +213 files per run, 11,331 in
total).

Fix: `SettingsStore` protocol (`object/set/removeObject` + typed getters);
`UserDefaults` conforms (the app is unchanged: `.standard`), and
`MemorySettingsStore` is a thread-safe in-memory implementation.
`AppModel.stateDefaults` and `NotchSettings` take `any SettingsStore`. Tests
use `TestDefaults.named(_:)` — one shared in-memory store per suite name,
so "restart" tests behave as before. A guard test fails if any test source
creates a real suite or calls `removePersistentDomain`.

| Check | Result |
|---|---|
| Files matching `PromptRelay*`/`pr-*` in `~/Library/Preferences`, before → after a full `swift test` | **11,331 → 11,331 (0 new)** — **Measured** (Phase 10: +213) |
| Same around the final run | see §12 |
| Old files | not deleted (outside the repo; owner's call; Phase 10 lists a command) |

## 8. Technical debt and performance (P1)

| Item | Finding | Action |
|---|---|---|
| `AppModel.swift` 2.3 k lines, `IslandViews.swift` 2.0 k | large but cohesive; Phase 11 added logic in new files (`AgentConnection`, `SettingsStore`, `SetupView`) instead of growing them | no refactor (not needed for this phase's risk) |
| UI ↔ storage | settings and remembered state now behind `SettingsStore` | done (§7) |
| Idle CPU | Xcode Debug build, 6 × 2 s `top`: **0.0 %**, 53 MB — **Measured** (Phase 10 Release: 0.0–0.7 %, 46 MB) | — |
| CPU during animation | not measured (`PROMPT_RELAY_PERF` probe needs a visible panel) | **Requires owner** |
| Launch time | not measured (would need launching a second copy) | **Requires owner** |
| Large history (Core calls the app makes, isolated temp data, 50 sessions, ~4 KB answers, median of 5) | 200 answers: `sessions --json` 76 ms, `turns` 75 ms, `show` 74 ms; 1,000: 92 / 91 / 91 ms; 3,000: 138 / 136 / 136 ms — **Measured** | roughly linear; fine for the beta; retention defaults stay P2 |
| Hook latency this run | median 45.6 ms, p95 57.1 ms; launcher 66.6 / 82.6 ms (machine busy with builds; Phase 10: 39 / 47) | — |

## 9. Hooks vs MCP (§8 of the brief)

`docs/MCP_EVALUATION.md`, ADR-022. MCP **cannot replace** passive capture:
an MCP tool runs only when the model decides to call it and would receive
re-emitted (not verbatim) text; hooks deliver the exact final answer every
turn for free. MCP **would add** pull-style access for other agents and
structured results. A read-only stdio server over the existing JSON API v1
is feasible without touching capture (`get_latest_result`,
`list_projects`, `list_conversations`, `get_context_pack`,
`get_attachment_metadata`), with: off by default, per-project allowlist,
no write tools, no file bytes, same secret checks, audit line per call.
**Not implemented** (no critical reason found).

## 10. Multi-agent workspace (§9)

`docs/MULTI_AGENT_MODEL.md`: Provider → Profile → Host → Project →
Conversation → Result. Profile = hash of the config home's real path
(`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) passed by the hook command, plus a
local label; credentials never read; same provider never merged; old data
reads as `default`. Two navigation modes: By Project (today) and By Agent.
**Not implemented.** Phase 11 already separates Codex · Terminal and Codex ·
Xcode in diagnostics and Setup.

## 11. GitHub and portfolio (§10)

- README rewritten for a stranger: one-line value, screenshot (offscreen
  render from synthetic data, labelled as such), Mermaid architecture
  diagram, features, privacy, requirements, install (release: not yet;
  checkout: `install-local.sh`), limitations, license status.
- New: `docs/INSTALL.md` (incl. troubleshooting table), `docs/RELEASE.md`,
  `CONTRIBUTING.md`, `docs/PORTFOLIO.md` (stack, decisions, only measured
  numbers; no user or time-saving claims).
- CI (`.github/workflows/tests.yml`): opt-in macOS job now also runs
  `swift build`, `swift test` and `release-build.sh --unsigned-test`; new
  `secrets` job (NUL-safe file list; scanner fixtures excluded).
- Secrets: full history scanned (`git log --all -p`) for AWS, Anthropic,
  GitHub, Slack, Google keys and private-key blocks — only the deliberate
  fake fixtures of the secret scanner's own tests. Two absolute paths with
  the local user name in `PHASE9.1/9.2.md` replaced by `$HOME`/`~`. Commit
  author e-mail is the owner's; public on push (owner's call).
- GIF demo: **not made** — no safe way to record real frames without
  driving the live GUI.
- **License: none.** `plugin.json` says `UNLICENSED`; README says "not
  chosen yet". Choosing one is the owner's decision (code and Relay
  graphics).

## 12. Checks (all on this Mac, macOS 27.0.1, Xcode 27.1, arm64)

Logs in `macos/acceptance/phase11/` (not committed).

| Check | Result | Exit |
|---|---|---|
| `swift test`, run 1 (after the defaults fix) | XCTest 271, 16 skipped, 0 failures; Swift Testing 57/57 | 0 |
| `swift test`, run 2 (after UI changes) | XCTest 271, **2 failures** (tooltip height thresholds, see §5); Swift Testing 69/69 | 1 |
| Targeted re-run (Phase8, TooltipWidth, Phase6Visual, CompactHelp, IslandLayout, AdaptiveIsland) | 0 failures | 0 |
| `swift test`, final | XCTest 271, 16 skipped, **0 failures**; Swift Testing **69/69**; `~/Library/Preferences` PromptRelay files 11,331 → 11,331 | 0 |
| `scripts/check.sh`, Python 3.14.0 and 3.9.6 | 200 + 15 tests each, OK (1 skipped: Linux-only launcher case) | 0 |
| `xcodebuild` Debug / Release, isolated DerivedData | BUILD SUCCEEDED; stamp `a10de9b`, dirty `yes`, 0.3.0; signatures verify | 0 / 0 |
| `scripts/build-macos-app.sh` (via `install-local.sh --dry-run`) | built + verified | 0 |
| `scripts/release-build.sh --unsigned-test` | universal, runtime flag, DMG/zip | 0 (after the pipefail fix; first run 1) |
| Skipped XCTests (16) | env-gated by design (visual dumps, audits, real paste, real dialog, perf) — not run | — |

## 13. Before the first public beta

1. **Owner decisions:** license (code + graphics); publish under
   `Banderos14/prompt-relay`; commit e-mail public or a noreply address.
2. **Developer ID Application certificate** + notary profile; run
   `release-build.sh` and `release-notarize.sh --submit`; Gatekeeper check
   on a clean Mac (also: no CLT prompt without Python).
3. **Codex setup without a checkout**: ship `run-hook` + `configure-codex.py`
   with the app and point the hook at a stable, versioned launcher location
   (ADR needed: invariant 10 forbids state in the plugin root; a launcher in
   Application Support is code in a data dir).
4. **Claude marketplace from GitHub** works only once the repository is
   public and pushed (`claude plugin marketplace add Banderos14/prompt-relay`).
5. Owner live acceptance: §4 snapshot scenario; Setup with a real Claude
   Code and Codex (CLI and Xcode) reaching "Connected"; `install-local.sh`
   real install + rollback; 11 pt type and hit targets on a non-Retina
   external display.
6. Decide the Evidence/Completeness/Checklist consolidation (§5).

## 14. Git

- Branch `claude/loving-mccarthy-ossw3q`; start `a10de9b`.
- `cc47712` — code, tests, scripts, Xcode project, CI (Phase 11).
- The docs commit that adds this file (README, ADR-019…022, STATUS,
  INSTALL, RELEASE, MCP_EVALUATION, MULTI_AGENT_MODEL, PORTFOLIO,
  CONTRIBUTING, path hygiene in PHASE9.1/9.2) follows it; see `git log`.
- Not committed, left exactly as found: the staged
  `macos/acceptance/phase9.1/xcode-smoke/REPORT.md` and every untracked
  `macos/acceptance/` item; new logs in `macos/acceptance/phase11/`; build
  output in `macos/build/` and `dist/` (ignored).
- `e4211fc` — follow-ups from the automated security review: CI secrets
  job no longer fails open; plist values sanitised in backup names and
  backups found with `find`; Developer ID checked by code requirement in
  `release-notarize.sh`; Codex hook detection by exact tokens and known
  hosts (new test). Targeted Swift tests (45) passed.
- No push, no merge, no install, no notarization, no release.
