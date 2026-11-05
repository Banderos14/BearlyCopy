# Prompt Relay JSON API — version 1

The local, machine-readable interface for the future SwiftUI/AppKit app and
other tools. There is no server and no HTTP: the consumer runs the CLI and
reads one JSON document from stdout.

- Schema: [`docs/api/api-v1.schema.json`](api/api-v1.schema.json) (JSON
  Schema 2020-12)
- Golden examples: `tests/golden/expected/*.json`, produced from
  `tests/golden/cases/*.json`
- Implementation: `plugin/prompt_relay/api.py`, `plugin/prompt_relay/cli.py`

## 1. Invocation and transport

```bash
prompt-relay <command> [options] --json
```

| Property | Rule |
|---|---|
| stdout | exactly one JSON object followed by `\n`; nothing else |
| stderr | empty in `--json` mode; diagnostics are in `warnings` |
| encoding | pure ASCII: every non-ASCII character is a `\uXXXX` escape (characters above U+FFFF become UTF-16 surrogate pairs). Decoding is independent of the locale, and every string survives exactly, including NUL, CRLF and lone surrogates |
| keys | sorted, no insignificant whitespace (do not depend on key order) |
| exit code | same as text mode (§5); `ok` is `true` exactly when the exit code is 0 |
| usage errors | a bad option in `--json` mode yields a JSON `usage_error` document, exit 2 |
| not covered | `--help` and `--version` print plain text |

Commands with `--json`: `projects`, `sessions`, `turns`, `show`, `context`,
`delete`, `prune`, `retention`, `doctor`. The other commands (`hook`,
`enable`, `disable`, `copy`, `copy-context`, `hook-config`, `pin-python`)
are text commands. The app writes the clipboard itself (NSPasteboard) using the
text from `show --json` or `context --json`.

## 2. Envelope

```json
{
  "api_version": 1,
  "command": "show",
  "ok": true,
  "data": { },
  "error": null,
  "warnings": [ { "code": "background_tasks_pending", "message": "…" } ]
}
```

All six keys are always present.
- `command` is the subcommand, or `null` if argument parsing failed before
  one was known.
- `data` is the command result. It is `null` for most errors, but some errors
  carry data (`no_final_response`, `confirmation_required`,
  `active_session`, `storage_error` from delete/prune).
- `warnings` explain caveats. They never change the meaning of `data`.

## 3. Commands and `data`

`$defs` names refer to the schema. Times are UTC ISO-8601 with six
fractional digits and a `Z` suffix: `2026-10-29T14:04:18.117766Z`.

| Command | Options | `data` (`$defs`) |
|---|---|---|
| `projects` | — | `projects_data`: every enabled project plus every project that has history, with `capture_enabled`, `explicitly_enabled`, `session_count`, `last_event_at`; `settings.retention_days`, `settings.automatic_deletion` (always `false`) |
| `sessions` | `--project DIR` | `sessions_data`: `session_summary[]`, newest first |
| `turns` | `--session ID\|KEY`, `--project DIR` | `turns_data`: one session (default: the latest) and its `turn_summary[]` |
| `show` | `--session`, `--project`, `--turn N` | `show_data`: the session and one `turn_full` with full texts (default: the latest turn that has a response) |
| `context` | as `show`; `--detail standard\|full` (Phase 7, default `full`, unchanged) | `context_data`: the Copy Context text, `sensitive_findings` (section, line, kind; never the value), read-only `git` summary, `exported_at` |
| `delete` | `--session ID\|KEY` or `--all`; `--dry-run`, `--yes`, `--force-active` | `plan_data` |
| `prune` | `--older-than-days N` (default: the retention setting), `--yes` | `plan_data` |
| `retention` | `--days N` or `--off` | `retention_data` |
| `results` | `--project DIR`, `--provider claude_code\|codex`, `--profile ID\|unassigned`, `--limit N` (1–10000, default 500) | `results_data` (Phase 12): final results of every session, newest `answered_at` first (ties: session key, turn); `total` before the limit. A result is a turn with a final response whose `completion` is `answer`, `answer_background_running` or `waiting_background` (the app shows the last only after its wait expired); intermediate Stops never. Each `result_summary`: `session_key`, `turn`, `answered_at`, `status`, `completion`, `conversation{title,session_id}`, `source?`, `profile?`, `native_session_id?`, `project`, `logical_project?`, `request{turn,own,display_preview,char_count}` (for a turn the harness started: the request that began the work chain, `own:false`), `response{preview,truncated,char_count}`, `observed`. Previews only; `show`/`context` give the verbatim texts |
| `doctor` | `--project DIR` (default: the current directory), `--no-project` | `doctor_data`: `core` (Python, pinned hook interpreter), `storage`, `capture`, `configuration` (plugin install records, settings files: Prompt Relay hooks, **counts** of other hooks, `enabledPlugins` for prompt-relay), `observed` (handler.log by `via` and outcome), `findings[]` (`level`, `code`, `message`), `unverified[]`. Every finding is also in `warnings`. Added in Phase 2B; a compatible addition |

