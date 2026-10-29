# Test plan

Run everything: `scripts/check.sh` (unit + integration on every available
Python, plus a hook latency benchmark). A subset:
`python3 -m unittest discover -s tests -k s08 -v`. Tests import `helpers`
from `tests/`, so always use `discover -s tests`. A plain
`python3 -m unittest tests.test_scenarios` fails with `ModuleNotFoundError`.

Isolation guarantees for every automated test: a fresh temporary
`PROMPT_RELAY_HOME` and project dirs; the clipboard is the **file MOCK
backend**; no Claude process; no network; no real `~/.claude`; no real
clipboard.

## 1. Unit tests (`tests/test_units.py`)
| Area | Tests |
|---|---|
| Correlation | prompt_id linking out of order; unknown prompt_id is not guessed; stop-hook continuation; unrelated Stop; failure after Stop; failure text never a response; trailing prompt is awaiting |
| Store | permissions 0700/0600; session key cannot escape the dir; hashed ids keep the real id; dedup window without prompt_id; dedup with prompt_id; corrupt/future-schema lines skipped; lossless round trip (lone surrogate, NUL); delete; empty store |
| Hook | allowlist; `CLAUDE_PROJECT_DIR` precedence; prefix is not a parent; corrupt config fails closed; unhandled events not stored; oversized payload; unknown fields preserved; log has no message text |
| Export | fence escaping; secret scan blocks Copy Context and never echoes secrets; git section + **.git untouched** during collection; git unavailable; hook-config is exec form; enable refuses `/` and `$HOME`; delete needs `--yes`; session prefix / project filters |
| Platform | default data dirs (darwin/linux); clipboard backend selection; pbcopy call uses a UTF-8 locale and no shell (mocked subprocess); secret patterns |
| Audit regressions | prompt without prompt_id + Stop with one; prompt_id match keeps other pending prompts; inferred link never upgraded; last Stop without text has no final response; API error after Stop is surfaced; events without session_id never linked; foreign-session line ignored; torn + NUL-filled tail; existing root dir not chmod-ed; entry point exits 0 when the package is missing; concurrent `enable`; Copy Response secret warning; same-directory match by inode (mocked); repo `core.fsmonitor` not executed |
| Schema conformance | every `documented_*.json` (and future `real_*.json`) fixture: stored verbatim and exactly once across three JSON encodings (UTF-8, `\u` escapes, pretty-printed CRLF with reordered keys); documented fields interpreted; documented turns; every fixture text byte-exact via `show` |
| JSON API (`test_api.py`) | text mode unchanged; usage errors as JSON; lone surrogate/NUL/CRLF survive; warnings in JSON, never stderr; preview vs full text; context findings without values; storage errors as JSON; selection by `session_key`. Every `--json` output is checked: one ASCII line, empty stderr, schema-valid, `ok` ⇔ exit 0 |
| Golden (`test_api.py::GoldenTests`) | 13 cases: single real Desktop turn, several turns, two projects, missing prompt_id, ambiguous, API error, empty response, duplicates, Unicode + Markdown, background tasks, real CLI prompt only, no session_id, empty store. Expected files are compared exactly and schema-validated |
| History management | prune is a dry run by default; `prune --yes` deletes only old sessions and nothing else (config, log, foreign files stay); retention setting drives prune and is never automatic; an invalid retention value never disables capture; delete preview, confirmation and active protection; a file written after planning is kept; a hook waiting on the lock survives a concurrent delete; 16 hooks + 3 deleters concurrently: no lost event, no corruption |
| Path safety | symlinked session file never read, written or deleted; symlinked `events/` refused; `safe_unlink` refuses paths outside `events/`; foreign names ignored; a damaged duplicate line cannot crash an append |
| Plugin package (`test_plugin.py`) | manifest fields and version, plugin root contents (no `bin/`, no `CLAUDE.md`, no symlinks), `hooks.json` shape (wrapper, 3 events, exec form `/bin/sh ${CLAUDE_PLUGIN_ROOT}/hooks/run-hook`), launcher POSIX/syntax/no stdout, marketplace entry, no data files in the plugin |
| Real Claude Code parser | `claude plugin validate plugin --strict --json`, `claude plugin validate .` (marketplace), `claude --plugin-dir plugin plugin list --json` and `plugin details` ("Hooks (3) UserPromptSubmit, Stop, StopFailure", ~0 tokens), a root with spaces and Unicode. Isolated HOME; no install, session or API call; skipped where `claude` is missing (for example the Linux CI) |
| Launcher | verbatim Stop from a root with spaces and Unicode, `via=plugin` in the log, cwd independence, discovery without a pin, stale or wrong pins fall back, no usable Python → exit 0 + `no_python_3_9` (Linux), missing package or entry → exit 0, `PYTHONPATH`/`PYTHONSTARTUP` injection ignored, capture off and failures never block, plugin root change after update keeps history, uninstall/disable keep history, plugin + settings hook concurrently → stored once |
| Coexistence and diagnostics | NotchBuddy-like foreign hooks counted, never printed, settings bytes unchanged; plugin + foreign hooks is not double registration; plugin + our settings hook is; settings in two files; incomplete install record; broken/huge settings reported and untouched; doctor never prints message text, never creates the data dir, schema-valid JSON |
| `pin-python` | `enable` pins once and never overwrites a valid pin; bad interpreters rejected; `--show`, `--clear`; file mode 0600 |
| Source safety | no network modules, `shell=True`, `eval`/`exec`, `os.system` in sources; the hook module never prints; `.gitignore` entries |

