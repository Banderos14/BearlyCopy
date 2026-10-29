# Architecture

Status: Phase 1 proof of concept. Components marked *planned* do not exist yet.

## 1. Overview

```
 Claude Code (CLI / Desktop local session)
   │  hook events: UserPromptSubmit, Stop, StopFailure   (JSON on stdin)
   ▼
 ┌──────────────────────────── Prompt Relay Core (platform-independent) ──┐
 │ bin/prompt-relay hook ──► hook.py ──► config.py (project allowlist)    │
 │                              │                                          │
 │                              ▼                                          │
 │                           store.py  ──►  <data dir>/events/<sid>.jsonl  │
 │                                                                          │
 │ CLI (cli.py) ──► history.py ──► events.py + correlation.py              │
 │                     │                                                    │
 │                     ├──► export.py (Copy Response / Copy Context)        │
 │                     │        ├── gitinfo.py (read-only, export time)     │
 │                     │        └── sensitive.py (warn, never modify)       │
 │                     └──► clipboard.py ── file MOCK backend               │
 └─────────────────────────────────────│──────────────────────────────────┘
                                       │  macOS-specific boundary
                                       ▼
                          /usr/bin/pbcopy (PoC)  ·  NSPasteboard (planned app)

 Planned: SwiftUI/AppKit menu-bar + notch app that reads the same data dir
          (docs/DATA_MODEL.md) and writes the clipboard via NSPasteboard.
```

## 2. Components and responsibilities

| Module | Responsibility | Must not |
|---|---|---|
| `hook.py` | parse stdin, filter events, check the allowlist, build the envelope, append | write stdout, exit non-zero, touch the network, read the transcript or project files, run git |
| `config.py` | the opt-in list of project roots; fails closed | capture anything when the config is missing or broken |
| `store.py` | append-only per-session JSONL, locking, dedup, permissions, tolerant reads | rewrite or reorder existing lines |
| `events.py` | typed, defensive view of the documented payload fields | invent fields |
| `correlation.py` | group one session's events into turns, with an explicit link quality | combine sessions or guess an ambiguous link |
| `history.py` | load sessions, filter by project/session, choose the turn | skip newer pending turns silently (it warns) |
| `export.py` | verbatim response; context packet with provenance labels | change response text or upgrade claims to facts |
| `gitinfo.py` | branch, HEAD, porcelain status; read-only and hardened | write `.git`, run repo-configured commands |
| `sensitive.py` | secret-pattern findings (kind and line only) | echo secrets, alter text |
| `clipboard.py` | `pbcopy` (macOS) or file MOCK | use a shell; guess an encoding (it forces a UTF-8 locale) |
| `cli.py` | user commands, exit codes | install hooks or edit Claude settings |

Only `clipboard.PbcopyBackend` and the default data path are macOS-specific.
Everything else runs and is tested on Linux.

## 3. Data flow

1. Claude Code runs `bin/prompt-relay hook` (exec form, `timeout: 10`) and
   pipes one JSON object to it.
2. `bin/prompt-relay` takes a fast path straight into `hook.main`, skipping
   argparse and the export modules.
3. The handler drops anything that is not UserPromptSubmit, Stop or
   StopFailure, or whose project (`$CLAUDE_PROJECT_DIR`, else `cwd`) is not
   enabled.
4. It wraps the **unchanged payload** in an envelope (record id, receive time,
   fingerprint, env context) and appends it to `events/<session>.jsonl` under
   an exclusive `flock`, followed by `fsync`.
5. It logs `timestamp event outcome` to `handler.log` and exits 0.
6. Later, the user runs `prompt-relay copy` (or the future app does the same).
   The store is read, events are normalized and grouped into turns, a turn is
   chosen, and the text goes to the clipboard.

## 4. Hook handler contract

- Input: one JSON object, any key order, every field optional and type-checked,
  up to 64 MiB. Unknown fields are preserved inside the envelope.