### Session summary
`session_id` (`null` for events captured without one), `session_key` (the
stable file key; pass it to `--session` to address any session),
`project{path,name}`, `first_event_at`, `last_event_at`, `event_count`,
`turn_count`, `cwds[]`, `last_turn{index,status}`,
`integrity{corrupt_lines,unsupported_lines,foreign_lines}`.

### Phase 5 additions (compatible, 0.3.0)
- Session summary: `title` (first captured request, one line, ≤ 80 chars, display only), `claude_code_title`
  (`session_title` sent by Claude Code), `answered_count`, `running` (a request without a Stop, active in
  the last 30 minutes; background tasks at a Stop do not count).
- Turn: `notification_count` (task notifications / subagent hand-backs delivered with the turn's
  `prompt_id`; not turns), `observed` (counts of tool events: `runs_exit_zero`, `runs_nonzero`, …),
  `background_tasks.watchers` (monitors, not work). `show` adds `observed_detail` (commands with time,
  exit code, duration, kind, compound/background/after-Stop flags, a failed run's tail; files changed;
  files shown; artifacts).

### Phase 5.11 additions (compatible)
- Turn: `request_origin` — `user`, `user_pasted`, `automated` (a turn Claude Code started itself:
  only `<system-reminder>`, `<side-sessions-event>`, `<ci-monitor-event>`, `<task-notification>`
  blocks) or `unknown` (such blocks mixed with other text); read from the text's structure, `null`
  without a request. `earlier_user_request` — for an `automated` turn, the latest earlier request from
  the user in the same session (`turn` plus the text reference), else `null`.
- Request text references: `display_preview` — the start of the request without those blocks and
  paste wrappers, for display only (`preview` stays verbatim); `null` when nothing else remains.
- `observed.commands_nonzero` — shell commands of any kind that exited non-zero (`runs_*` count only
  tests and builds).
- Session `title`: Claude Code's `session_title` when the first request is not the user's and a
  title exists.

