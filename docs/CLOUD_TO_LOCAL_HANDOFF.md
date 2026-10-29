# Cloud → Local handoff

A new Claude Code session on the Mac does **not** inherit the cloud
conversation. This file and the other docs are the full context.

## 1. Git state
- Repository: `Banderos14/prompt-relay`
- Branch: `claude/loving-mccarthy-ossw3q` (not merged into `main`)
- Commits: `75688ef` (core + tests), `cd34af4` (docs + ADRs), `4ff30b9`
  (handoff SHAs), `1d71087` (self-review fixes + regression tests), then the
  self-review docs commit (the branch tip). Confirm with `git log --oneline -6`.

## 2. Project state
Phase 0 is complete. The cloud-verifiable part of Phase 1 is complete. The
Mac validation (Phase 1.5) ran on 2026-10-29: the main path passed and some
checks remain open (§10). See `docs/STATUS.md` for the
verification matrix (Verified in Cloud / Verified with Mocks / Requires macOS
/ Not Implemented).

## 3. Implemented components
`prompt_relay/` (Python 3.9+, stdlib only):
- `hook.py`: the handler
- `store.py`: JSONL store
- `config.py`: project allowlist
- `events.py`, `correlation.py`, `history.py`: read model
- `export.py`, `gitinfo.py`, `sensitive.py`: Copy Response / Copy Context
- `clipboard.py`: pbcopy + MOCK
- `cli.py`: commands

Entry point: `bin/prompt-relay`. Tests: `tests/`. Scripts: `scripts/check.sh`,
`scripts/synthetic_demo.sh`. CI: `.github/workflows/tests.yml` (Linux; macOS
opt-in).

## 4. Accepted decisions
ADR-001 Local-first, no API · ADR-002 Official hooks (UserPromptSubmit, Stop,
StopFailure); plugin packaging for the public version · ADR-003 JSONL per
session, SQLite as the planned migration · ADR-004 Core/UI split, Python PoC
Core, data format as contract · ADR-005 Opt-in capture, explicit export,
secret warnings. Details are in `docs/DECISIONS.md`.

## 5. Test results (cloud, 2026-10-29)
- After the self-review: 79 tests on Python 3.13.17 and 3.9.25, all passed.
  1 skipped as root (permission test); it passes as a non-root user.
- Hook latency: median 72.6 ms.
- Audit findings and fixes: `docs/SELF_REVIEW.md`.
- Failed checks: none. Not run: anything on macOS, and any real Claude hook
  invocation.

## 6. Setup and commands on macOS
Prerequisites: any Python 3.9+ (Xcode Command Line Tools' `/usr/bin/python3`,
Homebrew or python.org), git, Claude Code CLI and/or Claude Desktop.
```bash
git clone https://github.com/Banderos14/prompt-relay.git ~/code/prompt-relay
cd ~/code/prompt-relay && git checkout claude/loving-mccarthy-ossw3q
export PR_PYTHON=/usr/bin/python3   # any Python 3.9+; /usr/bin/python3 only if `xcode-select -p` succeeds
PYTHONS="$PR_PYTHON" scripts/check.sh
"$PR_PYTHON" bin/prompt-relay doctor
```
- Hook validation: `docs/LOCAL_MAC_VALIDATION.md` §4 (CLI, `--settings`) and §5
  (Desktop, sandbox `settings.local.json`).
- Clipboard validation: same file, §3.

## 7. Risks and unresolved decisions
- D1–D5 in `docs/HOOKS_RESEARCH.md` §7, which need real payloads.
- Phase 3 decisions: keep the Python handler or port it to Swift; app↔core
  integration (`--json` CLI vs a Swift reader); macOS minimum version (OpenNook
  needs 15+); SQLite migration threshold.
- Installer: plugin first, settings merge as a fallback. Not designed in
  detail yet.

