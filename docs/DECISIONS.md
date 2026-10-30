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

---

## ADR-008: Plugin-first integration with Claude Code

**Context.** Users need a reproducible, low-effort way to connect Prompt
Relay to Claude Code (CLI and Desktop local sessions), without editing
`~/.claude/settings.json`, where other tools such as NotchBuddy keep their
global hooks. Phase 1.5 showed that Desktop starts hooks without the shell
environment and with a minimal `PATH`.

**Decision.**
- Ship Prompt Relay as an official Claude Code plugin. The repository root
  is a marketplace with one relative-path plugin, `./plugin`. Its
  `hooks/hooks.json` registers UserPromptSubmit, Stop and StopFailure in exec
  form: `/bin/sh ${CLAUDE_PLUGIN_ROOT}/hooks/run-hook`.
- The Core package lives inside the plugin root (`plugin/prompt_relay`)
  because installs copy only the plugin directory. There is one copy of the
  code, with no vendoring and no symlinks.
- The plugin root has no `bin/` (that would land on Claude's Bash `PATH`).
- The launcher finds Python without relying on `PATH`: a pinned interpreter
  written by the CLI, then known locations, then `/usr/bin/python3` only
  with the CLT, each version-checked. It runs the handler with `-I -S`.
- History stays in the app data dir, never in the plugin root or
  `${CLAUDE_PLUGIN_DATA}`.
- Capture remains opt-in per project. Installing the plugin captures
  nothing by itself.
- No settings-merge installer is built; `hook-config` stays for isolated
  validation only.

**Alternatives.** (a) A settings-merge installer: more code, and it writes
to a file shared with other tools. That is the risk the plugin avoids, and
it would need backup, merge and uninstall logic (SECURITY §5). (b) Plugin
root = repository root: exposes `bin/` on the Bash `PATH`, loads `CLAUDE.md`
warnings, and copies tests and docs into every install. (c) Vendoring a copy
of the package into `plugin/`: two copies that can drift. (d) A plugin hook
`python3 …` relying on `PATH`: breaks in Desktop, and can trigger the
`/usr/bin/python3` install stub.

**Consequences.**
+ Install, update and uninstall are Claude Code operations.
+ Other hooks are untouched.
+ Updates cannot lose history.
+ The real `claude plugin validate` and `plugin details` check the package.
− The repository layout changed: the package moved to `plugin/prompt_relay`.
− The launcher adds about 6 ms (sh plus a version check), measured 85–88 ms
  median vs 73–79 ms in the cloud.
− Whether a running Desktop session loaded the plugin can be proven only by
  observed `via=plugin` events.
− The private-repository GitHub marketplace needs local git credentials; the
  local-path marketplace does not.

**Status.** Accepted (Phase 2B). Mac validation pending (LOCAL_MAC_VALIDATION §11).

---

## ADR-009: Native app = Swift package over the JSON CLI, with the Core bundled

**Context.** Phase 3A needs a native app that lists sessions and copies
answers without a terminal, and later a notch UI. ADR-006 already fixes the
interface (CLI JSON API v1). Open points were the app's structure, where its
copy of the Core comes from, and how it learns about new answers.

**Decision.**
1. A Swift package in `macos/`: a reusable `PromptRelayKit` library and a
   thin `PromptRelayApp` executable. Every surface (menu-bar panel, window,
   later the notch) composes the same components over one `@Observable`
   `AppModel`.
2. `scripts/build-macos-app.sh` assembles `Prompt Relay.app` and copies the
   Core (`bin/prompt-relay`, `plugin/prompt_relay`) into
   `Contents/Resources/core` in the repository's layout. The hook keeps
   running from the plugin; the app only reads through the CLI.
3. The app runs the CLI as `python -I -S -B` with a minimal environment and
   finds Python with the plugin launcher's rules.
4. Updates come from FSEvents on the data dir (`events/*.jsonl`,
   `config.json`), with a 30 s timer only while a surface is visible when
   watching is impossible, plus manual Refresh.
5. macOS 14 minimum (`@Observable`, `MenuBarExtra`, `ContentUnavailableView`).

**Alternatives.** (a) An Xcode project: harder to review and to build from a
script; SwiftPM builds and tests from the command line. (b) Running the
CLI from the checkout: the app would break when the checkout moves.
(c) Polling the CLI: wasted process starts. (d) A Swift JSONL reader:
rejected by ADR-006.

**Consequences.** + No logic is duplicated; golden files test both sides.
+ The app works without the checkout. − The bundled Core can be older or
newer than the plugin's copy; both read the same versioned store
(`DATA_MODEL.md`) and the app checks `api_version`. − Each call starts
Python (≈40–60 ms). − Local ad-hoc signing only; notarization is Phase 5.

**Status.** Accepted (Phase 3A). Verified on the owner's Mac.

---

## ADR-010: Notch island = custom NSPanel + SwiftUI, presentation layer only

**Context.** Phase 3B adds a Dynamic-Island-style surface around the MacBook
notch. Candidates: OpenNook (framework) or a custom panel. Coucou
(NotchBuddy), MIT-licensed code with all-rights-reserved assets, is installed
on the owner's Mac and uses the same screen area.

**Decision.**
1. A custom borderless, non-activating `NSPanel` at `statusBar + 1`, on all
   Spaces including full screen, hosting a SwiftUI island. No dependency.
2. The window is resized to the island for every phase (notch, notch + ears,
   expanded card sized to its content) and hover uses an `NSTrackingArea`, so
   nothing polls and no transparent area catches clicks.
3. A pure state machine (`NotchInteraction`) owns transitions: dwell 0.15 s
   to open on hover, 0.35 s grace to close, click/⌃⌥⌘P open with focus,
   pinning while an alert is open. Geometry is pure (`NotchLayout`,
   `DisplayChoice`) and tested with mock displays.
4. The island is a presentation layer over the existing `AppModel`,
   `CoreClient`, `ClipboardService` and `StoreWatcher`; it adds no data path.
5. Off by default; one island on the chosen notched display; no island on
   displays without a notch (the menu-bar item stays). When Coucou runs, the
   island steps aside by default (setting), and Prompt Relay never changes
   Coucou.
6. No shadow and a black island in both appearances, so it merges with the
   hardware notch.

**Alternatives.** (a) OpenNook: macOS 15+, pre-1.0 API, owns the app entry
point. (b) Coucou's approach (fixed large panel, pointer polling at
8–60 Hz, `ignoresMouseEvents` toggling): smooth but costs wake-ups while idle.
(c) One panel per display: rejected (clutter, duplicate hover targets).

