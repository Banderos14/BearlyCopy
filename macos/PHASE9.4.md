# Phase 9.4 — reliable completion, attachments without Add

2026-11-05. Starting HEAD `9e2461b`. Backup: `refs/backup/phase9.4-start` and
`~/Projects/prompt-relay-backups/phase9.4-start-20261105-150720/` (patches,
status, untracked tarball). The staged `xcode-smoke/REPORT.md` and the
acceptance files were left as they were.

The task text received for this phase ended in the middle of section 2
("…и допустим"). Sections 0–2 are implemented; later sections were not
received and are not implemented.

## 1. An intermediate Stop is not the result

**Observed contract (Claude Code 2.1.268, this Mac, read-only, no text read).**
Stop carries `last_assistant_message`, `stop_hook_active`, `background_tasks`
(`{id, type, status, description, command?}`; seen types `shell` and
`monitor`, status `running`) and `session_crons` (never non-empty here).
When background work ends, Claude Code does **not** send another Stop for the
same prompt: it starts a new turn whose UserPromptSubmit is a
`<task-notification>` block with a new `prompt_id`, and the follow-up Stop
belongs to that turn. This session itself showed two such intermediate Stops
before its final one. Recorded in `docs/HOOKS_RESEARCH.md` terms: D3 resolved
as "new prompt_id, automated turn", not "same prompt_id".

**Model (Core `completion`, per turn and on `last_turn`; this session only):**

| completion | meaning | Latest / green dot |
|---|---|---|
| `answer` | Stop with text, no work in flight | yes |
| `answer_background_running` | work was running, then the user sent a new request | yes, flagged |
| `waiting_background` | last turn; Stop reported `shell`/agent work running | no — "Waiting for background work" |
| `intermediate` | work was running and the session continued automatically (`continued_in_turn`) | no — kept in History |
| `working` / `no_text` / `api_error` / `unknown` | as named | no |

`monitor` tasks (watchers) and `session_crons` (schedules) never hold an
answer. A Core without `completion` is read conservatively (a background Stop
counts as waiting). With no continuation for 2 hours the waiting state ends:
the text is reachable as "Completion unknown", never announced or shown green.
Nothing blocks or delays Claude Code; the hook is unchanged.

App: the right ear shows waiting dots in the warning tone; Details says
"Waiting for background work" or "Intermediate · continued in turn N"; the
session row says "waiting · background"; Copy with Context states the
completion in its Source section. The follow-up answer (an automated turn) is a
normal ready answer, not the "started by Claude Code" ring.

## 2. Automatic attachments with no Add and no Details

Gap found: the final answer after background work comes in the follow-up
turn, which usually has no tool events; the files were written in the user's
turn. They were missed, and named files failed the "changed during this turn"
check because the window started at the follow-up. Now `show` includes
`work_chain` (the intermediate turns this one continues, their observed files
and the request time that started the task). Preparation uses those files as
observed output and the chain's start as the turn window. Intermediate turns
prepare nothing themselves (no duplicates); their files arrive with the final
answer. The existing path then applies unchanged: answer loads (or Copy with
Context runs) → safe snapshot → selected → pack lists them → file hand-off ready.

Still offered, not auto-selected (by design): files only mentioned and not
changed during the task, files outside the project, HTML/SVG/JSON, hidden or
credential-like paths, symlinks, secrets in text.

## Tests added

- Python `tests/test_phase94.py`: the real sequence (request → Stop with
  shell tasks → task-notification turn → Stop with tasks → follow-up → final),
  redelivery, watchers/crons, user moving on, StopFailure after a background
  Stop, Stop without the field, work chain files.
- Swift `Phase94CompletionTests`: waiting → intermediate → final with exactly
  one announcement, repeated refresh, restart, expiry without continuation,
  older Core. `Phase94AttachmentTests`: chain files auto-selected (and missed
  without the chain), intermediate prepares nothing, Quick Peek Copy with
  Context → pack + 2-file hand-off without Details.
