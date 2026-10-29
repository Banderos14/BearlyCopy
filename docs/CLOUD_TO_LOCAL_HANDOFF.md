# Cloud → Local handoff

A new Claude Code session on the Mac does **not** inherit the cloud
conversation. This file and the other docs are the full context.

## 1. Git state
- Repository: `Banderos14/prompt-relay`
- Branch: `claude/loving-mccarthy-ossw3q` (not merged into `main`)
- Commits: `75688ef` (core + tests), `cd34af4` (docs + ADRs), then
  the commit that records these SHAs (the branch tip). Confirm with
  `git log --oneline -5`. The tip must contain this file.

## 2. Project state
Phase 0 is complete. The cloud-verifiable part of Phase 1 is complete. The
Mac validation (Phase 1.5) has not started. See `docs/STATUS.md` for the
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
- 59 tests on Python 3.13.17 and 3.9.25: all passed. 1 skipped as root
  (permission test); it passes as a non-root user.
- Hook latency: median ≈ 60–73 ms.
- Failed checks: none. Not run: anything on macOS, and any real Claude hook
  invocation.

## 6. Setup and commands on macOS
Prerequisites: Xcode Command Line Tools (`xcode-select --install`), git,
Claude Code CLI and/or Claude Desktop.
```bash
git clone https://github.com/Banderos14/prompt-relay.git ~/code/prompt-relay
cd ~/code/prompt-relay && git checkout claude/loving-mccarthy-ossw3q
PYTHONS=/usr/bin/python3 scripts/check.sh
bin/prompt-relay doctor
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

Then:
1. Confirm the branch is claude/loving-mccarthy-ossw3q, show `git log --oneline -5`,
   and confirm the working tree is clean.
2. Run the read-only environment check (LOCAL_MAC_VALIDATION §1) and the
   automated suite (§2) with /usr/bin/python3. Report the exact results.
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
