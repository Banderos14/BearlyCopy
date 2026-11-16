# Phase 16 — daily-driver acceptance (owner, about 20 minutes)

Fifteen checks you do yourself on this Mac, in order. No Git, Xcode or
process numbers needed. Write **Pass**, **Fail** (with what you saw) or
**Blocked** (could not try) in the Result column; a screenshot helps for any
Fail.

Before you start: the 0.7.0 app has been installed with your approval (step
"Install" in [PHASE16.md](PHASE16.md) §4). Nothing in this list is marked
passed until you have done it.

| # | Steps | Expected | Result |
|---|---|---|---|
| 1 | In Finder choose **Go → Home** (⇧⌘H), open **Applications** — your own Applications folder, where your other apps such as Blender already are. | **Prompt Relay** is there, once. No "Prompt Relay.before-…" copies next to it (they were moved to the backups if you agreed to `--tidy`). | |
| 2 | Look at its icon; also find it with Spotlight (⌘Space, type "Prompt Relay"). | Relay, the brown bear cub from the notch, on a dark rounded tile — in Finder and in Spotlight. (If Finder still shows an old generic icon, see "Icon looks old" below.) | |
| 3 | Quit Xcode and VS Code. Double-click **Prompt Relay** in Applications. | The bear appears beside the notch (or the floating island on a display without one) and a bear icon in the menu bar. No Dock icon (by design). | |
| 4 | Double-click Prompt Relay again while it runs. | The island opens (Home). | |
| 5 | Menu-bar bear → **Settings… → About**. | Build **Release**, version **0.7.0**, the commit named in the install message; "Running" lists one copy, from `~/Applications/Prompt Relay.app`. | |
| 6 | Menu-bar bear → **Quit Prompt Relay**. Then open it again from Applications. | It quits (bear gone from notch and menu bar); it reopens normally; your earlier results are still in the Inbox. | |
| 7 | In Claude Code (Desktop Code tab or CLI) in an enabled project, ask something short and wait for the answer. | Within a few seconds the island shows the new answer: your request, Claude's full answer, the right project and conversation. | |
| 8 | Open that result → **Copy Response**. Paste into TextEdit. | Exactly Claude's answer, complete (code blocks, Cyrillic, emoji intact). The island says it was copied. | |
| 9 | **Copy with Context**, paste into TextEdit. | Request, full answer, session and project, observed commands with exit codes, changed files, and clear "Reported by Claude" / "Confirmed locally" wording — no claim that tests passed unless they were observed. | |
| 10 | Ask Claude to write a small Markdown file and name it in its answer. In the result's **Attachments**: press **Add** (or **Add all**). | A line at the top says "Attached … — selected for Copy with Context and drag"; the file appears with a ticked box. Adding it again says it is already attached. A file Prompt Relay cannot keep (e.g. `.pbxproj`) says "Not attachable" instead of offering Add. | |
| 11 | Attachments → **Link Window…**, pick the Claude window of this conversation. Ask Claude one more short question. | After the answer, an **Auto screenshot** of that window appears in its Attachments (in memory). | |
| 12 | If step 11 said **Permission required**: press **Open Screen Recording Settings**, switch **Prompt Relay** on, then **Check Again** (quit and reopen if it says Restart required). | Screen & System Audio Recording opens (not the audio-only list); after enabling, Check Again succeeds and step 11 works. | |
| 13 | Copy with Context (with the screenshot and file ticked), then paste into a new ChatGPT message (text), and drag the attachments row(s) into the same message. | ChatGPT shows the text and the image/file. Nothing was sent automatically — you press Send. | |
| 14 | Restart the Mac (or log out and in). Open Prompt Relay from Applications. | All earlier results and attachments are there. Window links are gone (expected: they last until quit) — Link Window again when needed. | |
| 15 | Later, to update: double-click `scripts/Update Prompt Relay.command` in the project folder (or run `scripts/install-local.sh`). Then try `scripts/install-local.sh --rollback` once. | It shows installed vs new version, asks before replacing, installs, opens and verifies; rollback puts the previous version back and keeps the newer one as a backup. History unchanged both times. | |

## If something is off

| You see | Do this |
|---|---|
| **Icon looks old** in Finder although step 5 says 0.7.0 | Finder caches icons. `scripts/install-local.sh --status` confirms the installed build; log out and in, or run `scripts/install-local.sh --rollback` then the update again. The icon file itself is checked by the installer. |
| Two bears / two islands | A Debug build ("Prompt Relay Dev", hammer icon) is running too. Quit it from its hammer menu-bar icon. |
| Opening Prompt Relay starts an old version | An old copy is still in an Applications folder: `scripts/install-local.sh --status`, then `--tidy`. |
| After an update, screenshots say Permission required although Prompt Relay is switched on | Ad-hoc signed updates count as a new app for macOS: switch Prompt Relay off and on in Screen Recording, then Check Again. Installing with `--sign "Apple Development"` avoids this. |
| Update failed | Read the last line: nothing is replaced unless the build, the checks and the copy all pass; if replacing failed, the old app was put back. |
