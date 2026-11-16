# Phase 12.1 — Needs Input: accurate agent states

2026-11-05. Start: HEAD `40cb6bd`, installed app 0.4.0 `e75cdd5`, active
Claude Code plugin 0.4.0. Neither was changed in this phase (no install, no
plugin update). No push or merge. Staged `REPORT.md` and acceptance files
untouched. Repo version → **0.4.1** (Core, `plugin.json`, Xcode), because
the plugin's hook map changed and Claude Code caches plugins per version.

Legend: **Tested** (real hook handler processes or Swift tests on this Mac)
· **Offscreen** (real views rendered without a live GUI) · **Documented**
(hooks reference, not observed) · **Requires owner**.

## 1. Events — what is supported

| Signal | Source | Stored as | Ends the wait | Status |
|---|---|---|---|---|
| AskUserQuestion | `PreToolUse` (matcher), sync | `needs_input/question` | its `PostToolUse`/`Failure`, any later tool result, prompt, Stop | Tested (synthetic payloads) · not observed live |
| ExitPlanMode | `PreToolUse`, sync | `needs_input/plan_approval` | same | Tested · not observed live |
| Permission | `PermissionRequest`, sync; `Notification permission_prompt` (~6 s later) | `needs_input/permission` | the tool's result (any tool), Stop, prompt | Tested · not observed live |
| MCP elicitation | `Notification elicitation_dialog/_url_dialog` | `needs_input/elicitation` | `elicitation_complete/_response`, activity | Tested · not observed live |
| "Agent needs input" | `Notification agent_needs_input` | `needs_input/input` | activity | Tested · meaning only documented |
| Session closed | `SessionEnd` (stored only if a wait is open) | `session_end` | — | Tested |
| Codex approval | Codex `PermissionRequest` (Core adapter) | `needs_input/permission` | PostToolUse, Stop, prompt | Tested in Core · **not configured**: `configure-codex.py` unchanged (would change your Codex hooks + new trust) |

Never stored: question/plan/command text, `tool_input`, `message`,
`title`, `permission_suggestions`. `idle_prompt` and `PreToolUse` of other
tools are ignored. No event reports "the person answered"; a wait ends with
the next confirmed activity, never a timer.

**Hosts.** Claude Code in Terminal and Claude Desktop run the same plugin
hooks — **expected**, not observed live. Codex · Xcode: no known waiting
signal → keeps its last confirmed state (Working). Codex CLI: supported by the
Core once its hook is configured (not done).

## 2. States (independent per conversation)

Idle (no indicator) · Working (three dots) · Waiting for background tasks
(amber dots, Phase 9.4) · **Needs Input** (static amber dot) · Final Answer
Ready (green dot) · Completion Unknown (Inbox "Attention", Phase 12) · Error
(API error / capture warning). Needs Input is the Core's `attention` per
session (provider, profile, host, project and conversation come with the
session); it never changes `completion`, answers, Inbox results, unread
state or Copy with Context. Several agents: the notch shows Needs Input
first (it blocks progress); working, waiting and answered conversations keep
their chips in Project and Session / By Agent; the Inbox is unchanged.

## 3. UI

- Notch: still amber dot (no animation loop); accessibility label "an agent
  needs your input".
- Details band: "Claude · Needs input · Plan" (or "2 need input"); Quick Peek
  band: "Needs input" — the slot beside the camera housing is too narrow for
  more; the tooltip and accessibility label give "Claude Code · Claude
  Desktop in repo waits for you: Plan approval…". A click shows that
  conversation in Prompt Relay; the answer is given in the agent's app.
- Conversation chip: "needs input".
- Settings → General → "Notify when an agent needs input": **off by
  default**; title "Claude Code needs your input", body project + type,
  never the text; once per wait; waits already open at launch are not
  announced; no app switching.

## 4. Never automatic

The handler writes nothing to stdout and exits 0 for every event — per the
hooks documentation that is "no decision": the dialog appears as usual.
Prompt Relay does not answer, allow, approve, change permission modes,
return `updatedInput` or block anything. Tested: stdout empty and exit 0 on
every signal path.

## 5. Tests

