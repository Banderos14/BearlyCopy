# Rules for AI agents working in this repository

Prompt Relay is an independent product. Read `docs/STATUS.md` and
`docs/archive/CLOUD_TO_LOCAL_HANDOFF.md` first. They hold the current phase and what
is approved.

## Scope
- Work only on the phase the owner approved in `docs/STATUS.md`
  ("Next agreed stage"). Do not start the UI, the notch window, the hook
  installer or the next phase without explicit approval.
- If a task requires widening scope or making a security-relevant
  architecture decision, stop and explain why.
- Never modify other projects, global macOS settings, `~/.claude/settings.json`
  or other agents' configuration. Never install hooks globally.
- No deploys, releases, publishing, or merging into `main` without the owner's
  approval. Work on a branch; small, logical commits.

## Product invariants (do not break; tests enforce most of them)
1. The hook handler never writes stdout, always exits 0, does no network I/O,
   never runs git or shell commands, and never reads transcripts or project
   files.
2. Captured text is stored and copied **verbatim**. Never summarize,
   truncate, reformat or "fix" it.
3. Never combine data across sessions. An uncertain link is labeled
   (`sequence` / `ambiguous` / `none`), never guessed.
4. `Stop` means "Claude stopped", not "task succeeded". `StopFailure` text is
   an API error, never a response.
5. Claude's claims are *Reported by Claude*. Only locally read facts are
   *Confirmed locally*.
6. Capture is opt-in per project and fails closed.
7. User data lives outside the repository. Never commit captured text or real
   payloads without redaction.
8. Standard library only for the Core (Python 3.9 compatible) unless an ADR
   says otherwise.
9. Integration is plugin-first (ADR-008). Prompt Relay code never writes
   Claude Code settings files, and never changes or prints other tools'
   hooks; read-only diagnostics may only count them. Real plugin installs happen only on
   the owner's Mac, through `claude plugin` commands, with consent.
10. Nothing stateful lives in the plugin root (it changes per version) or in
    `${CLAUDE_PLUGIN_DATA}` (deleted on uninstall). History stays in the app
    data dir. The plugin root must not contain `bin/`.

## Working practice
- Read the existing code and docs before changing them; match their style.
- Use only documented Claude Code hook fields (`docs/HOOKS_RESEARCH.md`).
  When docs and observed behavior differ, record it there.
- Every bug fix gets a regression test. Run `scripts/check.sh` before every
  commit. Run it with Python 3.9 too when it is available.
- Report results honestly. Separate *Verified in Cloud*, *Verified with
  Mocks*, *Requires macOS* and *Not Implemented*. Never claim a macOS,
  clipboard, Claude Desktop or UI check that did not run on a Mac.
- Keep `docs/STATUS.md` current at the end of each work session.
