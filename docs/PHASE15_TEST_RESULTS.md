# Phase 15 — test and build results

All runs on the owner's Mac (Darwin 27.0, Xcode 27.1 / 27A9275), in the
worktree `~/Projects/prompt-relay-phase15`. Logs were kept in the session
scratchpad (not committed). Skipped tests are **not** counted as passed.

## Commands
| Check | Command |
|---|---|
| Python (3.14 + 3.9), integrations, hook latency | `PYTHONS="/usr/local/bin/python3 /usr/bin/python3" scripts/check.sh` |
| XCTest + Swift Testing | `cd macos && swift test` |
| Focused | `swift test --filter "Phase15Tests\|Phase142Tests\|Phase8Tests"` |
| Xcode | `xcodebuild -workspace PromptRelay.xcworkspace -scheme "Prompt Relay" -configuration Debug\|Release -derivedDataPath <scratch>/dd build` |
| Whitespace | `git diff --check` |

## Baseline (HEAD `17844fe`, before any change)
| Check | Exit | Passed | Failed | Skipped |
|---|---|---|---|---|
| Python 3.14.0 unit | 0 | 248 | 0 | 1 |
| Python 3.14.0 integrations | 0 | 15 | 0 | 0 |
| Python 3.9.6 unit | 0 | 248 | 0 | 1 |
| Python 3.9.6 integrations | 0 | 15 | 0 | 0 |
| Hook latency | — | median 43.1 ms, p95 48.2 ms (plugin launcher 62.0 / 71.9 ms) | | |
| XCTest | 0 | 323 | 0 | 16 (339 run) |
| Swift Testing | 0 | 123 | 0 | 0 |
| Xcode Debug / Release | 0 / 0 | BUILD SUCCEEDED, 2 distinct Swift warnings | | |

The Phase 14.2 report's numbers (XCTest 339/0/16, Swift Testing 123/123,
Python 249+15 ×2) reproduced exactly. "249 tests" includes the 1 skip.

## After Phase 15
| Check | Exit | Passed | Failed | Skipped |
|---|---|---|---|---|
| Python 3.14.0 unit / integrations | 0 | 248 / 15 | 0 | 1 / 0 |
| Python 3.9.6 unit / integrations | 0 | 248 / 15 | 0 | 1 / 0 |
| Hook latency | — | median 38.4 ms, p95 39.7 ms (launcher 55.3 / 57.0 ms) | | |
| Focused (Phase15 + Phase142 + Phase8) | 0 | 45 | 0 | 2 (47 run) |
| XCTest, full | 0 | 333 | 0 | 16 (349 run) |
| Swift Testing, full | 0 | 123 | 0 | 0 |
| Xcode Debug / Release (final sources) | 0 / 0 | BUILD SUCCEEDED, 0 Swift warnings | | |
| `git diff --check` | 0 | clean | | |

Change in counts: XCTest +10 (new `Phase15Tests`); none removed or renamed;
`Phase142Tests` still 20, five of them with new or changed assertions
(wording "1 likely not an error"; four strengthened, see
[PHASE15_AUDIT §3](PHASE15_AUDIT.md)). The 16 skips are the existing opt-in
render/scroll tests (environment-gated), unchanged.

The full run was repeated on the final committed sources (after the two
warning-only edits in `EvidenceViews.swift` and `IslandViews.swift`):
XCTest 349 run, 333 passed, 16 skipped, 0 failed; Swift Testing 123/123;
exit 0.

## After Phase 15.1 (2026-11-08)
| Check | Exit | Passed | Failed | Skipped |
|---|---|---|---|---|
| Python 3.14.0 unit / integrations | 0 | 248 / 15 | 0 | 1 / 0 |
| Python 3.9.6 unit / integrations | 0 | 248 / 15 | 0 | 1 / 0 |
| Hook latency | — | median 37.9 ms, p95 38.9 ms (launcher 54.3 / 58.1 ms) | | |
| Focused `Phase151Tests` | 0 | 9 | 0 | 0 |
| XCTest, full | 0 | 342 | 0 | 16 (358 run) |
| Swift Testing, full | 0 | 123 | 0 | 0 |
| Xcode Debug / Release | 0 / 0 | BUILD SUCCEEDED, 0 Swift warnings | | |
| `git diff --check` | 0 | clean | | |

Change in counts: XCTest +9 (`Phase151Tests`); none removed. One existing
expectation changed on purpose: `Phase142Tests` chip "5 observed …" →
"6 observed …" (the fixture's grep no-match is now its own non-alarm fact
instead of being grouped with the real build failure's exit 1).

Phase 15.1 mutations (each reverted): M1 old pass counting → 4 failures;
M2 trust withheld compound text → 5; M3 grep alarms again → 3; M4 old
`meaning()` → 3; M5 old `&&` rule → 8 (all in `Phase151Tests`).

## Mutation checks (temporary edits, reverted)
| Mutation | Result |
|---|---|
| Review-mark pruning back to `Dictionary.prefix(limit)` | `Phase15Tests`: 4 failures |
| `exitBelongsToKind` always true (pre-Phase 15 classification) | `Phase15Tests`: 7 failures |

## Core probes (isolated `PROMPT_RELAY_HOME` in the scratchpad)
Empty stdin, `not json`, `[]`, Stop without session id, traversal-shaped
session id, StopFailure: every run exit 0, 0 bytes on stdout; the
traversal id was stored under a hashed file name. A 300 KB Cyrillic answer
with emoji, two code fences, CRLF and a tab: `copy --stdout` returned it
byte-identical. `handler.log` held only time, event, route and outcome.

## Not run / not verifiable here
Real mouse hover/resize/drag, System Settings permission toggles, Claude
Desktop live timing, real paste into ChatGPT, plugin install/update, app
install (all need the owner: [PHASE15_MVP_ACCEPTANCE](PHASE15_MVP_ACCEPTANCE.md)).
`xcodebuild test` was not run separately (the same test targets run under
`swift test`).
