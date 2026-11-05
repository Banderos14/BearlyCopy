# Claude Code Hooks — research notes (Phase 0)

Source of truth: the official hooks reference, <https://code.claude.com/docs/en/hooks>,
read on 2026-10-29. Where this document says "documented", it means that page.
Where it says "observed", it names the exact check that was run.

## 1. Environment where the research was done

| Item | Value | How it was determined |
|---|---|---|
| OS | Ubuntu 24.04.5 LTS, x86_64 (Claude Code cloud container) | `uname -a`, `/etc/os-release` |
| Claude Code | 2.1.312 | `claude --version` |
| Python | 3.13.17 (system), 3.9.25 (installed via `uv` for compatibility tests) | `python3 --version` |
| Node.js | 22.22.0 | `node --version` |
| Swift / Xcode | **not available**; `download.swift.org` is blocked by the cloud egress policy (HTTP 403) | `command -v swift`, `curl -I` |
| macOS tools (`pbcopy`, AppKit) | not available (Linux) | `command -v pbcopy` |

Phase 0 made no real Claude request. Phase 1.5 (2026-10-29, macOS) captured
real payloads from Claude Desktop and the CLI; they are in
`tests/fixtures/real_*.json` and the findings are in §7 (D1, D4, D5, D9).

**Observed in the installed binary.** `grep -a` on `/opt/claude-code/bin/claude`
(v2.1.312) finds the strings `last_assistant_message`, `background_tasks`,
`session_crons`, `StopFailure`, `prompt_id`, `stop_hook_active` and
`error_details`. This shows that the installed version knows these field
names. It does **not** prove the exact payload layout. A real payload capture
is part of `LOCAL_MAC_VALIDATION.md`.

## 2. Common input fields (all events)

| Field | Use in Prompt Relay | Notes |
|---|---|---|
| `session_id` | session key; never merged across ids | treated as optional; when it is missing, events go to the `_no-session` bucket |
| `prompt_id` | **primary request↔response link** | UUID of the user prompt being processed. "Absent until the first user input". Present on Stop as a common field |
| `transcript_path` | stored only, never read | the docs warn the transcript can lag at Stop time |
| `cwd` | project identity fallback | follows Claude into worktrees and into `cd` |
| `permission_mode` | stored only | "Not all events receive this field" |
| `hook_event_name` | dispatch | |
| `agent_id`, `agent_type` | stored | present inside subagents/teammates |
| `effort`, `scratchpad_dir` | stored only | newer versions |

Environment: `CLAUDE_PROJECT_DIR` is the project root where the session
started, and it stays at that root inside worktrees. Prompt Relay prefers it
over `cwd` as the project identity. `CLAUDE_CODE_REMOTE="true"` marks cloud
sessions. Prompt Relay records it, so cloud-originated events stay
distinguishable.

## 3. Events

### UserPromptSubmit — used
Input: common fields + `prompt` (and `session_title` when set).
Output semantics that matter for safety:
- **Plain stdout on exit 0 is added to Claude's context.** The handler therefore
  never writes to stdout.
- `decision: "block"` would stop the prompt. Prompt Relay never emits a decision.
- The default timeout is lowered to 30 s for this event.

Observed 2026-10-30 (Claude Desktop, CLI 2.1.309), stage 5.11:
- The payload has **no field that says who wrote the prompt**. Claude Code
  also fires the event for turns it starts itself: when a side session
  finishes, the parent's next turn begins with a prompt made only of
  `<system-reminder>` and `<side-sessions-event>` blocks, with a new
  `prompt_id`. Phase 5's whole implementation ran in such a turn, so its pack
  showed that text as the user's request. Prompt Relay now classifies the
  origin from the text's structure (ADR-017).
- A session started from another one (`start_session`) receives as its first
  prompt a `<system-reminder>` listing linked sessions, then
  "Background (from the session that started this one): …" and the brief.
  Its origin is `unknown`: neither the user nor provably automated.
- `session_title` is absent on a session's first prompt; it appears on later
  prompts once Claude Code has named the session.
