# Architecture Decision Records

Format: Context / Decision / Alternatives / Consequences / Status.

---

## ADR-001: Local-first, no AI API

**Context.** Prompt Relay moves Claude Code results to ChatGPT. The content
is source code, plans and sometimes secrets. Users already pay for Claude and
ChatGPT. The goal is to remove copy-paste friction, not to add another model.

**Decision.** All data stays on the device. There is no server, sync,
telemetry, OpenAI API or additional Anthropic API call. Delivery to ChatGPT
is a manual paste by the user. The code contains no network client, and a
test (`test_s16`, `SourceSafetyTests`) enforces this.

**Alternatives.** (a) Send results straight to ChatGPT through the API:
costs money, needs API keys, and sends code to a third party automatically.
(b) Browser automation of chatgpt.com: fragile, against the spirit of
explicit user control, and a large security surface. (c) A cloud relay: a
server, accounts and a privacy burden.

**Consequences.** + Simple, private, offline-capable. + No keys to manage.
− The user still pastes into ChatGPT, which is acceptable by the product
definition. − No cross-device history.

**Status.** Accepted.

---

## ADR-002: Official Claude Code hooks as the only event source

**Context.** Prompt Relay needs the full final text of each Claude response,
plus the prompt that led to it. The alternatives are screen scraping,
transcript parsing or hooks.

**Decision.** Use documented command hooks: `UserPromptSubmit` (`prompt`),
`Stop` (`last_assistant_message`) and `StopFailure` (to label API errors).
Do not read `transcript_path`. The docs say the transcript may lag at Stop
time, and its format is not a public contract. Other events (SessionStart,
SessionEnd, Notification, SubagentStop) are researched in
`HOOKS_RESEARCH.md` and not connected.

Installation strategy:
- PoC / validation: session-scoped `claude --settings <file>` for the CLI,
  and a throw-away sandbox project with `.claude/settings.local.json` for
  Desktop. Neither touches `~/.claude/settings.json`.
- Public version (planned): a **Claude Code plugin** that ships
  `hooks/hooks.json`, so Claude Code owns install and uninstall. As a
  fallback, an installer that *merges* into user settings, with JSON
  validation, a backup, an idempotency marker, a dry-run diff and an
  uninstall. Each of these steps requires explicit consent.

**Alternatives.** (a) Transcript file watching: undocumented format, lags,
needs filesystem watching. (b) Accessibility or screen reading of the
terminal: fragile, needs broad permissions, loses Markdown. (c) Wrapping the
`claude` process stdout: breaks the TUI and does not work for Desktop.
(d) An MCP server: Claude decides when to call it, so capture would not be
reliable.

**Consequences.** + Supported, version-tolerant integration. + Exact text.
− Depends on the hook schema. Every field is treated as optional, and
unknown fields are preserved. − Interrupted turns produce no Stop. −
Interactive sessions run hooks only after workspace trust is accepted.

**Status.** Accepted. Plugin packaging is planned for Phase 3.

---

## ADR-003: Storage — append-only JSONL, one file per session

**Context.** Requirements: survive restarts, tolerate empty or corrupt data,
handle concurrent hook processes (two Stops at once), support deletion, keep
restrictive permissions, stay simple, and be readable later by a Swift app.

**Decision.** One JSONL file per session under the app data directory. Each
append runs under an exclusive `flock`, writes one buffer and calls `fsync`.
Readers skip corrupt lines. The raw payload is kept in an envelope (see
`DATA_MODEL.md`).

| Criterion | JSONL per session (chosen) | SQLite | Single JSON file |
|---|---|---|---|
| Concurrent writers | `flock` per session; different sessions never contend | WAL plus busy timeout; good | needs a global lock and a whole-file rewrite; poor |
| Crash safety | at most one partial last line, skipped | journaled; excellent | a torn rewrite can lose everything unless done via tmp+rename |
| Corruption blast radius | one line | whole DB, recoverable with tools | whole file |
| Simplicity / zero deps | stdlib, human-readable | stdlib `sqlite3`, opaque file | simplest |
| Query (latest per project) | scan files (fine at PoC scale) | indexed | load all |
| Delete one session | `unlink` | `DELETE` plus `VACUUM` to really erase | rewrite |
| Swift reader | trivial (`JSONDecoder` per line) | `libsqlite3` (system) | trivial |

**Alternatives.** SQLite was the strongest alternative and is the planned
migration if history grows (thousands of sessions) or the UI needs indexed
queries. The JSONL envelope can be imported losslessly. A single JSON file
was rejected because of concurrency and crash risk.

**Consequences.** + Very robust under concurrency and crashes. + Easy
inspection and deletion. − Dedup reads the session file on every append
(O(session size)). This is acceptable for sessions of a few MB. Revisit at
about 10 MB per session. − Listing scans all files.

**Status.** Accepted for Phase 1. Revisit in Phase 3 (criteria in ROADMAP).

---

## ADR-004: Separate the Core from the macOS UI; PoC Core in Python

**Context.** The product will be a native SwiftUI/AppKit app. The current
development environment is a Linux cloud container where Swift cannot be
installed: `download.swift.org` is blocked by the egress policy, as observed
on 2026-10-29. The hook handler must start fast, have no dependencies and run
on a stock Mac.

**Decision.**
1. Split the system into a **platform-independent Core** (event model,
   storage, correlation, export) and **macOS adapters** (clipboard; later the
   UI and notch window).
2. Write the PoC Core in **Python 3.9+, standard library only**. A developer
   Mac has `/usr/bin/python3` 3.9.6 from the Xcode Command Line Tools. The
   tests run on 3.9 and 3.13.
