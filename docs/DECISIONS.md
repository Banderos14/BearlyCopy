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


## ADR-013: Observed tool results from PostToolUse / PostToolUseFailure

**Context.** Phase 5 (`docs/PHASE5_PROPOSAL.md`) hands a Claude Code result
to ChatGPT with facts the reviewer can rely on: which tests and builds ran,
their exit codes, which files Claude changed. The Stop hook carries only
Claude's final text, and Claude's statements about tests are claims.

**Decision (direction approved; plugin change gated on stage 5.1).**
1. Add `PostToolUse` and `PostToolUseFailure` to the plugin, `async: true`,
   with a matcher limited to `Bash|Write|Edit|MultiEdit|NotebookEdit` plus,
   only if stage 5.1 confirms them, `SendUserFile`, `Artifact` and image
   `Read`s.
2. The handler keeps the invariants (exit 0, no stdout, no network, no
   commands, no file reads). For these two events it stores a reduced
   `tool_event` record, **never the raw payload**: ids (`tool_use_id`,
   `session_id`, `prompt_id`, `agent_id`, `agent_type`), time,
   `duration_ms`, outcome; for Bash `exit_code` (only from a first line
   `Exit code N`), `command` (≤ 1 KB, withheld if it looks secret), `kind`
   (test/build/git/other by configurable prefixes), `background`, and for a
   failed test/build only the last 12 lines (≤ 2 KB) after a secret scan;
   for edits the path only; for Artifact the returned title, URL, version,
   audience and source path.
3. Never stored: stdout/stderr of successful commands, file contents,
   `old_string`/`new_string`, Write/Edit `tool_response`, artifact HTML.
4. Linking: session by `session_id`, turn by `prompt_id`; without it an
   event is linked only when exactly one turn is open, else `unlinked`
   (counted, not exported). Subagent events are grouped apart.
5. Wording: an exit code describes one command. Prompt Relay never says
   "passed", "success" or "done".
6. Before any plugin change, real payloads are captured in a sandbox
   (`claude --settings`, separate data dir; plugin and
   `~/.claude/settings.json` untouched) and recorded in
   `HOOKS_RESEARCH.md`.

**Alternatives.** (a) Parse `transcript_path` at export time: undocumented
format that contains full file contents and API request blobs, lags at
Stop, conflicts with invariant 1; rejected. (b) Synchronous hooks: adds
40–90 ms to every tool call; rejected.

**Consequences.** + verifiable facts in the pack; + no transcript reading.
− more hook invocations (async); − events of a `claude -p` run can be lost
at teardown (labeled, never read as success); − a new record type in the
store and JSON API (compatible addition).

**Status.** Direction approved 2026-10-30; the plugin change waits for the
stage 5.1 results.


## ADR-014: Optional clipboard image history

**Context.** The owner takes several screenshots while dictating to ChatGPT
and wants to pick them in Prompt Relay.

**Decision.** An opt-in mode, **off by default**. While on: poll only
`NSPasteboard.changeCount` once a second (tolerance 0.5 s), paused while
the displays sleep; read only the item types first; skip items marked
`org.nspasteboard.ConcealedType`, `TransientType`, `AutoGeneratedType` and
Prompt Relay's own `com.promptrelay.origin`; keep image data (PNG, TIFF →
PNG, JPEG, HEIC) or file URLs to images only; never read text; ≤ 20 MB per
image; at most 5, deduplicated by SHA-256; kept 24 h (1 h / 7 d
selectable); per-item and Clear all deletion. While off, the pasteboard is
not polled at all.

**Alternatives.** Global event taps or accessibility hooks: need
permissions and see more than images; rejected.

**Consequences.** + screenshots without files; − macOS paste-privacy
prompts may appear (to be checked on macOS 27, V6).

**Status.** Approved 2026-10-30 as optional.


## ADR-015: Project → Session → Turn in the island

**Context.** Several Claude Code sessions can run in one folder. The Core
already keeps one file per `session_id` and `sessions`/`turns`/`show`
address a single session.

**Decision.** Keep the Core model. Add compatible fields to the session
summary: `title` (the first captured request of the session, one line, up
to 80 characters, for display only; the request itself stays verbatim),
`claude_code_title` (the `session_title` Claude Code sent, labeled),
`answered_count`, `running`, `captured_since`. The island gets a project
and session switcher; the selection is kept by `session_key`; a new answer
in another session shows a "New in …" chip and never switches the view.
Capture switches and Add Project move to Settings → Capture. `/compact`
keeps the same `session_id`, so it never creates a session; `/clear` and
forks do.

