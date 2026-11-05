# Phase 9.2 — Codex/Xcode delivery diagnosis

2026-11-04. Starting HEAD `fa371a25462c20001a46b87e4f99db04dda0d69e`.
Existing staged smoke REPORT.md and untracked acceptance files were preserved.
Starting status and tracked patch: `acceptance/phase9.2-start-status.txt` and
`acceptance/phase9.2-start.patch`. No reset, clean, history deletion or clipboard clearing.

## Observed facts, not synthetic acceptance

- Active CODEX_HOME is Xcode's `Library/Developer/Xcode/CodingAssistant/codex`.
  Its hooks.json points to this checkout with provider=codex and host=xcode.
  This work did not change hooks, trust records, agent settings or NotchBuddy.
- The old smoke REPORT.md/preview.png have timestamps around 08:12 UTC.
  There are no corresponding hook records. Existing metadata cannot prove
  whether that particular Xcode process had loaded/reviewed the hooks.
  CLI Trusted/Active is not retrospective proof of Xcode delivery.
- Real Xcode events began at 09:26:39 UTC. Two real sessions were recorded,
  with cwd `/Users/admin/Projects/prompt-relay/macos`, not the nested smoke folder.
  The repository itself is capture-enabled, so this cwd passes the existing
  opt-in rule. UserPromptSubmit and PostToolUse reach the launcher, parser,
  adapter, append-only storage and Core. No synthetic event was sent to real storage.
- A read-only Swift AppModel check returned 2 Xcode sessions and exactly
  `Codex · Xcode · This Mac`, with 0 completed turns. No full Answer/Stop has
  yet been verified. This active diagnostic conversation cannot verify its
  own final Stop before it ends.
- Two Prompt Relay builds were running. The installed Release executable
  had run since October 30 and its bundled Core lacked adapters.py.
  Against the SAME store, checkout and fresh Debug Core reported 10 sessions,
  including 2 Codex; installed Release Core reported 10 sessions, 0 Codex.
  This proves stale provider interpretation in that installed build; it does
  not explain away the absence of records for the earlier smoke.
- Built and ad-hoc-signature-verified the local 0.3.0 app, replaced the installed
  copy, and launched it. The previous bundle is preserved at
  `~/Applications/Prompt Relay.before-phase92-20261104160705.app`.
  Only the new installed process was running at the final check. Its adapter
  bytes match the checkout; its Core sees 2 Xcode sessions, 0 completed turns.
  No settings, history or agent profile files were changed by installation.

The capture failure boundary for the original smoke is before a recorded
handler invocation, not UI filtering. The exact historical runtime/trust
condition is not recoverable from available metadata. New Xcode invocations
prove lifecycle hook execution is supported on this installation. No passive
transcript reader, UI scraping or trust bypass is needed or implemented.

## Fixes

- `hook.py`: allowlisted provider/host attribution in metadata-only diagnostics;
  arbitrary event labels cannot expose payload text. Legacy Claude log format
  stays compatible. Hook commands and their trust definitions are unchanged.
- `integration.py`, API schema, Swift APIModels: optional per-source receipt,
  save and error timestamps in doctor output. Old logs never imply Codex trust.
- `CodexDeliveryStatus.swift`, `IntegrationsView.swift`: configuration, confirmed
  execution/storage, rejection reason, latest event/workspace, pending Stop vs
  Stop without text vs answer, app path/PID and concurrent-build notice.
- `AppModel.swift`: Test Connection publishes the fresh sessions it reads;
  previously its status rows could retain stale `allSessions`. Opening
  Integrations now performs that read-only check too.
- `adapters.py`: successful Xcode write results with an explicit absolutePath
  now provide file evidence, including MCP structuredContent/JSON text blocks.
  Failed writes, input paths and navigator-only paths remain unconfirmed.
  Shell-created images still require actual qualifying evidence; their creation
  is not inferred merely from a successful command or the assistant's prose.

## Checks actually run

| Check | Result |
| --- | --- |
| scripts/check.sh, Python 3.14.0 | 172 tests: 171 passed, 1 skipped; 15 integration tests passed |
| scripts/check.sh, Python 3.9.6 | 172 tests: 171 passed, 1 skipped; 15 integration tests passed |
| Full Swift XCTest | 269 enumerated: 253 passed, 16 opt-in skipped, 0 failures |
| Full Swift Testing | 18 tests in 7 suites passed |
| Final targeted Phase 9/9.1/9.2 | 9 Swift tests in 3 suites passed, including the subsequently added CLI/Xcode/Stop-state regression |
| Xcode BuildProject | Succeeded after final edits |
| Local app build/signature verification | 0.3.0 built, installed with backup, launched successfully |
| Real storage → Swift AppModel | 2 Codex/Xcode sessions readable; exact source label confirmed; 0 completed turns |
| git diff --check | Passed |

Logs are under `acceptance/phase9.2-*`. Initial sandbox Swift runs failed
because of nested sandbox/PNG framework access; the permitted macOS run passed.
An initial full Python run caught the missing optional JSON schema field and
legacy log-format expectations; both were corrected, and both final Python
runs completed with exit 0. These failures are not counted as successful checks.
Swift tests use named pasteboards and temporary attachment storage.

## Remaining real acceptance: one owner action

In a **new Codex conversation in Xcode for xcode-smoke**, send:

> Создай REPORT-92.md с текстом relay-92 через инструмент записи файла,
> выполни printf 'relay-92\n', затем sh -c 'exit 7'. В финальном ответе
> напиши RELAY-92-DONE и укажи путь REPORT-92.md.

After its final response, the real Stop, original task, full answer, command
outcomes and file evidence can be checked without Import AI Result. No second
hook setup/trust step is requested. The complete image attachment and real
Copy with Context/History/Project and Session workflow remains unaccepted
until actual completed-turn evidence exists. Isolated attachment/handoff tests
passed, but are not a substitute for that real acceptance.

No commits, pushes or merges were made during this diagnosis.
