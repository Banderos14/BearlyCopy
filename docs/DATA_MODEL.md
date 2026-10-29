# Data model and on-disk contract (schema 1)

This file is the contract between the Python Core and any future reader, such
as the SwiftUI app. Change it only together with `store.SCHEMA_VERSION`.

## Directory

| Platform | Default | Override |
|---|---|---|
| macOS | `~/Library/Application Support/PromptRelay/` | `$PROMPT_RELAY_HOME` |
| other | `$XDG_DATA_HOME/prompt-relay/` or `~/.local/share/prompt-relay/` | `$PROMPT_RELAY_HOME` |

```
<root>/                      0700
  config.json                0600
  handler.log, handler.log.1 0600  rotated at 256 KiB; metadata only
  events/                    0700
    <session-key>.jsonl      0600
```

`<session-key>` is the `session_id` when it matches
`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`. Otherwise it is `h-` followed by the
first 32 hex characters of the SHA-256 of the id. Events without a session
id use `_no-session`. Readers must take the real id from the records, not
from the filename.

## config.json

```json
{ "schema": 1, "enabled_projects": ["/Users/me/code/app"] }
```

Paths are `realpath`-normalized. A project matches when the event's project
dir equals an entry or lies below it, compared by path components, so
`/a/app-other` does not match `/a/app`. Any parse or shape error means
**capture off**.

## Event envelope (one JSON object per line)

```json
{
  "schema": 1,
  "record_id": "9f1c…32 hex",
  "received_at": "2026-10-29T09:53:11.767453Z",
  "received_at_epoch": 1793267591.767453,
  "hook_event_name": "Stop",
  "session_id": "abc123",
  "fingerprint": "sha256:…",
  "context": { "claude_project_dir": "/Users/me/code/app", "claude_code_remote": "true" },
  "payload": { "…": "the hook stdin object, unchanged" }
}
```

- Lines are written with `ensure_ascii=True`, so files are pure ASCII. This
  is lossless for every JSON string, including emoji and lone surrogates.
- `payload` is the parsed stdin object as received. Normalization happens at
  read time, so later readers can use fields that today's code ignores.
- `context` keys are optional. They are present only when the environment
  variable was set.
- `fingerprint` = SHA-256 of the payload serialized with sorted keys, no
  whitespace and `ensure_ascii`. Key order therefore does not matter.
- Order of lines = order of reception for that session, serialized by `flock`.

### Duplicate rule
A new record is a duplicate when a record with the same fingerprint already
exists in the session file **and** either the payload has a `prompt_id`, or
the earlier copy was received within 120 s. Identical prompts without
`prompt_id` sent minutes apart are kept as separate events.

### Reader rules
- Skip blank lines.
- Count lines that are not JSON objects with an object `payload` as
  *corrupt* and skip them. A killed writer can leave one partial last line.
  The next writer starts a new line.
- Skip `schema` values other than 1 as *unsupported*. Never rewrite them.
- Take a shared `flock` while reading, if one can be obtained within 3 s.

## Normalized event (read side)

| Field | From | Notes |
|---|---|---|
| kind | `hook_event_name` | `prompt` / `stop` / `stop_failure`; everything else is ignored |
| session_id, prompt_id, cwd, transcript_path, agent_id | payload | non-empty strings or null |
| project_dir | `context.claude_project_dir` else `cwd` | |
| text | `prompt` (prompt) or `last_assistant_message` (stop, stop_failure) | string or null. For `stop_failure` it is the API error string |
| stop_hook_active | payload | bool or null |
| background_tasks, session_crons | payload | list or null |
| error, error_details | payload (StopFailure) | |

## Turn (derived, not stored)

`index`, `prompt`, `responses[]`, `link` (`prompt_id|sequence|ambiguous|none`),
`candidate_prompts[]`, `status`, `final_response` (the last `stop` with non-null
text). See ARCHITECTURE §5.

## Deletion

`prompt-relay delete --session ID --yes` removes one session file.
`delete --all --yes` removes all session files. `config.json` and the logs
stay. Removing the whole `<root>` directory is always safe.
