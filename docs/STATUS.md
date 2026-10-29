# Status

Last updated: 2026-10-29, cloud session (Linux container), branch
`claude/loving-mccarthy-ossw3q`.

## Completed
- **Phase 0 — research & architecture**: docs, ADR-001…005, hook schema
  research, data model, threat model, UI foundation research.
- **Phase 1 — cloud-verifiable part**: hook handler, JSONL store,
  correlation, CLI (show / copy / context / copy-context / sessions / turns
  / enable / disable / delete / hook-config / doctor), and 59 automated tests.

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
| Hook latency | `scripts/check.sh`: median ≈ 60–73 ms, p95 ≈ 78–90 ms (cloud VM, 20 KB payload) |

Test run (2026-10-29): Python 3.13.17 — 59 run, OK, 1 skipped (root);
Python 3.9.25 — 59 run, OK, 1 skipped (root); as user `nobody` — 59 run,
OK, 0 skipped. Failures: 0.

### Verified with Mocks
| Item | Mock |
|---|---|
| Copy Response / Copy Context to the clipboard, byte-exact, `--verify` read-back | file MOCK clipboard (`PROMPT_RELAY_CLIPBOARD=file:…`) |
| pbcopy invocation: exact argv, UTF-8 bytes, UTF-8 locale, no shell | `subprocess.run` patched (`test_pbcopy_backend_sets_utf8_locale`) |
| macOS default data path | `paths.data_dir(platform="darwin")` |
| Hook payloads | synthetic fixtures copied from the documented examples, not captured from a real Claude run |

### Implemented, requires macOS validation
| Item | How to validate |
|---|---|
| Real `pbcopy`/`pbpaste` round trip, including NUL/emoji/large text | LOCAL_MAC_VALIDATION M2 |
| Real Claude Code CLI hooks (`claude --settings`) | M3 |
| Claude Desktop local Code session hooks | M4 |
| `prompt_id` present in real Stop payloads (D1); multi-tool final text (D2); background wake-up (D3); Desktop's Claude Code version (D4) | M3/M4 |
| `/usr/bin/python3` from Xcode CLT runs the suite | §2 |

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

## Cloud environment notes
- Swift toolchain unavailable: `download.swift.org` is blocked by the
  egress policy (HTTP 403). This drove ADR-004.
- No real Claude request was made to test hooks. The installed Claude Code
  2.1.312 binary contains the expected field names (HOOKS_RESEARCH §1).

## Next agreed stage
None approved yet. Proposed next steps, awaiting the owner's decision:
1. Phase 1.5 on the Mac: run `docs/LOCAL_MAC_VALIDATION.md` and record the
   results here.
2. Phase 2 tasks that can run in the cloud (ROADMAP Phase 2).
