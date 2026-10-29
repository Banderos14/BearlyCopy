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

## Phase 2B — Hook installation and management (proposed, C + M check)
Not started. Needs the owner's approval. Proposed scope:
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
Menu-bar app (SwiftUI + AppKit); history list; full-response preview; Copy
Response and Copy Context buttons; settings (enabled projects, delete
history); plugin-based install with uninstall. The notch UI is designed but
off by default.
Decision points: keep the Python handler or port it to Swift. Move to SQLite
if a session file exceeds ~10 MB or listing exceeds ~100 ms.

## Phase 4 — Notch / Dynamic-Island-style UI (M)
Hover expansion, animations, compact status, multi-monitor handling, and a
fallback for Macs without a notch. Evaluate OpenNook (Apache-2.0) against a
custom NSPanel (`UI_RESEARCH.md`).

## Phase 5 — Public-release readiness (M)
Signing and notarization, an installer, docs, licensing review of
dependencies, a privacy policy text, and a crash-free beta period.

## Not in the current version
UI of any kind; automatic hook installation; ChatGPT integration; clipboard
import; cloud-session capture; screenshots; release or deploy.
