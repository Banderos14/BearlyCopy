# Prompt Relay — complete project handoff (after Phase 15)

Written 2026-11-07 so a new Claude Code session or a new ChatGPT
conversation can continue without the earlier chats. Authoritative detail
lives in the files linked here; where this file and the code disagree, the
code wins. Items marked *(unverified)* could not be confirmed from the
repository.

## A. Project overview

**What it is.** A local-first, native macOS bridge between Claude Code (CLI
and Claude Desktop's Code tab; Codex partly) and ChatGPT. It captures Claude's
final answer verbatim through official Claude Code hooks, shows it in a
Dynamic-Island-style notch window, and lets the user copy either the answer
or a context-rich review pack to paste **manually** into ChatGPT for an
independent review.

**Target user.** One developer (the owner) who runs Claude Code on a MacBook
and reviews its work with ChatGPT. Daily-use utility, not a demo.

**Workflow.** Task to Claude Code → Claude works → hooks
(`UserPromptSubmit`, `Stop`, `StopFailure`, `PostToolUse(Failure)`, waiting
signals, `SessionEnd`) fire → the plugin's launcher runs the Python Core
hook handler (stdout empty, exit 0, no network) → it appends the event to a
per-session JSONL file in `~/Library/Application Support/PromptRelay` (only
for enabled projects) → the Swift app watches the folder (FSEvents) and asks
the Core for JSON (`bin/prompt-relay … --json`, API v1) → AppModel → notch
island (Quick Peek, Details, Inbox, Settings) → **Copy Response** / **Copy
with Context** (Review Pack) / Context Pack / attachments → the user pastes
into ChatGPT.

**Architecture and ownership.**
| Layer | Where | Owns |
|---|---|---|
| Plugin | `plugin/` (`.claude-plugin`, `hooks/hooks.json`, `hooks/run-hook`) | registration with Claude Code (ADR-008); no state in the plugin root |
| Python Core | `plugin/prompt_relay/*.py`, entry `bin/prompt-relay` | hook handler, JSONL store, correlation, history, JSON API, export (Review Pack, Context Pack), secret scan, retention/deletion. Stdlib only, Python 3.9+ |
| Contracts | `docs/JSON_API.md` (v1), `docs/CONTEXT_PACK.md` (v1), `docs/api/` | the app ↔ Core boundary |
| Swift app | `macos/` — `PromptRelayKit` (Core client, Models, Presentation/AppModel, Notch views, Services) + `PromptRelayApp` | UI, clipboard, attachments (ReportStore), window snapshots, permissions, settings |
| Tests | `tests/` (Python), `macos/Integrations` (Python), `macos/Tests/PromptRelayKitTests` (XCTest + Swift Testing) | |

**Key configuration.** Data dir `~/Library/Application Support/PromptRelay`
(override `PROMPT_RELAY_HOME`); enabled projects in `config.json`; app
settings in UserDefaults (Debug and Release have different bundle ids).

**Environment.** macOS 26/27 (this Mac: Darwin 27, Xcode 27.1), Python 3.9.6
(`/usr/bin/python3`) and 3.14; Swift package `macos/Package.swift`, Xcode
workspace `macos/PromptRelay.xcworkspace`, scheme "Prompt Relay".

**Product restrictions (never break).** See `CLAUDE.md` "Product invariants":
no AI APIs, no automatic ChatGPT/browser integration, no backend, offline,
verbatim capture, never mix sessions, Stop ≠ success, StopFailure ≠ answer,
"Reported by Claude" vs "Confirmed locally", opt-in per project (fails
closed), user data outside the repo, plugin-first, no global hook installs,
no Claude settings writes, Python stdlib only.

## B. Phase history (from Git and the phase reports)

| Phase | Dates | What it delivered | Key commits / docs |
|---|---|---|---|
| 0 | 10-29 | research, ADR-001…005, hooks research, data model, threat model | `cd34af4` |
| 1 / 1.5 | 10-29 | Core PoC: hook handler, JSONL store, CLI show/copy/context; Mac validation of the Desktop → Stop → clipboard path | `75688ef`, `475df67`, `d653a45` |
| 2A / 2B | 10-29 | JSON API v1, history deletion/retention, path hardening; Claude Code plugin (ADR-008) | `dd07a0f`, `7626dc0` |
| 3A / 3B / 3C | 10-29 | menu-bar app over the JSON API (ADR-009); notch island NSPanel (ADR-010); per-project capture | `663aa85`, `fdf1034` |
| 4 | 10-29/30 | one island, imports, image attachments, Review Pack, Relay the bear (ADR-011) | `0db6ed0`, `66205c1` (= old remote tip `f72a8ce`) |
| 5 / 5.11 | 10-30 | observed tool results (ADR-013), sessions, typed attachments, mockups, request origin (ADR-017) | `7182436`, `859c044`, `7538a98` |
| 6 (+polish, visual) | 10-30/31 | no overlaps, themes (Warm Cocoa), Copy with Context with Preview | `0267609`, `69251cf` |
| 7 / 7.1 / 7.2 | 10-31 | Evidence Check, Artifact Completeness, Review Checklist, Export Bundle, Living Relay, 60 fps Relay | `147f6bb`, `bf3f74a`, `e96bcc3` |
| 8 / 8.1 / 8.2 | 10-31 – 11-03 | Failure Inspector, ready indicator, layout fixes, island lifecycle | `2366f30`, `a58b3cd`, `994e57b` |
| 9 – 9.4 | 11-04/05 | Codex adapters, adaptive height, one Latest across agents, intermediate Stops are not results, final-only UI | `9655b36`, `9e2461b`, `1750587` |
| 10 | 11-05 | window snapshots in memory only (ADR-018), audit | `d8cc33f` |
| 11 | 11-05 | install script, release scripts, setup page, settings (ADR-019…022) | `cc47712` |
| 12 / 12.1 / 12.2 | 11-05/06 | agent profiles + Results Inbox (ADR-023/024), Needs Input (ADR-025), first-press Drag; 0.4.0 / 0.4.1 installed with consent | `6365809`, `94993af`, `4e31438` |
| 13 | 11-06 | Context Packs + Handoff History (ADR-026/027); 0.5.0 (not installed) | `c6693ef`, `e245bfe` |
| 14 / 14.1 | 11-06/07 | no half-visible rows, island stays open on resize, automatic final screenshots (ADR-028), hover corridor, Screen Recording recovery; 0.6.0 (not installed) | `80e1a0b`, `f721385`, `e6aea5d`, `e3bc4d2` |
| 14.2 | 11-07 | reviewProgress vs Evidence, FailureBreakdown, two-row Copy with Context (implemented with Sonnet 5) | `17844fe` |
| 15 | 11-07 | Git recovery + backup, `develop`, independent audit, D1–D4 fixes, stronger tests, this handoff | branch `phase/15-mvp-readiness` |
| 15.1 | 11-08 | one shared exit-code attribution rule (no false passes through pipes/`;`, `&&` failures unclear, pipefail, withheld compound lines unclear), diagnostics no longer alarm, second backup | same branch; [audit §7](PHASE15_AUDIT.md) |

Per-phase reports: `docs/PHASE6.md`…`PHASE8.md`, `macos/PHASE9.md`…`PHASE14.2.md`,
`docs/STATUS.md` (newest first). Decisions: `docs/DECISIONS.md` (ADR-001…028).

## C. Git and recovery
See [PHASE15_GIT_RECOVERY.md](PHASE15_GIT_RECOVERY.md): branches, SHAs,
bundle path and SHA-256, restore steps, the owner's staged/untracked files
(left untouched in `~/Projects/prompt-relay`), how to merge Phase 15 into
`develop`, and the pending decision about deleting the legacy branch.

## D. What works today (practical)

**Implemented and verified by automated tests on this Mac:** capture
(opt-in, verbatim, per session/profile), StopFailure handling, JSON API v1,
history list/search/delete/retention, Copy Response, Copy with Context
(Full), Context Packs, imports, attachments (files, images, clipboard images),
Evidence Check / Review Checklist / Failure Inspector, Needs Input model,
Results Inbox, settings, install script dry-run.

**Implemented, needs the owner on a real Mac (not verifiable here):** hover,
resize and the hover corridor with a real mouse; first-press drag; automatic
final screenshots with real windows and Claude Desktop timing; Screen
Recording grant/deny/restart in System Settings; Debug vs Release grants;
real paste/drop into ChatGPT; 0.6.0 install and plugin update. Checklist:
[PHASE15_MVP_ACCEPTANCE.md](PHASE15_MVP_ACCEPTANCE.md).

**Partially implemented:** Codex support (adapters exist, delivery depends
on Codex hook configuration); Needs Input for every host/version (documented,
partly observed live); Claims detection is literal phrase matching.

**Planned (not built):** Developer ID signing/notarization and a public beta
(no certificate on this Mac); MCP read-only interface (ADR-027, design only);
encryption at rest; license decision.

**Out of scope by design:** ChatGPT API or browser automation, auto-paste,
cloud backend, telemetry, clipboard monitoring of text, global hook install.

## E. Known issues and risks
| ID | Sev. | Issue | Next action |
|---|---|---|---|
| R1 | P2 | A non-permission capture error unlinks the window (possibly minimized/other-Space windows) | acceptance #16; fix only if reproduced |
| R2 | P2 | Claims detection misses unusual phrasing (never upgrades, only misses a warning) | collect real examples |
| R3 | P2 | Needs Input not observed live for every host/version | acceptance #8 |
| R5 | P2 | Installed app/plugin are 0.4.1 while source is 0.6.0 + Phase 15; two copies run at once (installed + Xcode Debug) | owner decides install (consent) |
| R6 | P2 | No Developer ID: only ad-hoc local builds | owner decision before any beta |
| R7 | P3 | `claude/loving-mccarthy-ossw3q` still exists locally and on GitHub | delete after owner approval (§4 of Git recovery) |
| R8 | P3 | History is unencrypted at rest (FileVault/account only) | future |
Fixed in Phase 15: D1–D4; Phase 15.1: findings 1–4 — both in [PHASE15_AUDIT.md](PHASE15_AUDIT.md).

## F/G. Next-session prompts
[PHASE15_NEXT_CHAT_PROMPT.md](PHASE15_NEXT_CHAT_PROMPT.md) — one prompt for
Claude Code, one summary for ChatGPT.

## H. Phase 16 candidates (not approved, not started)
1. **Owner acceptance pass of 0.6.0 + Phase 15** (install with consent, run
   PHASE15_MVP_ACCEPTANCE, fix what fails) — highest value, unblocks MVP.
2. Resolve R1 if reproduced: distinguish "window gone" from "window not
   capturable right now" (keep the link, show a status).
3. Version bump for the Phase 15 changes (0.6.1 or fold into 0.6.0 before
   its first install — owner's choice).
4. Picker polish (P3): open in the project folder; label the attachment
   checkbox "Send".
5. Release path: Developer ID, notarization, license, privacy text.
6. MCP read-only interface (ADR-027) only after the MVP is accepted.