## 8. Next stage and acceptance criteria
**Phase 1.5 — Local Mac validation** (requires the owner's approval to start):
- every M-check in `LOCAL_MAC_VALIDATION.md` §10 has a recorded result in
  `docs/STATUS.md`;
- real payloads (redacted) are added as `tests/fixtures/real_*.json`, with
  tests that pass;
- D1–D5 are resolved or documented, with code changes only where a real
  payload contradicts the model;
- `~/.claude` checksums are unchanged after cleanup;
- no UI work.

## 9. Starter prompt for the local Claude Code session
Open Claude Desktop → Code → Environment **This Computer** → select the local
`prompt-relay` folder, then paste:

```
You are continuing development of Prompt Relay in a LOCAL macOS session
(MacBook Pro M3 Pro). The previous work happened in a cloud session; you do
not have its conversation. Start by reading, in order: CLAUDE.md,
docs/STATUS.md, docs/CLOUD_TO_LOCAL_HANDOFF.md, docs/ARCHITECTURE.md,
docs/HOOKS_RESEARCH.md, docs/LOCAL_MAC_VALIDATION.md.

Also read docs/SELF_REVIEW.md (audit results and the Phase 1.5 plan).

Then:
1. Confirm the branch is claude/loving-mccarthy-ossw3q, show `git log --oneline -5`,
   and confirm the working tree is clean.
2. Run the read-only environment check (LOCAL_MAC_VALIDATION §1) and the
   automated suite (§2) with the chosen Python 3.9+ ($PR_PYTHON; do not run
   /usr/bin/python3 if `xcode-select -p` fails). Report the exact results.
3. Walk me through LOCAL_MAC_VALIDATION §3–§9 step by step. Run the commands
   you can run yourself. Ask me to do the steps that need the Claude Desktop
   GUI, or that replace my clipboard, and wait for my confirmation before
   each of them.
4. Never edit ~/.claude/settings.json or enable capture for my real projects.
   Use only the sandbox folders from the checklist.
5. Record every result in docs/STATUS.md (results table). Add redacted real
   payloads as fixtures with tests. Fix only defects that real payloads
   prove, each with a regression test.
6. Commit on the same branch. Do not merge into main. Do not start Phase 2,
   any UI or a hook installer. Finish with a report split into Verified on
   macOS / Failed / Not checked, and stop.
```

## 10. Local → Cloud handoff after Phase 1.5 (2026-10-29)
A cloud session does not inherit the Mac conversation either. Read
`CLAUDE.md`, `docs/STATUS.md` (section "Verified on macOS") and
`docs/LOCAL_MAC_VALIDATION.md` §10 first.

**State.** Branch `claude/loving-mccarthy-ossw3q`, not merged into `main`.
The Phase 1.5 commit is the branch tip (`git log --oneline -3`).

**Proven on the Mac** (real Claude Desktop 4.29.0 / Claude Code 2.1.309):
Stop hook fires from a sandbox `.claude/settings.local.json`; Stop carries
the prompt's `prompt_id` (`link=prompt_id`); `last_assistant_message` equals
Claude's final text byte for byte; `copy --verify` through real pbcopy
passes; the clipboard is byte-exact for Unicode, CRLF, NUL and 1.18 MB. The
suite has 81 tests, 0 skipped, on Python 3.9.6 / 3.11 / 3.14.

**Not proven yet (needs a later Mac session):** manual ⌘V paste, CLI Stop
(the CLI login had expired), Esc, background tasks (D3), multi-tool text
(D2), several messages and parallel sessions (M5), StopFailure (an auth
failure fired none, D9), `agent_id` in a subagent turn (D6). Do not mark
these done from the cloud.

**Facts that matter for Phase 2.**
- Claude Desktop does not pass the shell environment to hooks. Use
  `hook-config --data-dir` for isolated setups; an installer must not rely on
  environment variables either.
- Users can have other tools' global hooks on the same events (observed on
  the owner's Mac). The installer must merge, never replace (SECURITY §5).
- Real payload fields observed: `session_id`, `transcript_path`, `cwd`,
  `scratchpad_dir`, `prompt_id`, `permission_mode` (`auto` in Desktop),
  `effort`, `stop_hook_active`, `last_assistant_message`, `background_tasks`,
  `session_crons`. Fixtures: `tests/fixtures/real_*.json`.

**Phase 2 in the cloud.** Scope needs the owner's approval at the start of
the session. Candidates that need no Mac: ROADMAP Phase 2 tasks 1–3 and 5
(`--json` API, conformance set, retention/`prune`, installer design tested
on fixture settings only). Task 6 (Swift) can be written but not built there.

Starter prompt for the cloud session:
```
Continue Prompt Relay in the cloud on branch claude/loving-mccarthy-ossw3q.
Read CLAUDE.md, docs/STATUS.md, docs/CLOUD_TO_LOCAL_HANDOFF.md §10,
docs/ROADMAP.md (Phase 2) and docs/LOCAL_MAC_VALIDATION.md §10.
Confirm the branch tip and a clean tree, run scripts/check.sh, then propose
the Phase 2 scope and wait for my approval before writing code. Do not merge
into main, do not touch macOS-only items, and keep the open Phase 1.5 checks
marked as not verified.
```
