# Prompt Relay

Local context bridge for AI coding agents on macOS.

Prompt Relay automatically captures the **complete final answer** of every
Claude Code turn through official Claude Code hooks. It stores the answer
locally with its project and session, and copies it to the clipboard with one
command, ready to paste into ChatGPT for planning or independent review.

```
Claude Code ──(hooks)──► Prompt Relay (local store) ──(one click/command)──► clipboard ──(you paste)──► ChatGPT
```

## Who it is for
Developers who plan and review in ChatGPT and implement with Claude Code (CLI
or Claude Desktop local sessions), often across several projects and
sessions at once.

## The problem it solves
Selecting a long Claude answer by hand is slow and error-prone. It loses
Markdown and code fences, and it mixes up sessions. A pasted "all tests pass"
also tends to become an unquestioned fact. Prompt Relay copies the exact text,
keeps sessions apart, and labels what is confirmed versus only reported by
Claude.

## Principles
Local-first · privacy-first · no AI APIs · no network · opt-in per project ·
verbatim capture · never blocks or steers Claude Code.

## Status
**Proof of concept (Phase 3A). Not a product release.**
- Done and tested in the cloud (Linux): the hook handler, storage, session
  correlation, Copy Response / Copy Context, the JSON API for the future app,
  history management, the Claude Code plugin package, and 137 automated tests.
- Verified on a real Mac (Phase 1.5): Claude Desktop → Stop hook → Prompt
  Relay → system clipboard, byte-exact. Further Mac checks are open
  (`docs/STATUS.md`).
- Native macOS menu-bar app (Phase 3A): browse answers and copy them with
  one click, no terminal. Build: `scripts/build-macos-app.sh --install`
  (`docs/MACOS_APP.md`).
- The plugin is installed and verified on a real Mac
  (`docs/LOCAL_MAC_VALIDATION.md` §11). Not started: the notch UI.

## Install as a Claude Code plugin
```bash
bin/prompt-relay enable ~/code/my-project          # capture is opt-in per project
claude plugin marketplace add ~/code/prompt-relay  # this checkout is the marketplace
claude plugin install prompt-relay@prompt-relay
```
Restart Claude Desktop, or run `/reload-plugins` in a session. Then
`bin/prompt-relay doctor`. Details, disabling and uninstalling are covered in
[docs/PLUGIN.md](docs/PLUGIN.md). Uninstalling never deletes your history.

See `docs/STATUS.md` for the exact state.

## Try it with synthetic events (no Claude needed)
```bash
scripts/check.sh                 # all tests
scripts/synthetic_demo.sh        # isolated demo with a MOCK clipboard
```

## CLI (PoC)
```bash
bin/prompt-relay enable ~/code/my-project     # opt in a project
bin/prompt-relay sessions                     # captured sessions
bin/prompt-relay turns [--session ID]         # turns with status and link quality
bin/prompt-relay show [--project DIR]         # print the latest final answer verbatim
bin/prompt-relay copy [--verify]              # Copy Response → clipboard (macOS)
bin/prompt-relay context                      # preview Copy Context
bin/prompt-relay copy-context                 # Copy Context → clipboard (secret check first)
bin/prompt-relay sessions --json              # machine API for the app (docs/JSON_API.md)
bin/prompt-relay prune --older-than-days 30   # preview deletion of old sessions; add --yes to delete
bin/prompt-relay delete --session ID          # preview; add --yes (and --force-active for a live session)
bin/prompt-relay doctor [--json]               # Python, storage, capture, plugin/settings registration (read-only)
bin/prompt-relay pin-python [--show]           # the Python the plugin hook uses (enable pins one automatically)
bin/prompt-relay hook-config                  # settings-hook JSON for isolated checks (`claude --settings`); writes nothing
```

Requirements: macOS on Apple Silicon and any Python 3.9+. That can be
`/usr/bin/python3` from the Xcode Command Line Tools, Homebrew or python.org.
`bin/prompt-relay doctor` checks it. No other dependencies.

## Documentation
| Doc | Content |
|---|---|
| [PRODUCT_SPEC](docs/PRODUCT_SPEC.md) | vision, users, stories, scope, non-goals |
| [ARCHITECTURE](docs/ARCHITECTURE.md) | components, data flow, hook contract, correlation |
| [DATA_MODEL](docs/DATA_MODEL.md) | on-disk format (contract for the future app) |
| [PLUGIN](docs/PLUGIN.md) | install, enable, disable, uninstall, diagnostics, coexistence |
| [DECISIONS](docs/DECISIONS.md) | ADR-001…008 |
| [JSON_API](docs/JSON_API.md) | machine-readable CLI API v1, versioning rules ([schema](docs/api/api-v1.schema.json)) |
| [HOOKS_RESEARCH](docs/HOOKS_RESEARCH.md) | hook schemas, install options, open questions |
| [SECURITY](docs/SECURITY.md) | threat model, privacy, installation safety |
| [TEST_PLAN](docs/TEST_PLAN.md) | unit, integration, manual and regression tests |
| [ROADMAP](docs/ROADMAP.md) | phases and acceptance criteria |
| [UI_RESEARCH](docs/UI_RESEARCH.md) | notch UI foundations (research only) |
| [LOCAL_MAC_VALIDATION](docs/LOCAL_MAC_VALIDATION.md) | step-by-step Mac checks |
| [CLOUD_TO_LOCAL_HANDOFF](docs/CLOUD_TO_LOCAL_HANDOFF.md) | how to continue in a local session |
| [STATUS](docs/STATUS.md) | current state, verification matrix, risks |
| [SELF_REVIEW](docs/SELF_REVIEW.md) | Core audit results and the Phase 1.5 plan |