3. Make the **data format** (`DATA_MODEL.md`) and the **fixtures**
   (`tests/fixtures`) the language-neutral contract, so the Swift app can read
   the store directly, or the handler can be ported later and checked against
   the same fixtures.

**Alternatives.** (a) Swift Core now: the best long-term fit, but it cannot be
built or tested in the cloud, which would mean shipping untested code. (b)
Node.js: not guaranteed on a Mac, because Claude Code's native installer does
not need Node. (c) A shell script with `jq`: `jq` is not on stock macOS, and
robust locking and Unicode handling are hard.

**Consequences.** + Fully tested today. + Zero install on a developer Mac.
− Needs some Python 3.9+. `/usr/bin/python3` works only with the Xcode CLT;
without them it is an installer stub. Homebrew or python.org Python work
too. `hook-config` pins the absolute interpreter path, so hooks never depend
on `PATH` (audit fix, 2026-10-29). − Possible later
port of the handler to Swift (ROADMAP Phase 3 decision), limited by the
format contract and fixtures. − About 60 ms interpreter start per hook;
acceptable against a 10 s timeout.

**Status.** Accepted for the PoC. Re-evaluate when the Swift app exists.

---

## ADR-005: Privacy and explicit export

**Context.** Prompts and responses can contain secrets, private code or
personal data. Moving them to another AI service is the user's decision.

**Decision.**
- Capture is **opt-in per project** (`prompt-relay enable <dir>`). With a
  missing or broken config, nothing is captured. `/` and `$HOME` cannot be
  enabled.
- Data lives only under the user data directory (0700 dir, 0600 files), never
  inside a repository. `.gitignore` excludes `*.jsonl` as a second line of
  defence.
- No message text goes to logs (`handler.log` holds timestamp, event and
  outcome) or to stderr.
- The handler never reads `.env`, keys or project files. Git metadata is
  collected only at export time, read-only, with `core.fsmonitor` disabled.
- Export happens only on an explicit command. **Copy Response** copies exactly
  what Claude wrote. **Copy Context** can be previewed (`context`), is scanned
  for secret patterns, and is blocked until `--allow-sensitive`. Findings show
  only the type and line number.
- Claims by Claude ("tests pass", "CI green") are always labeled
  *Reported by Claude* / *Not verified*.
- History can be deleted per session or entirely.

**Alternatives.** Auto-redacting secrets: rejected, because it changes the
verbatim text and gives false confidence. Encrypting at rest: deferred. The
macOS user account plus FileVault already protect the data dir. Keychain-backed
encryption is a Phase 3+ option.

**Consequences.** + Predictable, auditable data handling. − An extra step
(`--allow-sensitive`) when the secret scan finds something that is not a
secret.

**Status.** Accepted.

---

## ADR-006: The macOS app talks to the Core through a versioned JSON CLI API

**Context.** The SwiftUI app needs projects, sessions, turns, final texts and
the Copy Context packet. The Core is Python (ADR-004), and the correlation
rules are subtle (prompt_id vs sequence vs ambiguous, API errors, background
tasks). Re-implementing them in Swift would duplicate logic that has to
behave identically.

**Decision.** The app runs `prompt-relay <command> --json` and decodes one
versioned JSON document (`docs/JSON_API.md`, `docs/api/api-v1.schema.json`).
Transport: ASCII-only JSON on stdout, nothing on stderr, the same exit codes
as text mode. Golden files pin the output. Breaking changes bump
`api_version` (JSON_API.md §6). The app does not parse the JSONL store.

**Alternatives.** (a) Swift reader of the JSONL files: duplicates the
correlation logic, and the two implementations can drift. (b) A local
HTTP/XPC server: a long-running process, a port or a service, and more attack
surface, for no gain in the MVP. (c) SQLite as the shared interface: a storage
migration plus a second schema contract.

**Consequences.** + One implementation of the rules, testable in the cloud.
+ The text CLI is unchanged. − A process start (about 50–100 ms) per call; the
app should cache and refresh on change (file watching of `events/`). − The app
needs a Python 3.9+ path, which it gets the same way as `hook-config`.

**Status.** Accepted (Phase 2A). Version 1 is unreleased until the first app
build.

---

## ADR-007: History deletion is explicit, previewed and file-granular

**Context.** Users need retention and deletion, but the store is append-only
JSONL written concurrently by hooks, and the data is the user's only copy.

**Decision.** Deletion removes whole session files only. Every destructive
command previews by default and needs `--yes`. `retention_days` is only the
default threshold for `prune`; nothing deletes automatically. "Last activity"
(the later of the last event and the file mtime) defines age and activeness.
Sessions active in the last 30 min are kept unless `--force-active` is given.
Execution re-checks each file under its lock, and only plain session files
directly in `events/` can be deleted.

**Alternatives.** (a) Per-record expiry by rewriting files: risks corrupting
an append-only file that a hook may be writing, and makes concurrency much
harder. (b) Automatic pruning in the hook: deletion as a side effect of
capture, against explicit user control. (c) Moving files to the macOS Trash:
better for a GUI, but it needs AppKit; the app can add it later.

**Consequences.** + Simple, safe and testable deletion. + Recoverable before
`--yes`. − Long sessions are kept or deleted as a whole. − The 30-minute
grace period is a heuristic. A session deleted after 30 min idle and resumed
later continues in a new file under the same key; its earlier turns are gone.

**Status.** Accepted (Phase 2A).