### Phase 12 additions (compatible)
- Session summary and result: `profile{id,provider,basis,default,hint}` — the local agent
  profile, i.e. the configuration folder the agent ran with (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`, or
  the provider's default). `id` is `cc-default` / `cx-default` for the default folder, else the
  provider prefix and 16 hex digits of SHA-256 over the folder's real path; `basis` is
  `config_dir`, `default_home` or `installation` (older Codex records, from `installation_id`);
  `hint` is `~/<folder>` under the home folder, else the last path component — never a user name.
  **Not an account**: credentials are never read. Absent for Claude Code records written before
  Phase 12 (the app shows them as Unassigned).
- `native_session_id`: the agent's own session id when the stored key was scoped. A Claude Code
  session from a non-default config folder is stored as `<session_id>.<12 hex of the profile>`,
  so equal ids from two folders never share a history; the default folder keeps the plain id
  (existing keys unchanged). The hook payload itself is stored verbatim; profile and scoping
  live in the record envelope (`agent_profile`, `session_id`, `native_session_id`).
- New command `results` (above).

### Turn
| Field | Meaning |
|---|---|
| `index` | 1-based, stable (history is append-only) |
| `status` | `awaiting_response`, `no_matched_response`, `stop_received`, `stop_received_background_tasks_pending`, `stop_received_without_text`, `api_error`. No status means "task succeeded" |
| `link` | how firmly the response belongs to the request: `prompt_id` (confirmed), `sequence` (inferred from order), `ambiguous` (several candidates; this turn has no request), `none` |
| `request` | the turn's own prompt (`text_summary`/`text_full`) or `null` |
| `final_response` | the last Stop's text or `null`. An empty string is a real (empty) final response |
| `response_event_count` | Stop/StopFailure events in the turn (continuations, wake-ups) |
| `candidate_request_turns` | for `ambiguous`: indexes of the turns whose prompt it might answer |
| `background_tasks` | from the last Stop: `{reported:false,count:null}` when Claude Code sent no task list; `null` when there is no Stop |
| `error` | for `api_error`: `{type, details, message}`. `message` is the API error string, never Claude's answer |

### Text reference
`preview` (the first 200 code points, unmodified), `truncated`, `char_count`
(Unicode code points, **not** Swift grapheme clusters), `utf8_bytes`,
`prompt_id`, `received_at`. In `show` only: `text`, the complete verbatim
text.

### Plan (`delete`, `prune`)
`operation`, `dry_run`, `criteria{older_than_days,session,all,force_active}`,
`now`, `cutoff`, `active_grace_minutes`, and `summary{matched,would_delete,
deleted,skipped,failed,bytes_freed}`. `items[]` hold `session_id`,
`session_key`, `project`, `last_activity_at`, `turn_count`, `bytes`,
`action`, `reason`. `action` is one of: `would_delete`, `deleted`,
`skipped_active`, `skipped_changed`, `skipped_unsafe`, `vanished`, `failed`.

## 4. Examples (abridged, from the golden files)

`turns --json` for an ambiguous response (`05_ambiguous`):
```json
{"api_version":1,"command":"turns","ok":true,"error":null,"warnings":[],
 "data":{"session":{"session_id":"sess-min","turn_count":3,"…":"…"},
  "turns":[
   {"index":1,"status":"no_matched_response","link":"none","request":{"preview":"first","…":"…"},"final_response":null,"candidate_request_turns":[]},
   {"index":2,"status":"no_matched_response","link":"none","request":{"preview":"second","…":"…"},"final_response":null,"candidate_request_turns":[]},
   {"index":3,"status":"stop_received","link":"ambiguous","request":null,"final_response":{"preview":"which one?","…":"…"},"candidate_request_turns":[1,2]}]}}
```

`show --json` after an API error (`06_api_error`), exit 3:
```json
{"api_version":1,"command":"show","ok":false,
 "error":{"code":"no_final_response","message":"The turn ended with an API error (StopFailure). There is no successful final response."},
 "data":{"session":{"…":"…"},"turn":{"index":1,"status":"api_error","link":"prompt_id","final_response":null,
   "error":{"type":"rate_limit","details":"429 Too Many Requests","message":"API Error: Rate limit reached"},"…":"…"}},
 "warnings":[]}
```

`show --json` text field for `Привет, мир! 🚀` (`01_single_real_desktop`):
```json
"text": "Привет, мир! 🚀"
```

`delete --session sess-a --yes --json` on a session used minutes ago, exit 6:
```json
{"ok":false,"error":{"code":"active_session","message":"active session(s) were kept; re-run with --force-active to delete them"},
 "data":{"operation":"delete","dry_run":false,"items":[{"session_key":"sess-a","action":"skipped_active","reason":"last activity 0 min ago (< 30 min); use --force-active to include","…":"…"}],"…":"…"}}
```

## 5. Errors and exit codes
| Exit | `error.code` | When |
|---|---|---|
| 0 | — | success, including empty results (`"sessions": []`) |
| 1 | `storage_error`, `unsafe_path`, `config_error`, `internal_error` | storage unreadable; symlinked `events/`; broken `config.json`; unexpected failure (message names only the exception type) |
| 2 | `usage_error`, `confirmation_required` | bad options; `delete` without `--yes`/`--dry-run` (data holds the preview) |
| 3 | `not_found`, `ambiguous_selection`, `no_final_response` | nothing matches; a session prefix matches several; the selected turn has no final response (data holds the turn) |
| 6 | `active_session` | `delete --yes` kept a session active in the last 30 min |

`turns` with no captured sessions is `not_found` (it needs a session).
`sessions` with none is `ok` with an empty list.

Warning codes (open set): `newer_prompts_awaiting_response`,
`api_error_after_stop`, `background_tasks_pending`, `corrupt_lines_skipped`,
`unsupported_lines_skipped`, `foreign_lines_ignored`, `sensitive_content`,
`active_sessions_kept`, `retention_setting_invalid`.

## 6. Versioning and change rules
1. `api_version` is an integer. Consumers **must** check it and refuse
   documents whose major version they do not know.
2. **Compatible changes, same version:** new fields, new commands, new
   warning codes, new error codes, new enum values (`status`, `link`,
   `action`). Consumers must ignore unknown fields and handle unknown enum
   values with a fallback ("unknown status"), never crash.
3. **Breaking changes → `api_version` + 1:** removing or renaming a field,
   changing a type or nullability, changing the meaning of a field or of an
   existing enum value, changing an exit code, or changing the transport
   rules in §1.
4. The schema is closed for the producer (`additionalProperties: false`).
   Every new field is added to the schema in the same change, so golden tests
   fail on accidental changes.
5. Process for any change: edit the code → regenerate the golden files
   (`PROMPT_RELAY_UPDATE_GOLDEN=1 python3 -m unittest discover -s tests -k Golden`)
   → review the diff → update the schema and this document → decide
   compatible vs breaking by rules 2–3 → note it in `docs/STATUS.md`.
6. While the version is unreleased (no app depends on it), version 1 may
   still change; from the first app build, rules 2–3 are binding.

## 7. Notes for the Swift consumer
- Run the CLI with an absolute interpreter path (as `hook-config` does) and
  `PROMPT_RELAY_HOME` only when testing. Read stdout fully, then decode.
- `JSONDecoder` decodes `\u` escapes, including surrogate pairs. A lone
  surrogate (invalid Unicode, practically never produced by Claude) cannot be
  decoded into a Swift `String`; treat that as a decoding error for the one
  field.
- Use the `session_key` and `index` pair as the stable identity of a turn.
- Show `request` only together with `link`: for `sequence`, say "inferred".