- Output: nothing on stdout. On unexpected outcomes, one line on stderr of the
  form `prompt-relay: <code>`, with no message content. Exit code 0 in every case.
- Outcomes (logged): `stored`, `duplicate`, `ignored_event`,
  `project_not_enabled`, `disabled`, `invalid_json`, `invalid_utf8`,
  `invalid_payload`, `payload_too_large`, `config_*`, `storage_unavailable`,
  `write_failed`, `lock_timeout`, `internal_error:<Type>`.
- Kill switch: `PROMPT_RELAY_DISABLE=1`.
- Bounded time: the lock wait is at most 3 s. There is no network or git work.
  The measured median is about 60 ms on the cloud VM (`scripts/check.sh`).

## 5. Session correlation

The full rules are in the `correlation.py` docstring. Summary:

| Situation | Result | `link` |
|---|---|---|
| response `prompt_id` == a captured prompt's `prompt_id` | linked | `prompt_id` (confirmed) |
| response has a `prompt_id` that was never captured, exactly one prompt pending and that prompt has **no** `prompt_id` | linked | `sequence` (inferred) |
| response has a `prompt_id` that was never captured, otherwise | its own turn, no request | `none` |
| no `prompt_id`; exactly one prompt since the last response | linked | `sequence` (inferred, labeled as such in exports) |
| no `prompt_id`; several prompts pending | its own turn; the prompts are listed as candidates | `ambiguous` |
| no `prompt_id`; no new prompt; `stop_hook_active` or the previous Stop had background tasks | joins the previous turn | unchanged |
| no `prompt_id`; no new prompt; otherwise | its own turn | `none` |

Further rules:
- A `prompt_id` match leaves other pending prompts pending. A link inferred by
  order is never upgraded to `prompt_id` by a later response.
- Events stored without a `session_id` (`_no-session` file) are never linked:
  each becomes its own turn with `link=none`.
- Reading a session file ignores, and counts, records whose `session_id` does
  not belong to that file.
- One turn can hold several responses: stop-hook continuations and background
  wake-ups. The **final response** is the last `Stop`. If that Stop carries no
  text, there is no final response; older text is never promoted.
- Status is derived from the last response event: `stop_received`,
  `stop_received_background_tasks_pending`, `stop_received_without_text`,
  `api_error`. Without responses, the status is `awaiting_response` or
  `no_matched_response`. No status says "success".
- Sessions are never merged. A resumed session that keeps its `session_id`
  appends to the same file. A forked or new id gets its own file.
- A directory change inside a session is recorded per event (`cwd`). The
  project identity stays `CLAUDE_PROJECT_DIR`.

## 6. Storage

See `docs/DATA_MODEL.md` for the on-disk contract and ADR-003 for the choice
of format.

## 7. Export

- **Copy Response** (`copy`, `show`): the exact final `last_assistant_message`,
  encoded as UTF-8. Refused when there is no final response, the text is
  empty, or the turn ended in an API error. Warns when background tasks were
  pending.
- **Copy Context** (`copy-context`, preview with `context`): a Markdown packet.
  Request and response are wrapped in fences longer than any backtick run they
  contain. It carries provenance labels, read-only git state *at export time*,
  an explicit "tests/CI not verified" section, and a review request. The
  secret scan blocks copying until `--allow-sensitive` is passed.

## 8. Boundaries with the future macOS app (ADR-004)

- The Core owns the data format, correlation and export semantics. The app
  must produce the same results for the shared fixtures.
- Integration options, to decide in Phase 2 (see ROADMAP): (a) the app shells
  out to `prompt-relay --json` commands; (b) the app re-implements the read
  side in Swift against `DATA_MODEL.md` and the fixtures. The hook handler
  can stay Python in both cases.
- The app writes the clipboard with `NSPasteboard` (`.string` type),
  replacing `pbcopy`.
