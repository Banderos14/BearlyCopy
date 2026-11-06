# 0.6.0 — live acceptance (owner, on this Mac)

Nothing here has been run yet. Each row is filled in only from what you see.
Full background: [ACCEPTANCE_PHASE14](ACCEPTANCE_PHASE14.md).

## Before (needs your consent, separately)
A. **Install the app.** `scripts/install-local.sh --dry-run`, then
   `scripts/install-local.sh`. It backs up 0.4.1 to
   `~/Library/Application Support/PromptRelay-AppBackups/`, asks the
   installed copy to quit normally, never quits the Xcode Debug copy (quit it
   yourself so only one island runs). Undo: `scripts/install-local.sh --rollback`.
B. **Plugin (optional).** Hooks are unchanged since 0.4.1, so capture works
   with the installed 0.4.1 plugin; updating only aligns versions:
   `claude plugin marketplace update prompt-relay`, then
   `claude plugin update prompt-relay@prompt-relay`; restart Claude Code sessions.

## Checks
1. **Quick Peek / Details, no clipped rows** (14" display): Copy with Context
   shows whole rows (+N more), the Answer ends on a whole line.
2. **Hover-resize**: open by hover, click a tab low in a tall view that leads
   to a shorter one, keep still 10 s → stays open; move onto the island →
   stays open; click in the strip the island just left → the click reaches
   the app below and the island closes; move away → closes.
3. **Settings → Automatic final screenshots** on; open a Claude Desktop
   conversation; *Link Window for Open Conversation…*; pick Claude's window
   (allow screen capture if macOS asks).
4. **Real final answer** in that conversation → Attachments shows
   "Auto screenshot Claude Desktop …", unchecked, "in memory".
5. **Preview** it; tick it; **Copy with Context**; **Context Pack** (Copy Text,
   Copy Files); **Drag** it into ChatGPT (web and desktop if available).
6. After quitting Prompt Relay: no new PNG under
   `~/Library/Application Support/PromptRelay/app/`
   (`find ~/Library/Application\ Support/PromptRelay/app -name '*.png' -newer <file>`).

## Record (fill in)
| What | Result |
|---|---|
| Capture happened (yes / no / status shown) | |
| Last lines of the answer visible in the screenshot | |
| Delay: final answer → Attachments (stopwatch, s) | |
| Window chosen correctly (agent, profile, conversation) | |
| No PNG on disk after quit | |
| ChatGPT web: pasted text / dropped image accepted | |
| ChatGPT desktop: pasted text / dropped image accepted | |
| Hover-resize: stayed open / click passed through | |