| Check | Result |
|---|---|
| `tests/test_phase121.py` (15, real hook processes): question → answered → Stop; plan approval; permission allowed by a non-evidence tool, `permission_prompt` same wait; denied then Stop; background wait ≠ Needs Input; one session waits, another works; redelivery stored once, restart same state, cancelled question, new prompt; elicitation result and SessionEnd; no timer; no signal → nothing invented, ignored events not stored; ordinary tools store nothing; SessionEnd without a wait creates no conversation; Inbox/Copy with Context unaffected; Codex PermissionRequest; raw signal records never read; secret question text never on disk | Tested |
| `test_plugin` (updated): hook map pinned; real `claude plugin details` lists 9 hooks, ~0 tokens | Tested |
| `scripts/check.sh` Python 3.14 / 3.9.6 | 228 + 15 each, OK (1 skipped, Linux-only); hook median 39.4 ms |
| `Phase121Tests` (8, Swift): decoding + kinds; Needs Input before working/answer, Codex keeps Working; back to Working; two agents counted not merged; host without signal not invented; notification once per wait, none at launch or after restart; setting off by default; band in Quick Peek and Details inside the island | Tested / Offscreen |
| Full `swift test`, Xcode Debug/Release | see §7 |

## 6. Not reliably determinable

- That the person answered: only inferred from the next activity.
- A wait abandoned with no further event (window closed without SessionEnd)
  stays shown until the session continues — by design (no timer).
- Subagent permission requests in non-interactive runs: shown, labelled
  `subagent` in the API; may not need the person.
- `permission_prompt` alone (without `PermissionRequest`) arrives ~6 s late.
- Codex in Xcode, Codex CLI before its hook is configured: no signal.

## 7. Git and full runs (logs in `macos/acceptance/phase12.1/`, not committed)

| Run | Result |
|---|---|
| `swift test`, first full run | XCTest 271/0 failures; Swift Testing 89/98 — 9 issues, all Phase 12 Inbox tests timing out at 10 s while the long offscreen-rendering suites held the main thread (both suites pass alone and together: 20/20, 28/28). Wait ceiling raised to 60 s (returns as soon as true) |
| `swift test`, final | XCTest **271**, 16 skipped, **0 failures**; Swift Testing **98/98**; prefs files 11,331 → 11,331 |
| Python 3.14.0 / 3.9.6 | 228 + 15 each, OK |
| `xcodebuild` Debug / Release | BUILD SUCCEEDED, 0.4.1 |
| `git diff --check` | clean |

Commits: `94993af` (code, tests, 0.4.1), then the docs commit with this
file. Installed app (0.4.0 `e75cdd5`) and active plugin (0.4.0) unchanged.
Note: test runs recreate ignored `plugin/**/__pycache__`; clean them before
any plugin update (Phase 12 §18).

## 8. Owner checks (after you approve a 0.4.1 install + plugin update)

1. Clean `plugin/__pycache__`, update the plugin (same steps as Phase 12
   §18), restart Claude Code.
2. Ask Claude to use AskUserQuestion → notch amber dot, Details "Claude ·
   Needs input · Question"; answer → dots return; final answer → green.
3. Plan mode → plan shown → "· Plan"; approve → Working.
4. A command that needs permission → "· Permission"; Allow → Working; again
   and Deny → Claude stops → answer/green or idle.
5. Two sessions: one asking, one working → amber dot; Project and Session
   shows "needs input" and "working".
6. Settings → notify on → one banner per wait, no question text.
7. `bin/prompt-relay sessions --json` shows `attention`; record the real
   payload field names in `docs/HOOKS_RESEARCH.md`.


## 9. Acceptance pass (2026-11-06)

**Fixed**
- **Copy with Context**: a subagent's `<agent-message from="…">` report
  (observed: the whole prompt was that block) was classified as the user's
  request. `agent-message` is now an automated block in the Core
  (`origin.HARNESS_TAGS`) and in the app's display code. Copy with Context
  shows the user's latest earlier request under *Original user request* and
  the report verbatim under *Automated message that started this turn*;
  the Inbox names the result by the user's request. Regression tests:
  Python (classification, pasted stays the user's, mixed = source unknown,
  context sections, results) and Swift (display).