**Alternatives.** A separate "workspace" model in the app: duplicates the
Core's; rejected.

**Status.** Approved 2026-10-30 (R7, R9).


## ADR-016: Typed attachments and interactive mockups

**Context.** Results often include documents, PDFs, images, links and
interactive mockups (Claude Artifacts). The reviewer needs the material,
not a private link or a local path.

**Decision.**
1. One attachment store (ADR-011's `attachments.json`), extended with
   `kind` (document, pdf, image, link, mockup), `source`, `availability`
   (stored, missing, link_only, failed), `selected`, `order`. Existing
   records read as `image`. A stored file is a snapshot (SHA-256, time);
   later changes are shown, never applied silently.
2. Candidates only from: the user; what Claude showed explicitly
   (SendUserFile, Artifact, if stage 5.1 confirms the events); files Claude
   wrote this turn **and** named in its answer (suggested, not selected).
   Other changed files stay paths in the pack.
3. A mockup has named states with status `captured` (an image is stored),
   `named_only` or `failed`. A link is never presented as read content.
   Every mockup carries "Visual mockup — review required"; what a still
   cannot show (transitions, animation, pointer reactions) is listed.
4. Hand-off file names carry the order:
   `<project>-<artifact>-NN-<state>.png`. Files go as a second step (file
   URLs, drag, Finder) until pasting several items is verified.
5. Not done: fetching claude.ai pages (authentication), scraping Claude
   Desktop, scanning disks.
6. **Proposed, separate approval later (stage 5.10):** rendering a mockup's
   local source in an isolated, offline, non-persistent WKWebView to snap
   states the page declares (`prompt-relay-states` JSON, `#state` anchors),
   only on an explicit click.

**Status.** Items 1–5 approved 2026-10-30 (R10, R11); item 6 proposed.

## ADR-017: A request's origin is read from its structure

**Context.** UserPromptSubmit carries no author. Claude Code fires it for
turns it starts itself (a side session reporting back, a CI monitor) and
for sessions started from another session; those prompts are harness
blocks or text written by another Claude session. Copy for ChatGPT showed
such text as "Original user request" (observed 2026-10-30, HOOKS_RESEARCH §3).

**Decision.**
1. `origin.classify` reads the text: no harness block outside pasted text →
   `user` (`user_pasted` with a `<pasted_content>` block); nothing but harness
   blocks (`system-reminder`, `side-sessions-event`, `ci-monitor-event`,
   `task-notification`) → `automated`; both → `unknown`. Blocks quoted inside
   pasted text never count.
2. Stored events are never changed. Exports keep the verbatim text:
   an automated turn shows the latest earlier user request of the same
   session (labelled with its turn) and the automated message under its own
   heading; `unknown` is exported as "Request (source not established)".
3. Titles and previews drop harness blocks (display only); a session whose
   first request is not the user's takes Claude Code's `session_title` when
   there is one.
4. If Claude Code adds a field naming the prompt's source, it replaces the
   heuristic.

**Consequences.** A user who types a harness tag literally (outside a paste)
gets `unknown`, never a false "automated"; nothing is hidden, only labelled.

## ADR-018: Window snapshots are held in memory only

**Context.** Phase 9.4 stored Capture Final Window and auto-capture images as
attachments in the app data dir and copied them into `app/handoff/` for
every drag or Copy Files. Screenshots of a working window can show anything
on screen; the owner asked for no folder that fills with them (Phase 10).

**Decision.**
1. A window snapshot is a `ReportAttachment` with `inMemory = true`; its
   bytes live in `ReportStore`'s process memory, bounded (12 images, 96 MB,
   4 h; oldest first) and capped at 3200 px on the longest side.
2. It is never written to `attachments.json`, `attachments/` or `handoff/`.
   Copy and drag put image data on the pasteboard without a file URL. Only an
   explicit Export writes it, into the folder the user chose.
3. It does not survive quitting the app; a saved hand-off that used one is
   dropped at launch rather than restored without it.
4. Files the agent wrote (result attachments) are unchanged: they remain
   persistent snapshots of project files.

**Consequences.** Receivers that accept only file URLs get nothing from a
snapshot (use Export). The pasteboard, Universal Clipboard and the receiving
app may keep their own copies; Prompt Relay does not claim otherwise.

