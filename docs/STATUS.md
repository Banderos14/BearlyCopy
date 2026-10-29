# Status

Last updated: 2026-10-29, cloud session (Phase 2A), branch
`claude/loving-mccarthy-ossw3q`. The previous update was made in the local
Mac session (Phase 1.5).

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
| GitHub Actions (Linux, Python 3.9 + 3.13) | runs 1–3 green up to `d653a45`; Phase 2A run: see the final report |

Test run, Phase 2A (2026-10-29, cloud): Python 3.13.17 — 105 run, OK,
1 skipped (root-only permission test); Python 3.9.25 — 105 run, OK,
1 skipped; as user `nobody` — 105 run, OK, 0 skipped. Failures: 0.
Hook latency median 74.2 ms, p95 93.8 ms.

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

| Phase 2A suite on macOS (APFS `flock`, `O_NOFOLLOW`, `st_nlink` after unlink, scandir) | `PYTHONS=… scripts/check.sh` on the Mac; nothing in 2A is macOS-specific, but it has not run there yet |
| JSON API consumed by a Swift client (`JSONDecoder`, surrogate pairs) | Phase 3 |

### Not Implemented (by design in this phase)
SwiftUI/AppKit app, notch UI, hook installer (plugin or settings merge),
ChatGPT integration, clipboard import, encryption at rest,
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

## Next agreed stage
Phase 2A is finished and pushed; it is waiting for the owner's review.
Proposed next: **Phase 2B — hook installation and management** (ROADMAP),
which needs approval before any work. The unchecked macOS items above stay
open for a later Mac session, along with one run of the 2A suite on the Mac.
