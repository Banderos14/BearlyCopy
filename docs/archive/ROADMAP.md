# Roadmap

Each phase starts only after the owner approves it. Cloud (C) or Mac (M)
marks where each task can be done and verified.

## Phase 0 — Research & architecture ✅ (cloud)
Docs, ADRs, hook schema research, data model, threat model.
Done when the architecture, decisions, limits, stack and risks are written
down. **Met.**

## Phase 1 — Core proof of concept ✅ in cloud · ⏳ Mac validation pending
Hook handler, JSONL store, correlation, CLI show/copy/context, synthetic tests.
Done when: synthetic events are processed; responses are stored in full;
sessions never mix; duplicates are handled; tests pass; Claude settings stay
unchanged; nothing leaves the device (all **met in cloud**); CLI copy works
on macOS and a real Claude Desktop E2E passes (**pending**,
`LOCAL_MAC_VALIDATION.md`).

## Phase 1.5 — Local Mac validation (M) — main path ✅, follow-ups open
Run `LOCAL_MAC_VALIDATION.md` end to end. Record the real payloads (redacted)
as new fixtures. Resolve discrepancies D1–D5 from `HOOKS_RESEARCH.md`.
Done when every "Requires macOS" item in STATUS has a recorded result.
2026-10-29: the Desktop → Stop → Prompt Relay → clipboard path passed on a
real run; D1, D4, D5 resolved. Open: ⌘V paste, CLI Stop, Esc, background
tasks, multi-tool text, parallel sessions, StopFailure (STATUS).

## Phase 2A — Cloud Core for the app ✅ (cloud, 2026-10-29)
Done: JSON API v1 (`docs/JSON_API.md`, schema, ADR-006); 13 golden cases
including redacted real payloads; history management (retention setting,
`prune`, `delete` preview and confirmation, active-session protection,
ADR-007); storage path hardening (symlinks, foreign names, the unlink race).
Original task list for reference (tasks 1–3 are done; 4–6 remain):

## Phase 2 — Core hardening and app-facing API (mostly C)
Proposed tasks:
1. `--json` output for `sessions`, `turns`, `show` (a stable machine API for the app) (C).
2. Conformance fixture set + expected-results files that a Swift reader must
   pass (C).
3. Retention settings (max age or size) and `prune` (C).
4. Session metadata from SessionStart/SessionEnd (resume/clear markers),
   only if Mac validation shows value (C, then M check).
5. Installer design: plugin manifest (`.claude-plugin/plugin.json`,
   `hooks/hooks.json`) plus a dry-run diff tool for user-settings merges.
   Implement and test it against fixture settings files only; never the real
   `~/.claude` (C).
6. Swift package skeleton `PromptRelayKit` (read side + NSPasteboard adapter).
   Write it in the cloud, but build and test it **only on the Mac** (M).

Done when: the JSON API is documented and tested; the conformance suite
exists; the installer passes tests on fixture settings, including existing
hooks, invalid JSON, duplicates and uninstall.

## Phase 2B — Plugin integration ✅ in cloud · ⏳ Mac check (2026-10-29)
Done in the cloud (ADR-008, `docs/PLUGIN.md`):
- a plugin package (`plugin/`) plus a marketplace at the repo root;
- a POSIX launcher with interpreter pinning;
- `doctor --json` diagnostics: registrations, double registration, observed
  events;
- tests including the real `claude plugin validate` and `--plugin-dir`
  listing.

The settings-merge installer (item 2 below) was **not** built: the plugin
covers the scenario (PLUGIN.md §9). Open: the Mac check (LOCAL_MAC_VALIDATION
§11).

Original proposal, for reference:
1. Plugin packaging: `.claude-plugin/plugin.json` and `hooks/hooks.json`
   using `${CLAUDE_PLUGIN_ROOT}`; Claude Code owns install and uninstall.
2. Settings merge tool as the fallback for `~/.claude/settings.json` and
   project `.claude/settings.local.json`: `install --dry-run` (shows a diff),
   `install --yes` (backup, validate, merge, idempotent marker), `uninstall`
   (removes only our entries), `status` (detects our entries and other tools'
   hooks), all with `--json`.