**Consequences.** + Zero idle cost; + full control of look and tests; + the
same model drives every surface. − Our own window code to maintain (about
600 lines with tests). − Coexistence with Coucou is tested with mocks, not
yet observed live.

**Status.** Accepted (Phase 3B), confirmed on the owner's Mac.

## ADR-011: One island; app-owned imports and attachments

**Context.** Phase 4 makes the island the whole interface and adds two kinds
of data the Core never sees: reports pasted from Claude Code cloud sessions
(the local hooks cannot observe them) and images the user attaches.

**Decision.**
1. No regular windows. The island hosts every view (Home, Projects, Recent
   Copies, History, Import, Settings, Full Report) with Back; the menu-bar
   item is a fallback menu that opens the island. The 3A/3C windows were
   removed once their functions were in the island.
2. Imports and attachments live in `<data dir>/app/`, owned by the app
   (0700/0600, atomic writes), next to the Core's data but never read by
   it. The Core and its JSON API are unchanged except for the Review Pack
   wording (title, "Source" line).
3. The Review Pack for an import is written by the app in the Core's format
   and labels; the Core's secret patterns are mirrored in Swift and checked
   against the Core in a test.
4. Recent Copies and pins store references (`ReportRef`), never text.
5. Cloud capture is manual import only, because no documented interface
   returns cloud-session messages; `--teleport` is not used (it changes the
   repository).

**Alternatives.** (a) Imports through the Core (a new write command): more
API surface and a second writer of the Core's store for data the hooks
never produce. (b) Scraping Claude Desktop or claude.ai data: undocumented
and a privacy risk. (c) Keeping the windows as a second interface: two
places for the same functions, which Phase 4 set out to remove.

**Consequences.** + one interface, one model; + the Core stays the only
writer of captured history; + imports work offline and are labeled. − two
secret scanners to keep equal (a test guards it); − history search over
captured reports sees only the Core's previews.

**Status.** Accepted (Phase 4).


## ADR-012: Earlier requests of the same session in the Review Pack (proposal)

**Context.** Requests like «продолжи где остановился» ("continue where you
stopped") are common. The Review Pack then shows that sentence as the
original request; the reviewer cannot tell what was asked. Seen on the
real store (2026-10-30): turn 2 of this repository's session, linked by
`prompt_id`, request "продолжи где остановился". The Core already stores
every captured request of a session verbatim, with its link type. The same
audit found that the local pack's "Project" line includes the absolute
path (`/Users/<name>/…`), which reveals the user name to the reviewer.

**Proposal.**
1. `prompt-relay context|copy-context --earlier N` (N ≤ 3, default 0) and a
   Review Pack option in the app, off by default, "Include earlier requests
   of this session".
2. A section "Earlier requests in this Claude Code session" before
   "Original user request": the up to N previous turns of the **same**
   session whose request is linked by `prompt_id`, newest last, each
   complete and fenced (never truncated), labeled [Confirmed locally] with
   turn number and time. A request over 4,000 characters is left out and
   counted ("1 earlier request omitted: too long"), not cut.
3. Always an [Unavailable] line: turns before capture was turned on, turns
   summarized by `/compact`, and other sessions are not known to Prompt
   Relay. Nothing is inferred, no other session is ever used, no
   transcript or project file is read.
4. Earlier requests go through the same secret scan as the request.
5. The "Project" line shows the project name; the full path only with
   `--with-paths` (diagnostics).

**Alternatives.** (a) Detect short "continue" prompts and add context
automatically: a guess, rejected. (b) Read the Claude Code transcript:
the Core must not read transcripts (invariant 1). (c) Include earlier
responses too: makes the pack long; the reviewer can ask for them.

**Consequences.** + useful packs for follow-up prompts; + no inference.
− a Core change (export, CLI, JSON API, goldens) and a new app option.

**Status.** Proposed; waits for the owner's approval (Core change).
