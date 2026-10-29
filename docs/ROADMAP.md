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

## Phase 1.5 — Local Mac validation (M) — next, needs the owner's Mac
Run `LOCAL_MAC_VALIDATION.md` end to end. Record the real payloads (redacted)
as new fixtures. Resolve discrepancies D1–D5 from `HOOKS_RESEARCH.md`.
Done when every "Requires macOS" item in STATUS has a recorded result.

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
