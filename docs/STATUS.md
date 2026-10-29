# Status

Last updated: 2026-10-29, local session on the Mac (MacBook Pro M3 Pro,
macOS 27.0.1), branch `claude/loving-mccarthy-ossw3q`.

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

Test run after the self-review (2026-10-29): Python 3.13.17 — 79 run, OK,
1 skipped (root); Python 3.9.25 — 79 run, OK, 1 skipped (root); as user
`nobody` — 79 run, OK, 0 skipped. Failures: 0.

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

### Not Implemented (by design in this phase)
SwiftUI/AppKit app, notch UI, hook installer (plugin or settings merge),
ChatGPT integration, clipboard import, retention/prune, `--json` machine
output, encryption at rest, SessionStart/SessionEnd/Notification handling.

## Known risks
1. Real payloads may differ from the docs (for example `prompt_id` missing
   on Stop). Mitigation: order-based fallback with explicit labels; real
   payloads will become fixtures.
2. `last_assistant_message` may hold only the final text block of a
   multi-tool turn (D2). Prompt Relay copies exactly what Claude Code
   provides.
3. pbcopy and NUL / unusual characters (D5).
4. The Python handler needs the Xcode CLT on the Mac (ADR-004).
5. History is stored unencrypted (SECURITY §3).
6. The OpenNook API is not frozen, and it requires macOS 15+ (UI_RESEARCH).
7. `git status` can run a clean filter configured in a project's
   `.git/config` (SECURITY T9). The risk equals running git there yourself.
8. Without `prompt_id`, an interrupt or a prompt blocked by another hook
   makes the next answer `ambiguous` (by design).

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

## Next agreed stage
The owner closed the main Phase 1.5 check (Desktop → Prompt Relay →
clipboard) on 2026-10-29 and asked to continue with **Phase 2 in the cloud**;
the exact Phase 2 scope still needs the owner's approval at the start of that
session (see `docs/CLOUD_TO_LOCAL_HANDOFF.md` §10). The unchecked macOS items
above stay open and need a later Mac session.
