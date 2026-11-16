# 0.5.0 — install and live acceptance (owner)

Nothing here has been run yet. Install and plugin update only with your
explicit go-ahead.

## A. Before installing

1. Quit the Xcode Debug copy yourself (Xcode ▸ Stop, or quit "Prompt Relay"
   whose path is under `DerivedData`). Prompt Relay never kills it.
   Check: `scripts/install-local.sh --status` → "Running: Release …" only.
2. Install the app (builds, verifies signature/version/Core digest/commit,
   keeps the old app as a backup, opens the new one):
   ```bash
   scripts/install-local.sh
   ```
   Undo: `scripts/install-local.sh --rollback`. Backups:
   `~/Library/Application Support/PromptRelay-AppBackups/`.
3. Plugin 0.5.0 (hooks unchanged; the plugin ships the Core). First remove
   the generated caches that test runs leave in `plugin/` (ignored by Git,
   not part of the plugin):
   ```bash
   find plugin -name __pycache__ -type d -prune -exec rm -rf {} +
   ```
   ```bash
   git status --ignored --short plugin
   ```
   (expect no output), then:
   ```bash
   claude plugin marketplace update prompt-relay
   ```
   ```bash
   claude plugin update prompt-relay@prompt-relay
   ```
   Restart Claude Code sessions afterwards. Settings → About in the app
   should show 0.5.0, Core 0.5.0, commit = HEAD, no mismatch.

## B. Checklist (tick and note what you saw)

| # | Check | Expected | Seen |
|---|---|---|---|
| 1 | Another app in front, hover the notch, press **Drag** once and move | drag starts on the first press; drop works; Esc cancels; second drag works | |
| 2 | Inbox: `+` on one Claude result and one Codex result → **Create Context Pack** | two numbered rows, provider · profile · host · project each | |
| 3 | Write an instruction, pick ChatGPT, **Prepare** → **Preview** | two separate `## Result` sections, your instruction under "Review instructions [Supplied by you]" | |
| 4 | **1 · Copy Text** → paste into ChatGPT (web), ChatGPT (desktop), Claude | whole text arrives; fences intact; nothing sent by Prompt Relay | |
| 5 | Add a PNG and a .md to a result, Prepare again → **2 · Copy Files** → paste; then the same with **Drag** | note per app: images arrive? documents arrive? both? | |
| 6 | **Capture Final Window** on a result, put it in the pack → Copy Files / Drag into ChatGPT | image arrives; then quit Prompt Relay: no new PNG in `~/Library/Application Support/PromptRelay/app` (only Export writes one) | |
| 7 | Prepare, quit Prompt Relay, reopen → Context Pack | results, instruction, receiver still there; **Prepare** again works | |
| 8 | Handoff History | Prepared → Text copied → Files copied / Drag started; "destination not verified"; Prepare Again; delete one record (results stay) | |
| 9 | Daily use | Inbox unread dots, By Agent grouping, Go To ⌘K, Needs Input amber dot on a question / plan / permission unchanged | |
| 10 | Phase 12.2 leftovers | Permission **Deny**; a cancelled question; two sessions, one waiting | |

## C. Compatibility matrix (filled only from your observations)

Status values: **works** · **partly** (say what) · **does not work** ·
**not tried**. Nothing is "works" until you saw it.

| Receiver | Text paste | Markdown fences intact | Copy Files: images | Copy Files: documents | Drag: images | Drag: documents | In-memory snapshot |
|---|---|---|---|---|---|---|---|
| ChatGPT web (browser: …) | not tried | not tried | not tried | not tried | not tried | not tried | not tried |
| ChatGPT desktop | not tried | not tried | not tried | not tried | not tried | not tried | not tried |
| Claude (claude.ai / Desktop) | not tried | not tried | not tried | not tried | not tried | not tried | not tried |
| Gemini (web) | not tried | not tried | not tried | not tried | not tried | not tried | not tried |
| Codex (terminal) | not tried | not tried | n/a (terminal) | not tried | n/a | path only (expected) | n/a |

After your notes, `HandoffDestination.support` is changed only for cells
you marked, and this table is copied into `docs/CONTEXT_PACK.md`.
