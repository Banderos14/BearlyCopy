# Phase 9.1 — real Codex acceptance checkpoint

2026-11-04. Starting HEAD: 168638482d40ec0d14672a644205d5b6655cc8fc.
Branch: claude/loving-mccarthy-ossw3q. Only untracked acceptance/ existed at start.

## Observed on this Mac

- The current agent's CODEX_HOME equals `~/Library/Developer/Xcode/CodingAssistant/codex`.
- That profile has config.toml, but no hooks.json and no inline hooks table.
- Neither features.hooks nor its deprecated codex_hooks alias is explicitly set there. No managed-only setting is explicitly set in that file. This does not rule out other policy layers or launch overrides.
- Installed Xcode Codex executable reports 0.153.1.
- configure-codex.py preview completed successfully; no --apply was run.
- Read-only session metadata from the real Prompt Relay store contains eight legacy Claude sessions and zero Codex sessions. No prompt/answer text was printed.
- User consent to create the Xcode-profile hooks.json was requested with the exact command and three events. Until consent arrives, profile writes and live acceptance remain pending.

## Proposed configuration, not applied

Target: `~/Library/Developer/Xcode/CodingAssistant/codex/hooks.json`.
Events: UserPromptSubmit, PostToolUse, Stop. Each command has timeout 5 seconds:

```text
env PROMPT_RELAY_PROVIDER=codex PROMPT_RELAY_HOST=xcode /bin/sh $HOME/Projects/prompt-relay/plugin/hooks/run-hook
```

Only this file is proposed. Existing config.toml, credentials, other hooks and stored history remain untouched. The helper preserves existing hooks and creates a backup if the target exists by the time of application. Capture is still opt-in per project. This configuration is profile-wide, which is why explicit owner consent is required.

## Trust and acceptance boundary

[Official Codex hook documentation](https://learn.chatgpt.com/docs/hooks) requires review/trust of the exact non-managed hook definition. Discovery via hooks/list is separate from trust and delivery. CLI offers `/hooks`; the documentation also describes Review hooks for the Codex desktop app. That is not evidence that Xcode exposes the same UI.

After approving configuration, the owner must check whether Xcode offers hook review when starting a fresh session in a disposable project. If it does not, report that exact limitation; do not bypass trust or edit trust records directly. No real Xcode or CLI event has been obtained in this checkpoint. Neither client is accepted yet, and Xcode is not declared unsupported merely because configuration has not been enabled.

Next real test: enable capture for one disposable project through Prompt Relay, start a new Xcode Codex session there, and request a Markdown report, a small PNG, an exit-zero command and a controlled exit-7 command. Name both files in the final answer. Check provider/host, native IDs and the complete prompt/answer against the real captured result. Only files with observed origin qualify for auto-selection; shell-generated files without that evidence remain manual candidates. Then verify History, Project & Session, unread/pinned behavior, Quick Peek Copy with Context, deselection and handoff persistence across closing/restarting the app. Do not restart an existing user session automatically.

CLI acceptance must use a separate session and record host CLI; it cannot establish Xcode success. The safe currently available alternative remains Import AI Result with user-supplied Codex/Xcode provenance.

## Implemented change

Settings → Integrations now separates the bundled source adapter, Xcode hooks.json definition count, unverified trust, and recorded hook events. CLI history cannot satisfy the Xcode event indicator. Missing/partial/unreadable definitions require action. No state says Connected based on a file. Inline/plugin configurations and runtime policy are explicitly outside this narrow file inspection. Test Connection refreshes this evidence and performs the existing Core check without an AI task.

Regression tests verify absent, malformed, complete and CLI-only definitions. Complete definitions still say trust not verified. Existing Phase 9 provider/attachment tests and Phase 8.1/8.2 unread/handoff tests run unchanged. No capture, attachment selection, clipboard, correlation or Claude adapter behavior was changed.

## Verification

- 13 relevant Swift Testing tests passed, zero failures, no skipped tests in this selected run. This is not a new full Swift suite run.
- Debug: Xcode BuildProject succeeded.
- Release: xcodebuild succeeded with separate DerivedData and signing disabled.
- Python 3.14 and 3.9: each passed 171 existing tests (1 skipped) plus 12 integration tests.
- git diff --check passed.
- Live Xcode capture: not verified; no real events received.
- Live CLI capture: not verified; no real events received.
- New UI rendered/compiled, but interactive owner acceptance remains pending.

Local logs: acceptance/phase9.1/ (not committed). No push, merge, reset, clean, UI scraping, private database access, credentials copying, synthetic events in real storage, or system clipboard changes.

Disposable owner test project prepared at `acceptance/phase9.1/xcode-smoke/Package.swift`; paste `SMOKE-PROMPT.md` in a new Xcode Codex conversation only after configuration, hook trust and project capture have been enabled. The scaffold has not been run as a live agent task.