3. Tests only against fixture settings files in temp dirs: other tools'
   hooks on the same events (seen on the owner's Mac), invalid JSON, comments,
   duplicates, a missing file, read-only files, symlinked settings, concurrent
   edits, and uninstall restoring the other entries.
4. The data dir is passed in the hook command (`/usr/bin/env
   PROMPT_RELAY_HOME=…`), never through environment variables (Desktop does
   not pass them).
5. Mac check (M): install into a sandbox project, then (with explicit consent)
   user-level install, plus uninstall, with checksums.
Done when every fixture scenario passes, uninstall leaves other hooks
byte-identical, and the Mac check passes.

## Phase 3 — macOS app foundation (M)
**3A ✅ (2026-10-29):** menu-bar app (SwiftUI + AppKit, `macos/`); projects,
sessions and answers; full-response view; Copy Response and Copy Context;
connection status; live updates (FSEvents). `docs/MACOS_APP.md`, ADR-009.
**3B ✅ (2026-10-29, accepted by the owner on the real screen):**
Dynamic-Island-style notch island (custom NSPanel + SwiftUI, ADR-010):
resting / compact / expanded states, hover with dwell and grace, keyboard
(⌃⌥⌘P, ← →, ↩, Esc), Reduce Motion, display choice and no-notch fallback,
"answer ready" indicator and optional notification, coexistence with
Coucou, Settings, and an Xcode workspace with Debug/Release and Previews.
`docs/MACOS_APP.md` §1 and §2B.
Still open for Phase 3: settings for enabled projects, retention and
history deletion; app icon; launch at login.
Decision points: keep the Python handler or port it to Swift. Move to SQLite
if a session file exceeds ~10 MB or listing exceeds ~100 ms.

**3C (2026-10-29, implemented, awaiting the owner's confirmation and commit):**
capture per project in Settings (Add Project, enable/disable through the
CLI, inherited capture), following the newest answer, diagnostics in
Settings → Status.

## Phase 3D — Product Experience 2.0 (M) — folded into Phase 4
3D.1 (single notch experience) was implemented in two iterations; the owner
rejected the tabbed version and asked for a fuller redesign, which became
Phase 4 below. 3D.2–3D.4 (Review Pack and History, Settings in the notch,
the mascot) are delivered in Phase 4.

## Phase 4 — Real-world workflow, native UX and mascot (M) — implemented, owner validation pending
- P1 long real reports (100 KB+), task ↔ answer association shown honestly,
  Review Pack with source and full answer (Core wording change only).
- P2 one island, graphite cards on black, one white primary action, no
  windows; every control inventoried (`PRODUCT_UX_SPEC.md` §5).
- P3 Recent Copies (five references), History with search, pins and
  imports, Projects with capture switches, Settings with plain-language
  rows and Diagnostics.
- P4 manual Cloud import (documented limits, `MACOS_APP.md` §6) and image
  attachments (private copies, Copy Image, drag, text + images).
- P5 Relay the bear (original, vector, facts-only reactions).
- Open: the owner's real-screen review; real paste tests of text + images
  into ChatGPT; one real cloud report import; one real long local report.
Future scope: automatic cloud capture only if Anthropic documents an
interface for it; other agents; ChatGPT API; clipboard monitoring; cloud
storage; telemetry; public release.

## Notch / Dynamic-Island-style UI (M) — delivered in 3B and Phase 4
The notch island moved forward into Phase 3B (above). Remaining ideas:
live observation of coexistence with Coucou, optional "follow the pointer"
display choice, memory reduction toward the 50 MB target, and polish from
day-to-day use.

## Phase 5 — Public-release readiness (M)
Signing and notarization, an installer, docs, licensing review of
dependencies, a privacy policy text, and a crash-free beta period.

## Not in the current version
Automatic hook installation; ChatGPT integration of any kind; clipboard
monitoring of text; cloud-session capture; release or deploy. (Window
snapshots *are* in the product since Phase 9.4/10/14, opt-in and in memory
only; this line said otherwise until Phase 15.) Phases 5–15 are recorded in
`docs/STATUS.md` and `docs/PHASE15_HANDOFF.md`.
