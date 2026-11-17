# Contributing to BearlyCopy

BearlyCopy is a source-available portfolio project (see `LICENSE`): the code
is public to read, but **external contributions and reuse are not accepted**.
Issues with bug reports are welcome. The rules below are the maintainer's own
working rules and show how the project is kept trustworthy.

## Ground rules (product invariants)

Read `CLAUDE.md` — it applies to human contributors too. In short:

1. The hook handler never writes stdout, always exits 0, does no network
   I/O, runs no git/shell commands and reads no transcripts or project files.
2. Captured text is stored and copied **verbatim**.
3. Sessions are never merged; uncertain links are labelled, not guessed.
4. Capture is opt-in (selected projects, or the owner's explicit "all projects" mode with exclusions) and fails closed.
5. User data never enters the repository. Never commit captured text or real
   payloads without redaction.
6. The Core is Python 3.9+, standard library only.
7. BearlyCopy never writes Claude Code settings or other tools' hooks.

Most of these are enforced by tests; a change that needs to relax one needs
an ADR in `docs/DECISIONS.md` first.

## Setup

```bash
scripts/check.sh                        # Python Core: unit, integration, latency
(cd macos && swift test)                # Swift: app model, layout, views (offscreen)
scripts/install-local.sh --dry-run      # build and verify the app without installing
```

Xcode: open `macos/PromptRelay.xcworkspace` (Debug build, separate bundle ID).
Docs: `docs/INSTALL.md`, `docs/ARCHITECTURE.md`, `docs/MACOS_APP.md`.

## Pull requests

- One logical change per PR, with tests. Every bug fix gets a regression test.
- Run `scripts/check.sh` (and with Python 3.9 if you have it) and
  `swift test`. Say what you verified and what you could not (for example
  real clipboard, real Claude Desktop, a second display).
- Swift tests must not create real `UserDefaults` suites; use
  `TestDefaults.named(_:)` / `MemorySettingsStore` (a guard test enforces it).
- Use only documented Claude Code / Codex hook fields
  (`docs/HOOKS_RESEARCH.md`).
- UI text: short, plain, no claims the app cannot verify
  ("Reported by Claude" vs "Confirmed locally").

## Reporting bugs

Open an issue with: macOS version, how you installed (release / checkout),
Settings → About (version, commit, build), Settings → Diagnostics, and
`prompt-relay doctor --json` output **with paths and project names
redacted**. Never paste captured answers or prompts unless you wrote them
for the report.

Security issues: see `docs/SECURITY.md`; please do not file them publicly.
