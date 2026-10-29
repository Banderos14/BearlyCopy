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

No real Claude request was made to study hooks. Payload shapes come from the
documentation; fixtures in `tests/fixtures/` copy the documented examples.

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
| D1 | Whether `prompt_id` is actually present in Stop/StopFailure payloads in the Desktop-bundled version | docs say "common field"; unverified. The code falls back to order-based linking |
| D2 | Whether `last_assistant_message` contains only the last text block or all text of the final turn when tool calls are interleaved | docs: "text content of Claude's final response". Verify with a multi-tool turn on the Mac |
| D3 | Behavior of Stop after background tasks wake the session (same `prompt_id`?) | modeled as "same prompt_id → same turn". Verify locally |
| D4 | Desktop Code tab Claude Code version and hook support parity | unverified; requires macOS |
| D5 | Whether pbcopy preserves NUL characters | Prompt Relay stores NUL losslessly. The clipboard result needs a macOS check |
| D6 | `agent_id` is a common field ("subagent or in-process teammate the hook fires in"). Can a Stop/UserPromptSubmit with `agent_id` reach the main session's hooks? | The docs say Stop is for the main agent, and SubagentStop is not connected. `agent_id` is stored but not used for correlation. Verify with a subagent/teammate turn on the Mac (LOCAL_MAC_VALIDATION M3 prompt 5) |
| D7 | A prompt blocked by *another* UserPromptSubmit hook (hooks run in parallel) is still stored by Prompt Relay but gets no Stop. Without `prompt_id`, the next answer becomes `ambiguous` | By design (the handler cannot see other hooks' decisions); documented |
| D8 | Interrupted turns (Esc) produce no Stop. Without `prompt_id`, the next answer becomes `ambiguous` instead of being guessed | By design; `prompt_id` avoids it |