## 2. Required scenarios (`tests/test_scenarios.py`, real executable in subprocesses)
| # | Scenario | Test |
|---|---|---|
| 1 | One prompt, one Stop | `test_s01_one_prompt_one_stop` |
| 2 | Two prompts in one session (with and without prompt_id) | `test_s02_*`, `test_s02b_*` |
| 3 | Two parallel sessions in different projects | `test_s03_*` |
| 4 | Concurrent Stop events (12 processes, 2 sessions, 50 KB each) | `test_s04_*` |
| 5 | Duplicate delivery (also with reordered keys) | `test_s05_*` |
| 6 | Empty response | `test_s06_*` |
| 7 | Missing optional fields (no prompt_id, no session_id, no text) | `test_s07_*` |
| 8 | Long Markdown with many code blocks (>100 KB, nested fences) | `test_s08_*` |
| 9 | Cyrillic, English, emoji, special characters, CRLF, NUL, RTL | `test_s09_*` |
| 10 | Corrupt JSON, empty stdin, invalid UTF-8, non-object | `test_s10_*` |
| 11 | Storage not writable (path blocked; read-only session file) | `test_s11_*`, `test_s11b_*` (the second needs non-root; root skips it) |
| 12 | Ambiguous request↔response | `test_s12_*` |
| 13 | Background tasks, then a later Stop | `test_s13_*` |
| 14 | API failure (StopFailure) instead of Stop | `test_s14_*` |
| 15 | Byte-exact copy (MOCK clipboard) | `test_s15_*` |
| 16 | No network operations (sockets patched to fail) | `test_s16_*` |
| 17 | No user text in Git changes or the repo tree | `test_s17_*` |
| 18 | Safe stop: lock held → exits 0 in time; crash mid-line recovered; kill switch | `test_s18_*` |

## 3. Manual tests (macOS, `LOCAL_MAC_VALIDATION.md`)
M1 environment check · M2 real pbcopy byte-exact round trip (Unicode, NUL,
large text) · M3 isolated CLI session via `claude --settings` · M4 Claude
Desktop local session in a sandbox project with `settings.local.json` ·
M5 two parallel Desktop sessions · M6 interrupt (Esc) → no Stop · M7 a turn
with background task · M8 performance and no visible delay · M9 cleanup
leaves `~/.claude` unchanged (checksum compare) · M10–M15 plugin install,
real Desktop capture via the plugin, coexistence with NotchBuddy, double
registration, update, disable/uninstall (LOCAL_MAC_VALIDATION §11).

## 4. Regression scenarios (add a test for each bug fixed)
- Hook output ever appearing in Claude's context, which means stdout was
  written.
- A response attributed to the wrong session or project.
- Any change in copied bytes versus the stored text.
- `api_error` presented as a response.
- Data written inside a repository.
- Settings files modified by Prompt Relay.
- Real payloads captured on the Mac are added as fixtures (redacted) and must
  keep producing the same turns.
- Any change in `--json` output without a golden-file update (golden tests
  fail), or a golden-file change without a schema and JSON_API.md update.
- Deletion of anything other than a session file, or of an active session
  without `--force-active`.

## 5. Golden files
`PROMPT_RELAY_UPDATE_GOLDEN=1 python3 -m unittest discover -s tests -k Golden`
regenerates `tests/golden/expected`. Review the diff, then apply
JSON_API.md §6 (compatible vs breaking). Events get fixed timestamps from
2026-01-01T00:00:00Z. Temp paths are normalized to `__PROJECT_A__`,
`__PROJECT_B__` and `__TMP__`, and the wall-clock `exported_at` to
`2000-01-01T00:00:00.000000Z`.