- With a marketplace of type `directory` (this repository), Claude Desktop
  ran the hooks of the working tree's `plugin/` (0.3.0: `PostToolUse
  via=plugin` was stored) while `claude plugin list` still showed the
  installed 0.2.0 and its cache had no tool hooks. A branch switch in this
  checkout therefore changes the hooks that run. `claude plugin update`
  then recorded 0.3.0 (`~/.claude/settings.json` unchanged).

### Stop — used (main source of the final text)
Input: common fields + `stop_hook_active`, `last_assistant_message`,
`background_tasks`, `session_crons`.
- `last_assistant_message` is "the text content of Claude's final response".
  The docs recommend it over reading the transcript.
- Stop "does not run if the stoppage occurred due to a user interrupt". So an
  interrupted turn has a prompt with no response. Prompt Relay shows it as
  `awaiting_response` / `no_matched_response`.
- "API errors fire StopFailure instead."
- `stop_hook_active: true` means Claude is continuing because a stop hook
  blocked. **Several Stops can belong to one prompt.**
- `background_tasks` non-empty means the session is paused while work is
  still in flight, and it may wake and Stop again. Prompt Relay marks this
  `stop_received_background_tasks_pending` and never "done".
- Exit 2, or JSON `decision: "block"`, would force Claude to continue. The
  handler always exits 0 with empty stdout.

### StopFailure — used (to avoid mislabeling errors)
Input: common fields + `error` (`rate_limit`, `overloaded`,
`authentication_failed`, `oauth_org_not_allowed`, `account_on_hold`,
`billing_error`, `invalid_request`, `model_not_found`, `server_error`,
`max_output_tokens`, `cloud_credential_error`, `unknown`), optional
`error_details` and optional `last_assistant_message`, which **holds the API
error string, not Claude's answer**. Output and exit code are ignored.
Prompt Relay stores it as `api_error` and never offers its text as a response.

### PostToolUse / PostToolUseFailure — observed 2026-10-30 (stage 5.1)
Captured in a sandbox: a Claude Desktop Code-tab session in a throwaway
folder whose `.claude/settings.local.json` registered capture-only hooks
(stdin copied to a file; no stdout; `async: true` for the tool events). The
plugin and `~/.claude/settings.json` were not touched. Redacted fixture:
`tests/fixtures/turns/real_desktop_tool_turn.json` (22 events). The CLI could not
be used: it is logged out on this Mac.

| Question | Observed |
|---|---|
| Ids (V2) | every tool event had `session_id`, `prompt_id`, `tool_use_id`, `duration_ms`, `transcript_path`; subagent tool events also `agent_id`, `agent_type`. **All tool events of the turn, including the subagent's, carried the turn's `prompt_id`** |
| Bash success | `tool_response` = `stdout`, `stderr`, `interrupted`, `isImage`, `noOutputExpected`; no exit code |
| Bash failure (V5) | `PostToolUseFailure`, `error` first line `Exit code 3`, `is_interrupt: false`, no `tool_response` |
| Pipe | `python3 -c "…exit(2)" \| cat` → **PostToolUse** (success): the pipe's last process decides |
| Parallel (V5a) | three parallel Bash calls → three events within 10 ms, same `prompt_id`, none lost |
| Background (V5c) | `run_in_background: true` → PostToolUse at start with `tool_response.backgroundTaskId`; no event when it finished |
| Background / subagent completion | delivered to Claude as **UserPromptSubmit events with the same `prompt_id`** and prompt text starting `<task-notification>` or `<agent-message from=…>`; the second carried `session_title`. Before the stage 5.1 fix the Core made each of them a new, never-answered turn |
| Write / Edit | `tool_input` has `content` or `old_string`/`new_string`; `tool_response` has `originalFile` and `structuredPatch` (full file content) — never stored |
| `if: "Read(*.png)"` (V3) | works: the extra handler ran for `red.png` only |
| SendUserFile (V4) | PostToolUse fires; `tool_input.files` (absolute paths), `tool_response.attachments[]` with `path`, `size`, `media_type`, `isImage`, `pathValidated` |
| Artifact (V9) | PostToolUse fires; `tool_input.file_path` (+ private `__artifact…` keys); `tool_response` has `title`, `url`, `version`, `audience` (`owner`), `path`, `artifact_id`, `owned` |
| Agent | `tool_response.isAsync: true`, `agentId`, `outputFile`; the hand-back is a separate tool `SubagentHandback` inside the subagent |
| After Stop (V5b) | no tool event arrived after Stop in this run |
| Not observed | V1 latency at scale and V5d (`-p` teardown): need a logged-in CLI |

### SessionStart — researched, not connected
`source`: `startup | resume | clear | compact | fork`; optional `model`,
`session_title`. Possible future use: show "session started/resumed" in the
UI, and record `model`. Plain stdout is added to context, so it is risky for
a capture tool. It is not needed for capture.

### SessionEnd — researched, not connected
`reason`: `clear | resume | logout | prompt_input_exit | other`. The default
budget is 1.5 s. Possible future use: mark a session closed in the UI.

### Notification — researched, not connected
`message`, optional `title`, `notification_type` (`permission_prompt`,
`idle_prompt`, `agent_completed`, …). Possible future use: a notch status
such as "Claude needs permission". It cannot block anything.

### SubagentStop — researched, deliberately not connected
It carries the subagent's own `last_assistant_message`. That is not the
answer the user sees, and storing it would mix internal agent output into
"final responses".

### CwdChanged — noted
`old_cwd`/`new_cwd`. It is not needed, because every event carries `cwd`
and the project identity comes from `CLAUDE_PROJECT_DIR`.

## 4. Handler contract derived from the docs

| Rule | Reason (documented behavior) |
|---|---|
| Exit 0 always | exit 2 blocks or forces continuation; other codes are "non-blocking errors" that show error notices |
| Never write stdout | UserPromptSubmit/SessionStart stdout becomes Claude context; JSON on stdout is parsed as a decision |
| stderr only for content-free error codes | with exit 0, stderr is not shown to Claude |
| Finish far below the timeout | the default command timeout is 600 s (30 s for UserPromptSubmit). We configure `timeout: 10`. The lock wait is capped at 3 s and the measured median is about 60 ms |
| Use exec form (`command` + `args`) | "when present, exec form with no shell", so there is no shell parsing of the path |
| Synchronous, not `async` | async hooks are killed at `claude -p` teardown, and their output is delivered to Claude on the next turn |

## 5. Configuration and installation options

Settings locations (documented): `~/.claude/settings.json` (user),
`.claude/settings.json` (project, shared), `.claude/settings.local.json`
(project, personal), managed policy, plugin `hooks/hooks.json`, and skill or
subagent frontmatter. Hooks **merge** across levels. Identical handlers
defined in several files run once.

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| User-level `~/.claude/settings.json` | one place, all projects | must edit a file shared with other tools; a global side effect | possible later, only with explicit consent, backup and a merge-not-replace installer |
| Project `.claude/settings.json` | scoped | committed to the user's repos, so it leaks a personal tool into teams | rejected |
| Project `.claude/settings.local.json` | scoped, personal, gitignored by Claude Code | per project | **used for the local Desktop E2E sandbox** |
| `claude --settings <file>` | session-only, touches no settings file | CLI only; Desktop cannot pass flags | **used for the isolated CLI check** |
| Claude Code plugin (`hooks/hooks.json`, `${CLAUDE_PLUGIN_ROOT}`) | install and uninstall are handled by Claude Code; nothing is merged by us; reversible; works in Desktop | needs a plugin manifest, marketplace distribution and a trust prompt | **recommended for the public version** (ADR-002) |

`prompt-relay hook-config` prints a ready `--settings` JSON and writes
nothing.

## 6. Local vs cloud vs Desktop

- Documented: "Claude Code fires the same hook events wherever it runs:
  terminal, IDE extensions, the Desktop app, and cloud sessions."
- Documented: cloud sessions don't read the local `~/.claude/settings.json`.
  A user-level hook on the Mac therefore never sees cloud sessions. That is
  correct for Prompt Relay, which only captures local work.
- Desktop: "The desktop app reads the same settings files as the CLI." Which
  Claude Code version the Desktop Code tab bundles is **not verified**. Check
  it locally (LOCAL_MAC_VALIDATION §2).
- Interactive sessions hold back **all** hooks until the workspace trust
  dialog is accepted. In `-p` mode a folder is treated as trusted.

## 7. Discrepancies and open questions

| # | Topic | Status |
|---|---|---|
| D1 | Whether `prompt_id` is actually present in Stop/StopFailure payloads in the Desktop-bundled version | **Observed 2026-10-29**: present on UserPromptSubmit and Stop in Desktop 4.29.0 / Claude Code 2.1.309, with equal values (`real_desktop_*_1.json`); present on UserPromptSubmit in CLI 2.1.268. StopFailure not observed yet. The order-based fallback stays |
| D2 | Whether `last_assistant_message` contains only the last text block or all text of the final turn when tool calls are interleaved | docs: "text content of Claude's final response". Verify with a multi-tool turn on the Mac |
| D3 | Behavior of Stop after background tasks wake the session (same `prompt_id`?) | **Observed 2026-11-05, CLI 2.1.268 (Desktop):** a new turn — UserPromptSubmit with a `<task-notification>` block and a new `prompt_id`, then its own Stop. Background tasks seen: `shell` and `monitor`, status `running`. Phase 9.4 marks the earlier Stop `intermediate` |
| D4 | Desktop Code tab Claude Code version and hook support parity | **Observed**: Desktop 4.29.0 bundles Claude Code 2.1.309 and runs hooks from a project's `.claude/settings.local.json`; user-level hooks of other tools run alongside. Desktop does not pass the shell environment to hooks (hence `hook-config --data-dir`) |
| D5 | Whether pbcopy preserves NUL characters | **Observed**: preserved. pbcopy → pbpaste and NSPasteboard return NUL, CRLF, C0 controls and 1.18 MB byte-identical (macOS 27.0.1). How a target app treats NUL on paste is not checked |
| D6 | `agent_id` is a common field ("subagent or in-process teammate the hook fires in"). Can a Stop/UserPromptSubmit with `agent_id` reach the main session's hooks? | The docs say Stop is for the main agent, and SubagentStop is not connected. `agent_id` is stored but not used for correlation. Verify with a subagent/teammate turn on the Mac (LOCAL_MAC_VALIDATION M3 prompt 5) |
| D7 | A prompt blocked by *another* UserPromptSubmit hook (hooks run in parallel) is still stored by Prompt Relay but gets no Stop. Without `prompt_id`, the next answer becomes `ambiguous` | By design (the handler cannot see other hooks' decisions); documented |
| D8 | Interrupted turns (Esc) produce no Stop. Without `prompt_id`, the next answer becomes `ambiguous` instead of being guessed | By design; `prompt_id` avoids it |
| D9 | Does an authentication failure fire StopFailure? | **Observed** in CLI 2.1.268 (`-p`, expired OAuth): UserPromptSubmit fired, **no** Stop and **no** StopFailure. The turn stays `awaiting_response`, which is correct (no answer is invented) |

### Observed 2026-11-05: `CLAUDE_CODE_ENTRYPOINT`
Not in the hooks documentation. Claude Code sets it in the environment of the
processes it starts; in Claude Desktop's Code tab it was `claude-desktop`
(seen in a tool process; hooks are started the same way). The Claude adapter
reads only the values `claude-desktop`, `cli` and `claude-vscode` as a host;
anything else is not treated as host evidence. If a hook ever lacks the
variable, the host stays Unknown.

### Phase 12 (2026-11-05): config folders as profiles — expected, not observed
`CLAUDE_CONFIG_DIR` (Claude Code's documented settings-folder variable) and
`CODEX_HOME` (Codex) are read from the hook's environment. Hooks are child
processes of the agent and inherit its environment; with neither set, the
documented defaults `~/.claude` / `~/.codex` apply. **Not yet observed on a
live hook run with a non-default `CLAUDE_CONFIG_DIR`** — record the outcome
here after the owner's check (Phase 12 report, live checks). Claude Desktop
does not pass the *shell* environment to hooks (D4); whether it sets its own
`CLAUDE_CONFIG_DIR` is unknown. Nothing in a payload or a credential file is
used to identify a profile.
