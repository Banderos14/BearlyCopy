# Phase 17 — owner acceptance (10 checks, about 15 minutes)

You do these yourself on this Mac, in order, after installing app 0.9.0 and
plugin 0.9.0 ([PHASE17.md](PHASE17.md) §8). Write **Pass**, **Fail** (what
you saw) or **Blocked** in the Result column. Nothing here is marked passed
from automated tests.

| # | Steps | Expected | Result |
|---|---|---|---|
| 1 | Open **Prompt Relay** from Applications. Menu-bar bear → Settings → **About**, then **Daily Use**. | Version 0.9.0, one running copy. Daily Use shows a state and one sentence — "Setup incomplete" before step 4 of the install, never "Ready" by itself. | |
| 2 | In Claude Code (Desktop or CLI) start a **new** chat in a project and ask something short. | The island shows the request and the full answer under the right project and conversation within a few seconds. | |
| 3 | Move the pointer away so the island closes; open it again. Repeat three times. | The same newest answer every time — never an older one. No "Pinned" tag in the header. | |
| 4 | Ask a second question in the same chat. Close and reopen the island. | The second answer. (If the island was open while it arrived, the first stays on screen with "Jump to Latest" in the header; after closing, the second.) | |
| 5 | Switch to another repository that was **never** switched on (for example the theatre project), new chat, ask something. | Its answer becomes the one shown, under its own project. No per-project switch was needed (All Projects). | |
| 6 | Start two chats in two projects and send both a prompt so they finish close together. | The one that finished last is shown; the other is unread in the Inbox with its own project. The notch shows working while they run. | |
| 7 | Ask Claude: "Write notes.md with three lines and tell me its name; also mention docs/api/api-v1.schema.json." Open **Attachments**. | `notes.md` — "Attached automatically · written this turn", ticked. `api-v1.schema.json` — "Attached automatically · named in the answer, not seen written", ticked. No Add needed. A `.env` or a credentials file would say "Excluded for safety". | |
| 8 | With automatic screenshots on and the Claude window linked (install step 5), ask one more short question. | An **Auto screenshot** of that window appears under Attachments (in memory), ticked only if "Include auto screenshots in handoff" is on. If it says "Window association required", another chat was active in that window in the last 30 minutes — see PHASE17.md §6. | |
| 9 | **Copy Response** → paste into TextEdit. **Copy with Context** (files ticked) → paste into a new ChatGPT message, then drag the files. | Response: exactly Claude's text. Context: request, answer, observed commands and the ticked files; the files arrive by drag. You press Send — nothing is sent for you. Unpressed "Done" no longer keeps this answer on screen for good: 10 minutes later a newer answer is shown again. | |
| 10 | Menu-bar bear → **Quit Prompt Relay**. Open it again from Applications. | History and settings are there; the newest answer is shown; Daily Use says "Window not linked" (links end at quit) with **Link Window…** beside it — one click to link again. | |

## If something is off

| You see | Do this |
|---|---|
| "Plugin update required" or All Projects refuses to switch on | Daily Use → **Copy Update Commands**, run them in Terminal, start a new Claude session, **Check Again**. |
| An older answer after reopening | Look at the header: **Pinned** (Follow Latest unpins) or an unfinished file transfer started in the last 10 minutes. Otherwise it is a Fail — note which answer and a screenshot. |
| A file is listed with Add | Its second line says why (changed after the answer, excluded for safety, too large, many files named). Add attaches the current version on your decision. |
| "Permission required" after an update | Ad-hoc signed updates are a new app for macOS: switch Prompt Relay off and on in Screen Recording, then Check Again. |
| Anything worse | `scripts/install-local.sh --rollback` puts the previous app back; history is not touched. |