## ADR-019: Python for the first GitHub beta — a checked system dependency

**Context.** The Core is Python 3.9+ (standard library only, ADR-001). On a
clean Mac `/usr/bin/python3` is a stub that opens the Command Line Tools
installer. Phase 11 had to decide how a downloaded app gets a Python.

**Options considered.**
1. *Bundle a relocatable CPython* (e.g. a python-build-standalone build):
   ≈ 45–60 MB unpacked per architecture (≈ 90–120 MB universal) against a
   9.4 MB app today; every Mach-O inside must be Developer ID-signed with the
   Hardened Runtime and notarized; Prompt Relay would have to ship CPython
   security fixes itself. And it would serve only the app: the hook — the
   critical path — runs inside Claude Code/Codex from the plugin launcher,
   which cannot rely on an app's location without coupling the two.
2. *A standalone Core executable* (PyInstaller/Nuitka/zipapp): a new build
   dependency, a one-file binary that unpacks native code at run time (hard
   to sign and notarize cleanly), and the same "hook still needs Python"
   problem.
3. *A checked system dependency*: any Python ≥ 3.9 (Command Line Tools,
   Homebrew, python.org). The app never runs `/usr/bin/python3` unless the
   Command Line Tools are installed (`CoreLocator`, `run-hook`), so it never
   triggers the installer prompt by itself; it says what is missing and
   offers the install command.

**Decision.** Option 3 for the first beta. The app and the launcher keep
the existing search order (pin → Homebrew → /usr/local → python.org → CLT
only when installed). Setup and Settings → Diagnostics show "Python 3.9 or
newer: Not found" with the exact fix. Rewriting the Core in Swift is not
justified: the Core's guarantees (verbatim, fail-closed, stdlib-only,
cross-platform tests) would have to be re-earned, and the hook would still
be a separate process.

**Consequences.** App size stays ≈ 10 MB. Users without any Python need one
extra install step, stated in README and Setup. Revisit if beta feedback
shows this is the main drop-off; then option 1 for the hook too, via a
stable launcher location (separate ADR).

## ADR-020: Distribution — GitHub Releases, Developer ID, local install script

**Context.** The owner chose GitHub Releases and open source; the Mac App
Store is out of scope (Phase 10 §F: sandbox conflicts). The owner's daily
use also suffered from Xcode running a fresh Debug build while
`~/Applications/Prompt Relay.app` stayed old.

**Decision.**
1. *Developer workflow*: `scripts/install-local.sh` builds a Release
   bundle, verifies it (signature, app version = bundled Core version, Core
   digest = checkout, commit = HEAD), shows a plan, asks, asks the running
   Release copy to quit normally, keeps the old app in
   `~/Library/Application Support/PromptRelay-AppBackups/`, installs, opens
   and checks that exactly one Release copy runs. `--dry-run`, `--status`,
   `--rollback`. It touches nothing else (history, preferences, Claude/Codex
   configuration). Xcode remains the development tool.
2. *Release workflow*: `scripts/release-build.sh` builds a universal
   binary, signs inside-out with a Developer ID Application identity,
   Hardened Runtime with no exceptions (`macos/Release/PromptRelay.entitlements`),
   secure timestamp, then a zip (`ditto -c -k --keepParent`) and a DMG.
   `scripts/release-notarize.sh --submit` runs `notarytool submit --wait`,
   `stapler staple`/`validate` and `spctl`. Both refuse to label an unsigned
   or ad-hoc build as a release.
3. Every build records `PRGitCommit`, `PRGitDirty`, `PRBuildDate` (and the
   script builds `PRCoreDigest`); Settings → About shows them and explains
   mismatches it can read from the bundles themselves.
4. No auto-update in the beta (no Sparkle, no background checks): release
   notes and manual download. Nothing is hidden.

**Consequences.** A release needs the owner's Developer ID certificate and
notary credentials (not on this Mac as of Phase 11). The plugin is still
installed by the user through `claude plugin` (ADR-008).

## ADR-021: First-run setup reports delivery, not configuration

**Context.** Phase 10 found that new users cannot tell how to connect Claude
Code or Codex, and that "configured" was easy to mistake for "working".

**Decision.**
1. Setup is one page in the island: Agents (Claude Code, Codex · Terminal,
   Codex · Xcode) → Enable a project → Verify capture → First result. It can
   be skipped and reopened (empty Home, Settings → Agents & Projects).
