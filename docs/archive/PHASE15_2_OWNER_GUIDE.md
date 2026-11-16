# Owner guide — run the latest Debug build, fix screenshots

Plain steps. You do not need Xcode, Git or process numbers.

## A. Switch to the latest Debug build (Phase 15 / 15.1 / 15.2)

Open **Terminal** and paste these lines one at a time.

1. Look first (changes nothing):
   ```bash
   ~/Projects/prompt-relay-phase15/scripts/run-latest-debug.sh
   ```
   It lists every Prompt Relay copy that is running (Debug or Release,
   version, commit, where it lives) and what the next step would do.

2. Switch:
   ```bash
   ~/Projects/prompt-relay-phase15/scripts/run-latest-debug.sh --switch
   ```
   It builds the new Debug app (about 30 seconds), asks the **old Debug
   copy** to quit normally (like choosing Quit in its menu), starts the new
   one, and prints the commit it is running. Your history and settings stay.
   - macOS may ask whether **Terminal** may control **Prompt Relay**. Allow it,
     or quit the old copy yourself: click the **hammer icon** in the menu bar →
     **Quit Prompt Relay**, then run the command again.
   - If you see "Xcode — the app quit" in Xcode, that is expected.
   - The installed app (0.4.1) keeps running and steps aside at the notch.
     To quit it too, add `--quit-release`. It is not deleted or replaced.

3. Check: open the island → **Settings → About**. Expect **Build: Debug
   (Xcode)** and **Commit** equal to the commit the script printed. "Running"
   should list one Debug copy (and the Release one if you kept it).

Going back: quit the new copy from its menu-bar icon and open the old app
the way you used to. Nothing was removed.

## B. Auto screenshots: what the messages mean

| You see | It means | Do this |
|---|---|---|
| **Window not linked** | This copy of Prompt Relay has no window linked for this conversation. Links end when Prompt Relay quits, and each copy (Debug / Release) has its own. | **Link Window…**, then pick the Claude window that shows this conversation. Next final answers are captured. **Capture Now…** takes one picture without linking. |
| **Permission required** | macOS refused the capture. | **Open Screen Recording Settings**, switch on **Prompt Relay Dev** (that is the Debug build; "Prompt Relay" is the installed 0.4.1 app). Then **Check Again**. |
| Permission is on, still **Permission required** or **Restart required** | A rebuilt Debug app can count as a new app for macOS, or the app started before you allowed it. | In Screen Recording switch **Prompt Relay Dev** off and on again, then **Check Again**; if it says Restart required, **Quit Prompt Relay** and reopen it. |
| **Window not available right now** | The linked window still exists but is minimized, on another Space or hidden. The link is kept. | Bring the window back; the next answer is captured. |
| **Window closed** | The linked window was closed; its link was removed. | **Link Window…** again. |
| **Window association required** | Two active conversations could be in the same window, so nothing was taken. | Link the window to this conversation (**Link Window…** here). |

**Open Screen Recording Settings** appears with every one of these, and opens
System Settings → Privacy & Security → **Screen & System Audio Recording**
(not the audio-only list).

A successful **Capture Now** shows the permission works; it does not prove
the automatic capture will trigger — that needs a linked window and a new
final answer.

## C. Words in Evidence & Review
- **observed** — facts Prompt Relay saw on this Mac (commands, exit codes, files).
- **checks left** — your own review checklist; ticking changes only this.
- **build/test failed** — the build or test itself exited non-zero.
- **unclear** — a test/build line whose exit code may belong to another step
  (`| tee`, `| grep`, `;`, `&&`): its result is unknown, not failed, not passed.
- **likely not an error** — e.g. `grep` found nothing (exit 1); listed, not an alarm.
- None of these means the task succeeded; Claude stopping is not success.