- **Needs Input lifecycle**: Esc, a killed window or a missing SessionEnd may
  send no event. Such a wait is never removed by time, but it is no longer
  claimed as certain once its newest signal is > 30 min old or the same agent
  profile shows activity in a later conversation of the same project: amber
  ring instead of dot, "May need input", chip "needs input?", no
  notification. A repeated `permission_prompt` re-confirms it
  (`attention.last_signal_at`). Answered/denied/cancelled-with-a-result
  waits end as before.

**Timeout check.** Strict timing test (opt-in, `PROMPT_RELAY_TIMING=1`):
Inbox shown after 14.5 ms, a result opened after 15.1 ms, `loadInbox` 0.09 ms
(alone); 15.1 / 15.1 / 0.12 ms inside the full suite run serially. In the
parallel run the same open took 2.18 s and an untouched Phase 9.3 test with a
2 s ceiling timed out — both pass serially with their original bounds: the
delay is other suites blocking the main thread (synchronous
`RunLoop.main.run` render loops), not the interface. The 60 s ceiling in
Phase 12 tests absorbs only that.

**Runs on `0dffa80`** (logs in `macos/acceptance/phase12.1/`)

| Check | Result |
|---|---|
| Python 3.14.0 / 3.9.6 (`check.sh`) | 230 + 15 each, OK (1 skipped) |
| `swift test` (parallel) | XCTest 271/0 failures; Swift Testing 100/102 — the timing test (since made opt-in) and Phase93 `followLatestHoldsOnlyWhileTheIslandIsOpen` timed out under contention |
| `swift test --no-parallel`, timing on | Swift Testing **102/102**; XCTest 271 with **2 failures**: two scroll-wheel tests (`IslandLayoutTests` answer scroll, `NotchControllerTests` real-panel scroll). They fail identically on the unchanged `f8a7f9a` (temporary worktree) and passed in all earlier runs: **the screen was locked and the displays asleep** (`CGSessionCopyCurrentDictionary`), so synthetic scroll events reach no window. To re-run with the screen unlocked. |
| Xcode Debug / Release | BUILD SUCCEEDED, 0.4.1 |
| `git diff --check` | clean |

**Installed with the owner's consent**
- App: 0.4.0 `e75cdd5` backed up as
  `PromptRelay-AppBackups/Prompt Relay 0.4.0-e75cdd5-20261106-071019.app`;
  running `~/Applications/Prompt Relay.app` PID 62216, 0.4.1, `0dffa80`,
  not dirty, Core 0.4.1, signature valid. Rollback: `install-local.sh
  --rollback`. The Xcode Debug copy (PID 55979) was still running.
- Plugin: `plugin/` cleaned of test-run `__pycache__` (28 committed files,
  no symlinks, no secrets), then `claude plugin marketplace update` +
  `claude plugin update` → record 0.4.1, cache byte-identical to
  `HEAD:plugin`, `settings.json` hash unchanged; 0.2.0–0.4.0 caches kept.
  Codex hooks, trust records, credentials untouched.

**Live probe** (owner-approved, isolated; see HOOKS_RESEARCH "live probe"):
the installed 0.4.1 launcher ran for real (`UserPromptSubmit` stored,
`SessionEnd` ignored without a wait). The CLI's login had expired, so no
model turn ran and **AskUserQuestion / ExitPlanMode / PermissionRequest were
not observed live**; their fields stay documented-only.

**Live checks still for the owner** (restart Claude Code / Desktop first;
stop the Xcode Debug copy; unlock the screen):
1. Ask Claude to use AskUserQuestion → amber dot, Details "Claude · Needs
   input · Question" → answer → working dots → final answer → green dot.
2. Plan mode → plan approval → "· Plan" → approve → Working → green.
3. A Bash command needing permission → "· Permission" → Allow → Working;
   repeat → Deny → Claude stops.
4. Two agents: one asking, one working → amber dot; Project and Session
   shows "needs input" and "working" side by side.
5. Esc on a question → if no further event: after 30 min "May need input"
   (ring), never gone by itself; a new prompt clears it.
6. `bin/prompt-relay sessions --json` → `attention`; send the real field
   names (or let the probe run after `claude` login) for HOOKS_RESEARCH.
7. Re-run the two scroll tests with the screen unlocked.
