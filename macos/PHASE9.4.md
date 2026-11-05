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
