# Core self-review — 2026-10-29

Scope: the Phase 1 Core (`prompt_relay/`, `bin/prompt-relay`, tests, docs)
at `4ff30b9`. Every defect below was **reproduced first** (a probe script or
a failing test), then fixed in `1d71087`, each with a regression test.
Environment: cloud Linux container, Python 3.13.17 and 3.9.25. There are no
macOS results in this review.

## Confirmed defects (fixed)
| ID | Area | Defect (reproduced) | Fix | Regression test |
|---|---|---|---|---|
| A1 | Correlation | Prompt without `prompt_id` + Stop with one → answer orphaned (`none`), prompt `no_matched_response` | link by order when the single pending prompt has no id of its own | `test_stop_prompt_id_with_prompt_lacking_it_links_by_order` |
| A1b | Correlation | Found by the A1 test itself: a second Stop with the same id upgraded the inferred link to `prompt_id` (a false "confirmed") | `prompt_id` link only when the prompt carries the id | same test |
| A2 | Correlation | A `prompt_id` match cleared all pending prompts, so the next id-less Stop lost its prompt | remove only the matched turn from the pending list | `test_prompt_id_match_keeps_other_pending_prompt` |
| A3 | Verbatim/final text | If the last Stop had no `last_assistant_message`, an older, superseded Stop text was exported as "final" | final response = last Stop only | `test_last_stop_without_text_has_no_final_response` |
| A4 | Status honesty | Stop followed by StopFailure: copy succeeded silently, and the context said "no successful final response" while showing one | an explicit warning in copy/show/context | `test_copy_warns_on_api_error_after_stop` |
| A5 | Session isolation | Events without `session_id` (all in `_no-session`) were linked to each other across unknown sessions | no linking in that bucket | `test_events_without_session_id_are_never_linked`, `test_no_link_mode` |
| B1 | JSONL integrity | A line with another session's id inside a session file was merged into that session | ignored and counted (`foreign_lines`), with a CLI warning | `test_foreign_session_line_is_ignored` |
| B2 | Safety | `ensure()` ran chmod 0700 on a pre-existing root (for example `PROMPT_RELAY_HOME=$HOME`) | never chmod an existing root; `events/` is still 0700 | `test_existing_root_mode_is_not_changed` |
| C1 | Concurrency | 20 concurrent `enable` runs kept 10 projects; several processes crashed (shared tmp file plus lost update) | config lock and unique tmp names | `test_concurrent_enable_keeps_every_project` |
| F1 | Hook contract | Entry point exited **1** with a traceback when the package could not be imported (moved checkout); old Python was unguarded | the hook fast path always exits 0 (`startup_failed:<Type>` on stderr) | `test_hook_entry_point_exits_zero_when_package_missing` |
| F2 | Python assumption | The default `hook-config` relied on `PATH` via `/usr/bin/env python3`; docs assumed `/usr/bin/python3`, which is only a stub without the Xcode CLT | pin `sys.executable` by default and validate it; `doctor` reports the CLT state; docs use `$PR_PYTHON` | `test_hook_config_is_exec_form_and_writes_nothing` |
| E1 | Sensitive data | Copy Response gave no warning on likely secrets (the spec asks for a warning) | warn on stderr (kind and line only); never block or alter | `test_copy_response_warns_on_secrets_without_echo` |
| E2 | Docs overclaim | SECURITY T9 implied that repository config cannot run code during git collection. A repo `filter.*.clean` **does** run during `git status` (verified) | T9 corrected to "partly mitigated"; the fsmonitor mitigation is proven by a test | `test_repo_configured_fsmonitor_is_not_executed` |
| G1 | Docs | `python3 -m unittest tests.test_scenarios` (TEST_PLAN, validation doc) fails with `ModuleNotFoundError: helpers` | the docs use `discover -s tests` | (doc fix) |

Small robustness fixes: the session listing tolerates a file deleted
mid-scan; `Session.last_at` uses the max timestamp; the context reports
"background tasks: not reported" when Claude Code omits the arrays;
same-directory project matching by `(st_dev, st_ino)` for case-insensitive
APFS (mock-tested only).

## Reviewed, no defect found
- **Verbatim text**: payloads are stored as parsed JSON with `ensure_ascii`
  lines. The round trip is lossless (emoji, NUL, CRLF, lone surrogates). The
  same event in three encodings is stored once and is equal to the input
  (`SchemaConformanceTests`).
- **Torn and corrupt lines**: a partial or NUL-filled tail, invalid UTF-8 and
  a non-object payload are skipped and counted. The next append starts on a
  fresh line (`test_partial_and_nul_filled_tail_then_append`, `test_s18`).
- **Concurrent Stops**: 12 parallel writers with no loss or corruption
  (`test_s04`). Dedup does not depend on key order (`test_s05`).

## Accepted limitations (documented, not changed)
- Without `prompt_id`, an interrupted turn (Esc → no Stop) or a prompt blocked
  by another hook makes the next answer `ambiguous`. This is by design: no
  guessing (HOOKS_RESEARCH D7/D8).
- Identical payloads that carry the same `prompt_id` always dedupe, even if
  Claude emitted them twice; the copied text is the same.
- `flock` may not work on network home directories (SMB/NFS). The data dir
  is expected to be local.
- Whether `agent_id` can appear on main-session Stop events is open (D6).
- Tests use documented, not real, payloads until Phase 1.5.

## Results after the fixes
- Python 3.13.17: 79 run, OK, 1 skipped (root-only permission test).
- Python 3.9.25: 79 run, OK, 1 skipped.
- Non-root (`nobody`): 79 run, OK, 0 skipped.
- Hook latency: median 72.6 ms, p95 88.2 ms (cloud VM).
- Synthetic demo: MOCK clipboard bytes identical to the fixture.

## Phase 1.5 plan (macOS, MacBook Pro M3 Pro)
The step-by-step commands are in `docs/LOCAL_MAC_VALIDATION.md`.

| Step | Goal | Acceptance |
|---|---|---|
| 1. M1 environment | choose `$PR_PYTHON` (3.9+); record macOS, CLT, CLI, Desktop and Desktop-Code versions; checksum `~/.claude` settings | versions recorded; checksums saved |
| 2. Suite | `PYTHONS="$PR_PYTHON" scripts/check.sh`; `doctor` | 79 OK, 0 skipped; `doctor` shows pbcopy and the data dir |
| 3. M2 clipboard | real pbcopy/pbpaste: Unicode fixture, ~1 MB Markdown, paste into TextEdit and ChatGPT | byte-identical, or the NUL difference (D5) documented |
| 4. M3 CLI hooks | `claude --settings` with `hook-config` output; 5 prompts (exact text, multi-tool, background, Esc, subagent) | turns correct; D1, D2, D3, D6 answered; no hook error notices |
| 5. Real fixtures | redact and add `tests/fixtures/real_*.json`; rerun the suite | conformance tests pass on real payloads |
| 6. M4 Desktop | sandbox `.claude/settings.local.json`; same prompts | hooks fire; D4 recorded; same results as the CLI |
| 7. M5 parallel | two sandbox projects at once | no cross-session or cross-project mixing |
| 8. M7 latency | hook latency on the M3 Pro | median < 150 ms; no perceptible delay |
| 9. M9 cleanup | remove sandbox settings and data | `~/.claude` checksums unchanged; repo has only intended changes |

Rules: fix only defects that real payloads prove, each with a regression
test; no UI, no installer, no Phase 2; commit on the same branch, never
merge into `main`.