- Updated: Phase 8.1 unread test fixture now states `answer_background_running`.

Not verified live: a new real Claude Code background-test run against the new
build (the installed app is still older; installation needs the owner's OK).

# Phase 9.4, continuation — final-only UI, status dots, Details, host, conversations

Starting HEAD `19231c6`; backup `refs/backup/phase9.4b-start` and
`~/Projects/prompt-relay-backups/phase9.4b-start-20261105-153858/`. Sections
0–2 above were kept; only the places below changed.

**Installed build (checked, nothing replaced).** One copy runs: the Xcode
Debug build from DerivedData (built and started 15:29). Its bundled Core
already had part 1 of Phase 9.4, so the owner's "4/5 · waiting for the final
run" was part-1 behaviour (intermediate Stops were still in the carousel),
not an old binary. `~/Applications/Prompt Relay.app` is the Nov 4 build.
Claude Code itself runs the plugin from `~/.claude/plugins/cache/prompt-relay/
prompt-relay/0.3.0` (updated Oct 30), which has no source adapters: that is
why Claude sessions show no host. Updating it is the owner's step
(`claude plugin update`), not done here.

**Final-only UI.** `AppModel.isVisibleAnswer` is the single rule: a final
answer (`answer`, `answer_background_running`), an API error, or a background
wait that expired with no continuation. The Answer carousel and its `n/m`
counter, the default selection, History, search, the conversation list and
plain Copy Answer use it; Copy Answer explains why an intermediate message is
not offered. The Core's `answered_count` now counts final answers only. The
answer of a turn resumed after background work shows the user's earlier
request as its Task ("from turn N · after background work"), and the pack
says "This answer finishes that request" instead of repeating the
`<task-notification>` as a request. All turns stay stored for correlation.

**Status dots.** `LoadingDots`: three 3.5-pt dots, each grows to 1.45× and
brightens in turn (1.2 s period, ease in/out), as Core Animation keyframes —
no per-frame app work; removed with the view, so the animation stops when
work ends. Working = white, waiting for background work = the waiting tone;
Reduce Motion = still dots. Ready = a 6-pt dot in the theme's success green;
viewed = nothing; capture error = the `!` ring. SwiftUI fades between them.

**Details is remembered.** `NotchPresentation.preferredSurface`: opening
Details sets it; hover then reopens on Details (same report, route Home) after
the automatic close. "Quick Peek" (top band of Details, left) returns to Quick
Peek and resets it. Settings/History/Clipboard do not change it. With Details
preferred, closing never moves the selection to Latest and keeps a manual pick.

**Host.** Claude Code sets `CLAUDE_CODE_ENTRYPOINT` for its child processes;
observed `claude-desktop` in Claude Desktop's Code tab (2026-11-05). The
Claude adapter maps only `claude-desktop`, `cli`, `claude-vscode`; a configured
`PROMPT_RELAY_HOST` wins; anything else records no host. Old events keep no
host; compact headers then show "Claude Code · This Mac" (full label in the
tooltip). The background-work note became an hourglass icon; the source line
does not truncate, the session title gives way first.

**Conversations.** Project and Session's right column lists conversations
(one native session each) with a disclosure: "Claude Code · <title>",
host · time of the last final answer · N answers, state chip, `Latest`.
Expanded, it lists that conversation's final answers (newest first; Latest
tag; click opens). Order: newest real final answer; conversations without one
follow. Expansion is kept in `projects.expandedConversations`. Filters and
logical-project grouping are unchanged from 9.3.

**Capture Final Window.** Attachments → 📎 → "Capture Final Window…" opens
macOS's own window picker (`SCContentSharingPicker`, single window); the
system handles consent. One still image of that window (`SCScreenshotManager`)
is stored locally as an attachment added by you (selected; uncheck/remove as
usual). Cancel or failure adds nothing. No automatic or background capture.
**Not tried live** — the picker and consent flow need the owner at the Mac.

**Labels.** Behavior → "Stay on the conversation I open"; off = Follow Latest.
