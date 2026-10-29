# Architecture

Status: Phase 2B (Core + Claude Code plugin). Components marked *planned* do not exist yet.
Source layout: the Core package is `plugin/prompt_relay/`, inside the Claude
Code plugin root (`plugin/`), and the CLI is `bin/prompt-relay`. See
`docs/PLUGIN.md`.

## 1. Overview

```
 Claude Code (CLI / Desktop local session), plugin "prompt-relay" enabled
   │  hook events: UserPromptSubmit, Stop, StopFailure   (JSON on stdin)
   │  /bin/sh ${CLAUDE_PLUGIN_ROOT}/hooks/run-hook  → finds Python 3.9+
   │  → python -I -S hooks/prompt_relay_hook.py
   ▼
 ┌──────────────────────────── Prompt Relay Core (platform-independent) ──┐
 │ (or bin/prompt-relay hook for settings-based checks)                   │
 │ hook.main ──► hook.py ──► config.py (project allowlist)                │
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
| `api.py` | JSON API v1: envelope and serializers over the read model (ADR-006) | write anything to stderr in `--json` mode; expose text outside `show`/`context` |
| `retention.py` | plan, preview and execute deletion of whole session files (ADR-007) | delete without `--yes`, delete anything but plain session files in `events/`, delete active sessions unforced, run automatically |
| `runtime.py` | the pinned hook interpreter (`<data dir>/python-path`) | run in the hook path |
| `integration.py` | read-only diagnostics of the plugin and settings registrations, plus observed events (`doctor`) | write anything, run Claude Code, print other tools' hook commands |
| `plugin/hooks/run-hook` | POSIX launcher: find Python 3.9+, `exec python -I -S` | write stdout, exit non-zero, rely on `PATH`, run `/usr/bin/python3` without the CLT |
| `cli.py` | user commands, exit codes, `--json` dispatch | install hooks or edit Claude settings |

Only `clipboard.PbcopyBackend` and the default data path are macOS-specific.
Everything else runs and is tested on Linux.

## 3. Data flow

1. Claude Code runs the plugin hook `/bin/sh ${CLAUDE_PLUGIN_ROOT}/hooks/run-hook`
   (exec form, `timeout: 10`) and pipes one JSON object to it. In validation
   setups, a settings hook runs `bin/prompt-relay hook` instead.
2. `run-hook` picks a Python 3.9+ (the pinned one, then known locations) and
   execs `python -I -S hooks/prompt_relay_hook.py`, which imports
   `hook.main` from the plugin root. Argparse and the export modules are
   never loaded.
3. The handler drops anything that is not UserPromptSubmit, Stop or
   StopFailure, or whose project (`$CLAUDE_PROJECT_DIR`, else `cwd`) is not
   enabled.
4. It wraps the **unchanged payload** in an envelope (record id, receive time,
   fingerprint, env context) and appends it to `events/<session>.jsonl` under
   an exclusive `flock`, followed by `fsync`.
5. It logs `timestamp event via=<plugin|direct> outcome` to `handler.log`
   and exits 0.
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

## 8. JSON API for the macOS app (ADR-006)

`--json` on `projects`, `sessions`, `turns`, `show`, `context`, `delete`,
`prune` and `retention` returns one versioned JSON document (`api.py`,
contract in `docs/JSON_API.md`, schema in `docs/api/api-v1.schema.json`).

```
SwiftUI app ──exec──► <python> bin/prompt-relay <command> --json ──► stdout: one JSON document
     │                         (reads <data dir>, never writes except delete/prune/retention)
     └──► NSPasteboard (writes the text from show/context itself)
```

- `api.py` holds pure serializers over the existing read model
  (`history` → `correlation` → `events`). It adds no new storage and no state.
- `cli.py` keeps the text output byte-compatible. In `--json` mode, every
  message that would go to stderr becomes a structured `warning` or `error`.
- Golden files pin the output: `tests/golden/cases` (events and queries) and
  `tests/golden/expected` (responses).

## 9. History management (ADR-007)

`retention.py` plans and executes deletion of whole session files.

| Command | Default | Deletes when |
|---|---|---|
| `delete --session ID\|KEY` / `--all` | preview, exit 2 | `--yes` |
| `delete … --dry-run` | preview, exit 0 | never |
| `prune [--older-than-days N]` | preview (dry run) | `--yes` |
| `retention --days N` / `--off` | shows the setting | never (stores the default for `prune`) |

- Nothing is deleted automatically. The hook never prunes.
- *Last activity* = the later of the last event time and the file mtime. It
  drives both age and activeness, so touching a file can only delay deletion.
- *Active* = last activity under 30 min ago. `prune` always keeps active
  sessions. `delete` keeps them unless `--force-active` is given (exit 6
  otherwise).
- Execution re-checks every file under its exclusive `flock`: it must still
  be a regular, non-symlink file named like a session file, directly in a
  non-symlink `events/`, with the planned size and mtime. Otherwise it is kept
  (`skipped_changed`, `skipped_unsafe`, `vanished`).
- A hook that was waiting for that lock sees `st_nlink == 0` after the
  unlink and reopens the path, so a concurrent event is never lost.

## 10. Claude Code integration: plugin first (ADR-008)

- The repository is a marketplace (`.claude-plugin/marketplace.json`) with one
  plugin, `./plugin`. Claude Code owns install, enable, disable, update and
  uninstall. Prompt Relay never edits settings files.
- The plugin root changes with every version (`cache/…/<version>/`). It
  holds only code. History and `python-path` live in the data dir, which an
  update or uninstall never touches. `${CLAUDE_PLUGIN_DATA}` is not used,
  because uninstall deletes it.
- A local-path marketplace install is also copied into the cache (observed
  on the Mac, CLI 2.1.268), so the root is `cache/…/<version>/`, not the
  checkout's `plugin/`.
- Double registration (the plugin plus a settings hook) is harmless for the
  data: the second handler run finds the same fingerprint and logs
  `duplicate`. `doctor` reports it from configuration and from `via=` in
  the log.
- Coexistence: hooks from all sources run in parallel. Ours never writes
  stdout or decides anything, so other tools' hooks (NotchBuddy) behave as
  before.

## 11. The macOS app (ADR-004, ADR-006, ADR-009, ADR-010, ADR-011)

`macos/` is a Swift package: `PromptRelayKit` (API models, the CLI adapter,
clipboard, FSEvents and report-store services, the one `AppModel`, the
island's views) and `PromptRelayApp` (lifecycle only). Details:
`docs/MACOS_APP.md`; product rules: `docs/PRODUCT_UX_SPEC.md`.

```
 island (notch or floating) ─┐                ┌─► CoreClient ─(python -I -S -B prompt-relay … --json)─► Python Core ─► events/
 menu-bar fallback menu ─────┴─► AppModel ────┼─► ReportStore ─► <data dir>/app/ (imports, attachments; app-owned)
                                 (@Observable)├─► ClipboardService ─► NSPasteboard (text read back; text + images)
                                       ▲      └─► SecretScanner (imports only; same patterns as the Core)
                                       └── StoreWatcher (FSEvents on events/*.jsonl, config.json)
```

Boundaries:

- The Core owns the captured data, correlation and the local Review Pack.
  The app reads them through the JSON API and never parses `events/`.
- The app owns `app/` (manual imports and attachments). The Core does not
  read it; the app does not write `events/`.
- The hook handler stays Python; the app is never in the hook path.
- Claude Code cloud sessions are outside both: the hooks cannot observe
  them, so they enter only through the explicit Import (MACOS_APP.md §6).