2. Status per agent and host: Not detected · Installed · Configuration
   required · Trust required · Capture disabled · Waiting for first event ·
   Connected — events observed · Error. **Connected requires a stored event
   from that agent and host** (a readable session, or the handler log's
   stored outcome attributed to that host). A plugin record or hook
   definition is configuration only; a Codex CLI delivery never marks Xcode
   connected.
3. Detection is existence checks of well-known paths (`~/.claude`, the
   `claude`/`codex` commands, `~/.codex`, Xcode's CodingAssistant folder);
   credentials, tokens and transcripts are never read. Codex `hooks.json` is
   parsed only to count Prompt Relay's own commands, as before.
4. Prompt Relay does not run `claude plugin` or edit `hooks.json` itself.
   Setup shows the exact commands, what they change and how to undo them,
   and copies them; the user runs them (ADR-008, invariant 9). The Codex
   helper keeps other hooks and writes a backup.

**Consequences.** One more paste for the user, in exchange for no silent
configuration changes and no dependency on finding the right `claude`
binary from a GUI app. Codex setup still needs a source checkout (the hook
command points at its launcher) — a beta blocker recorded in Phase 11.

## ADR-022: MCP — a read-only interface later, never a replacement for hooks

**Context.** The owner asked whether MCP could simplify passing context
between agents. Full analysis: `docs/MCP_EVALUATION.md`.

**Decision.** Not in Phase 11. MCP cannot replace passive capture: an MCP
server is called by an agent when the model decides to; it never sees the
final answer of a turn unless the agent sends it, which is neither verbatim
by construction nor guaranteed. Hooks stay the capture path. A future
*read-only* MCP server over the existing Core JSON API is feasible
(`get_latest_result`, `list_projects`, `list_conversations`,
`get_context_pack`, `get_attachment_metadata`), off by default, per-project
allowlist, no write tools, no file contents beyond the Context Pack the user
could copy.

**Consequences.** No new process or protocol surface in the beta.

## ADR-023: Local agent profiles from config folders; one history, several views

**Context.** Phase 12: several Claude Code and Codex set-ups run side by
side on one Mac (Claude Personal, Claude Work, Codex in Xcode and in
Terminal). Results must never mix, and the user must see which agent,
profile, host, project and conversation produced each one.

**Decision.**
1. A *profile* is the agent's configuration folder: `CLAUDE_CONFIG_DIR`
   (default `~/.claude`) or `CODEX_HOME` (default `~/.codex`), read from
   the hook's own environment (`profiles.py`). Its id is `cc-default` /
   `cx-default` or a prefix plus 16 hex digits of SHA-256 over the real
   path; only a `~/…` hint is kept. It is **not an account**: no
   credentials, tokens, `auth.json`, keychain items or e-mails are read, and
   two accounts used in one folder are indistinguishable (documented in the
   UI). Names ("Work") are local app labels.
2. The profile goes into the record envelope (`agent_profile`); the payload
   stays verbatim (invariant 2). A non-default Claude Code folder scopes the
   stored session key (`<id>.<12 hex>`), so equal native ids never share a
   file (invariant 3); the default folder keeps plain keys, so no existing
   history changes. Codex keys already include `CODEX_HOME`.
3. Records without a profile are read as they are: Claude Code →
   Unassigned (never guessed); Codex → the profile its `installation_id`
   maps to. No migration rewrites any file.
4. By Project, By Agent, the Results Inbox and the Quick Switcher are views
   of the same Core data; the Inbox reads one new read-only command,
   `results`, loaded only while it (or the switcher) is on screen.
5. Read state stays per result (`answers.seenReports`); the notch keeps its
   single green dot.

**Consequences.** A Claude Code session that is in progress while the
plugin is updated *and* runs with a non-default `CLAUDE_CONFIG_DIR` continues
under a new key (its earlier turns stay in the old conversation). Whether
Claude Code passes `CLAUDE_CONFIG_DIR` to hooks is expected from its
documented environment inheritance but **not yet observed live**
(HOOKS_RESEARCH). If Claude Desktop runs its bundled Claude Code with its own
folder, those sessions form their own profile, which is correct.

## ADR-024: Open at Login through SMAppService, installed Release copy only

**Context.** Phase 12 asks for optional start at login, no second instance,
no Xcode dependency.

**Decision.** `SMAppService.mainApp` (system login items), off by default,
only for the Release bundle at `~/Applications` or `/Applications`; Debug
builds and copies elsewhere show why the switch is unavailable. Turning it
off unregisters the same item. A "requires approval" status is shown with a
button to System Settings → Login Items. No helper app, no LaunchAgent plist.

**Consequences.** Registration was **not exercised live** in Phase 12 (it
changes the user's login items; needs the owner's consent on the installed
app). Ad-hoc signed builds may need approval in System Settings.

## ADR-025: Needs Input from observed hook signals only

**Context.** Phase 12.1: while Claude Code asks a question, waits for plan
approval or a permission, the notch showed Working.

**Decision.** The plugin observes `PreToolUse` (AskUserQuestion,
ExitPlanMode), `PermissionRequest`, waiting `Notification` types and
`SessionEnd`; Codex `PermissionRequest` in the Core. Handlers stay silent
(exit 0, empty stdout = no decision); only reduced records without any text
are stored. A wait ends with the next confirmed activity, never a timer.
`PostToolUse` matches every tool so an approved tool ends the wait; tools
outside the evidence set write only while a wait is open (marker file under
`<data>/waiting/`). The state is `attention` on the session; it never
touches turns, answers, results or Copy with Context. No auto-answer, no
permission changes, no app switching.

**Consequences.** Two synchronous hooks add ~40–60 ms before a question or
permission dialog appears. More hook processes run (async) per tool call;
they store nothing unless a wait is open. Hosts without these events keep
their last confirmed state. A wait abandoned without any further event stays
shown until the session continues or ends.

## ADR-026: Context Packs — one document, one section per result

**Context.** Phase 13: the user hands the work of several agents (Claude
designs, Codex implements, Claude reviews) to another AI at once. Copy with
Context carries one result.

**Decision.**
1. A Context Pack is one Markdown document (`docs/CONTEXT_PACK.md`), format
   `prompt-relay-context-pack` v1, versioned apart from the app, the Core and
   JSON API v1. A manifest describes it without paths, session ids or text.
2. Each result keeps its own section, built by the Copy with Context
   functions one heading level deeper; nothing is merged, summarised or
   rewritten; a result appears once (identity `session_key#turn`, which
   already separates profiles, ADR-023). Results from different projects
   are allowed and flagged.
3. The Core renders local results (`context-pack`, read-only, ≤ 20,
   `external` slots for imports); the app adds attachments, imports, profile
   names and the user's instructions with the same frame. The user's
   instructions are labelled as theirs; the default request as Prompt
   Relay's.
4. Hand-off stays two explicit steps (text, then files/images or Drag) plus
   Export. Window snapshots stay in memory (ADR-018): image data only,
   files only through Export. Missing attachments are listed, never offered.
5. Receivers (ChatGPT, Claude, Gemini, Codex, any chat) change guidance only;
   no capability beyond plain-text paste is claimed without a real check.
6. A local Handoff History records what the user did (Prepared, Text copied,
   Files copied, Drag started, Exported), never delivery, and stores no text.

**Consequences.** New Core command and schema entry (`context_pack_data`)
in API v1 (additive). Two composers of the frame (Python, Swift) are kept
equal by a cross-test. A restart keeps the draft, not the prepared text.

## ADR-027: MCP stays a design for Phase 14 (updates ADR-022)

**Context.** Phase 13 asked whether a minimal read-only MCP server could ship
now. The current specification (checked 2026-11-06) has a new revision,
`2026-07-28` ("modern", no `initialize` handshake, version and capabilities
in `_meta`), next to the legacy `2025-11-25` handshake; stdio servers must
write only MCP messages to stdout, validate every input and check access on
every call.

**Decision.** No MCP server in Phase 13. The data side exists — `context-pack`
is exactly what `get_context_pack` would return — but shipping a server now
would mean (a) choosing between two handshakes without knowing which one the
owner's Claude Code and Codex versions speak, and (b) testing it only against
our own fakes, because connecting a real client means editing the user's
Claude/Codex configuration, which needs their consent. ADR-022's rules stand
(off by default, separate per-project allowlist, read-only, no file
contents, audit line without payload, stdio only, no automatic install).
Phase 14 starts with a live probe of which revision each client sends.

**Consequences.** No new process or trust surface in 0.4.x/0.5.0. The design
in `docs/MCP_EVALUATION.md` §"Phase 13 update" is the starting point.
