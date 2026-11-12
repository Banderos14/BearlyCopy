# Phase 17 — Daily workflow stabilization (0.9.0)

Branch `phase/17-daily-stabilization` (worktree
`~/Projects/prompt-relay-phase16`), from the verified 0.8.0 baseline
`1afa08b`. Goal: the newest answer, its files and its screenshot arrive by
themselves, and one short setup is all the configuration there is. No new
providers, APIs or features beyond that.

## 1. Baseline verified (2026-11-12, before any change)

| What | Found |
|---|---|
| Source | `phase/16-daily-driver` = `origin` = `1afa08b` (docs), `6020544` (app 0.8.0), `10ef117` (Core); clean |
| Installed app | `~/Applications/Prompt Relay.app` 0.7.0 |
| Installed plugin | `prompt-relay@prompt-relay` 0.4.1 (marketplace source: the main checkout, 0.6.0) |
| Owner's preferences (read only) | `behavior.staysOnChosenSession = false`, no saved pin, `attachments.autoCaptureFinalWindow = true`, capture config schema 1 (Selected, 5 folders) |
| Owner's app data (read only, metadata) | `app/handoffs.json`: **7 unfinished hand-offs** (`filesCopied: false`, `resumed: true`) |

## 2. Confirmed defects and root causes

### 2.1 An older answer after reopening Quick Peek (P1)

Reproduced by `Phase17LatestTests.reopeningNeverPrefersAnOlderUnopenedAnswerOverTheNewest`
(failed on reopen 2 and 3 before the fix). Not caused by a saved pin: the
owner has none.

| # | Root cause | Fix |
|---|---|---|
| R1 | On every open the notch controller called `revealReadyAnswer()`, which selected `unseenAnswers.first` — the newest answer *never opened*, not the newest answer. With an old "seen" baseline (the owner's is 2026-10-29) every conversation that was never opened queues up, so each reopen showed the next older one. In the installed app FSEvents is live, so no refresh corrected it. | Opening selects `readyAnswer` (newest completed answer by completion time). Unopened answers stay unread in the Inbox and in Project and Session. |
| R2 | An unfinished file hand-off (Copy with Context with files, "Done" never pressed) held its report across every close and blocked following Latest — forever. Seven of these were in the owner's data. | The hold lasts `handoffHoldWindow` (10 min) from the copy; steps saved by earlier versions (no start time) never hold. The hand-off itself is kept and resumes when its report is opened. |
| R3 | An older report read in Details was kept across close with no limit. | Kept for `readingGrace` (90 s, an accidental close), then reopening shows Latest. |
| R4 | A late `show` answer could land on a newer selection when the selection had moved without a new load having started. | `loadDetail` also checks the selection it was started for. |

Rules now (ADR-029): closed island + no pin ⇒ Latest. While the island is
open the report being read is never replaced (unchanged). The only
persistent hold is the deliberate pin ("Stay on the conversation I open" /
`stayOnThisConversation()`); an ordinary pick writes nothing. Home shows
**Pinned** and **Jump to Latest / Follow Latest** in the header whenever the
report shown is not the newest (before: only inside the conversation
switcher).

Order of "newest": `last_turn.answered_at` (the Core's completion time),
never `last_event_at`; equal times fall back to (session key, turn). A
working conversation without final text never becomes Latest; it shows as
working.

### 2.2 `api-v1.schema.json` stayed under "From this turn" with Add (P1)

Reproduced by `Phase17AttachmentTests.theSchemaNamedInTheAnswerIsAttachedAndSelectedWithoutAdd`.

| # | Root cause | Fix |
|---|---|---|
| A1 | `.json` (and `.html`) were offered as suggestions but were not in `ResultAttachments.extensions`, the list of types prepared automatically. | Added `json`, `html`, `htm`. |
| A2 | A file named in the answer but not changed during the turn was deliberately only offered. | Prepared as **named** ("named in the answer, not seen written" — never "written by the agent"), at most `maxNamedExisting` (6) per answer; the rest stay offered as "Named but not verified". |
| A3 | Files were snapshotted when a report was first *opened*, so answers that were never selected (another conversation finishing, a pin) got later bytes, or none. | `prepareNewFinals()`: every new final answer is prepared when it arrives. |
| A4 | A late snapshot could pass newer bytes off as the answer's. | A file modified after the answer arrived (+2 s) is not snapshotted: "Not attached automatically — changed after this answer"; Add takes the current version on purpose. |
| A5 | A skipped file showed a bare Add. | The row says the state: Excluded for safety / Not attachable / Failed to attach / Named but not verified, with the reason. |
| A6 | Found by the new tests: the secret scanner did not match JSON-form credentials (`"api_key": "…"`), in the app and in the Core. | Second "credential assignment" pattern in `SecretScanner.swift` and `sensitive.py`. |

Safety, unchanged or tightened: only supported types; the canonical path
must stay inside the answer's own project/worktree (every path component
opened with `O_NOFOLLOW`, so no symlink leads out); hidden files and
credential-like names never; content with a secret pattern never; size
limits as before; nothing is executed or uploaded — a snapshot is a local
copy. A removed attachment is never recreated and an unticked one never
re-ticked (ledger). Identical bytes under two paths are kept once.
The snapshot keeps its SHA-256 and capture time; the row says "the original
has changed since" when it differs — the hand-off always carries the
snapshot.

### 2.3 Other fixes

* **All Projects with an old plugin stopped capture.** Switching to All
  Projects writes config schema 2, which plugins before 0.8.0 refuse — they
  then store nothing. The switch is now refused with the reason while the
  installed plugin is too old (`requestGlobalCapture`, the setup card).
* **An unknown capture mode from a newer Core** failed the whole project
  list; it now decodes as "unknown" (never "capturing").

## 3. Daily Use (addendum)

**Works without setup** (defaults of a new installation, unchanged for
existing users): Follow Latest on, no pin, result files attached and
selected, new-answer indicators for all projects.

**One setup, the user's own yes** (card on the Set Up page, in Projects,
Settings and the Inbox until answered; later Settings → Daily Use → Set Up…):
Capture all projects · Automatic final screenshots · Include screenshots in
hand-offs. Nothing is applied before **Enable Recommended Daily Use**; Not
Now changes nothing and is not asked again. Setup only switches things on:
an unticked item is left as it is, and repeating setup resets nothing.
macOS's Screen Recording consent and the window picker stay macOS's.

**Readiness** (Settings → Daily Use), from the working state, never from a
toggle: Ready · Setup incomplete · Plugin update required · Permission
required · Window not linked · Capture paused — one sentence, one action
(Resume Capture, Copy Update Commands, Open Screen Recording Settings, Link
Window…, Set Up Agents), Check Again, and the checks behind it (app and
Core, capture mode, plugin version, stored hook events, Latest, result
files, screenshots).

## 4. Settings inventory (from the Swift sources)

Stored in the app's preferences (`UserDefaults`), except capture, which is
the Core's `config.json`. "Restart" = verified by a test that builds a new
object over the same store (`Phase17SettingsTests`, `Phase17DailyUseTests`).

| Setting (Settings label) | Key | Default | Effect | Restart |
|---|---|---|---|---|
| Open on hover | `notch.enabled` | on | resting island opens on hover; off: menu bar / hotkey | ✔ |
| Display | `notch.displayID` | Automatic | which notch display; Automatic removes the key | ✔ |
| Make room for other notch apps | `notch.yieldToOtherNotchApps` | on | open from the menu bar when another app uses the notch | ✔ |
| Stay on the conversation I open | `behavior.staysOnChosenSession` (+ `selection.pinned`) | off | on: a pick pins its conversation. **Follow Latest wins**: it turns this off | ✔ |
| Open at login | system (`SMAppService`) | off | installed Release only | macOS |
| Global shortcuts ×3, modifier keys | `shortcuts.enabled.*`, `shortcuts.modifiers` | off, ⌃⌥⌘ | Inbox / Go To / Next Unread | ✔ |
| Notify when an agent needs input | `notify.needsInput` | off | banner without text; needs notification permission | ✔ |
| Notify when an answer is ready | `notify.whenReady` | off | banner names the project only | ✔ |
| Theme | `appearance.theme` | Warm Cocoa | island colours | ✔ |
| Motion | `notch.animation` | Follow System | Follow System uses Reduce Motion; Reduced: fades only | ✔ |
| Show Relay the bear, Liveliness, Idle moments, Follow the pointer, Relay without a notch | `mascot.enabled`, `relay.*` | on, Subtle, on, on, on | the mascot; sub-settings only apply while the bear is shown | ✔ |
| Capture mode (All / Selected / Paused), project switches, exclusions | Core `config.json` | Selected | what the hooks store; **exclusions and pause win over every mode**; All Projects refused while the plugin is too old | ✔ (Core) |
| Attach result files automatically | `attachments.autoSelectResults` | on | off: files are offered with Add | ✔ |
| Select attached files for handoff *(new)* | `attachments.autoSelectPrepared` | on | off: attached but unticked; shown only while the one above is on | ✔ |
| Automatic final screenshots | `attachments.autoCaptureFinalWindow` | off | on: linked windows are captured after final answers; **off drops every link** | ✔ |
| Include auto screenshots in handoff | `attachments.autoScreenshotsInHandoff` | off | screenshots start ticked; shown only while screenshots are on; remembered while off | ✔ |
| Window links | memory only | none | never stored (ADR-028): gone at quit, re-link in one click | by design ✘ |
| Keep the last 5 copied images | `clipboard.imagesEnabled` (+ `clipboard.noticeAcknowledged`) | asked once | off deletes the kept images | ✔ |
| Daily Use setup answered *(new)* | `dailyUse.setupAnswered` | no | the setup card is not offered again | ✔ |
| Workspace By Project / By Agent, agent profile names, expanded conversations, review marks | `workspace.*`, profile labels, … | By Project | layout and local labels | ✔ |
| Diagnostics: Check Again, copy commands; Privacy: Clear copy history, Clear Temporary Screenshots, Open Screen Recording Settings | — | — | actions, no stored value | — |

Precedence where settings meet: Pause > exclusions > capture mode; Follow
Latest > Stay; screenshots off > hand-off inclusion and links; "Attach
result files automatically" off > "Select attached files". The UI says each
of these in the control's own explanation or in Daily Use.

**Recommended daily-use values:** All Projects (after the plugin update),
attach + select result files on, automatic screenshots on with the Claude
window linked, include screenshots in hand-offs as you prefer, Stay off.
None of this was changed in the owner's installed app.

## 5. API contract

The repository's `docs/api/api-v1.schema.json` is the authoritative schema
and already contains Global Capture (`capture_data`, `settings.capture`,
`excluded`, `minimum_plugin_version`, `resume_mode`). It was **not**
replaced by the older attached snapshot. `tests/test_phase17.py` validates
the Core's real output (projects, sessions, turns, show, context, results,
doctor, capture) against it in every mode and fails if those definitions
disappear; `Phase17ContractTests` decode the current document, a pre-0.8.0
document and an unknown mode in Swift. API v1 and Context Pack v1 are
unchanged; the hook contract is unchanged since 0.8.0, so
`minimum_plugin_version` stays 0.8.0.

## 6. Screenshots

Unchanged rules (ADR-028): a link is a window the user picked in macOS's
picker; never guessed, never the frontmost window, never stored. Verified
in tests: the opt-in persists across restarts; one link serves successive
conversations of the same agent · profile · host · project with no re-link
and no Add; the screenshot is ticked only if the user asked; two
conversations active in that window ⇒ nothing is taken.

**Owner decision needed (not changed):** ADR-028 item 4 treats any
conversation with an event in the last 30 minutes as possibly on screen.
Starting a new chat in the same project shortly after another one therefore
gives "Window association required" until the older one has been quiet for
30 minutes (or the window is linked to the conversation). Narrowing
"active" to "running, or active during this turn" would remove most of
these, at the price of a small chance of a picture of the *other*
conversation of the same project. It is a privacy rule, so it was left as
is.

## 7. Verification

See [STATUS.md](STATUS.md) for the counts of the final run.

| Kind | What |
|---|---|
| Automated, passed | Python 3.14 and 3.9.6 (unit, scenarios, hook, API contract, capture policy, installer); XCTest; Swift Testing; `git diff --check`; secret scan of the diff |
| Real macOS, verified here | real Core + real hook handler through the app model in a temporary data folder (Global Capture, a never-enabled repository, plugin-version gate); real files, symlinks and `O_NOFOLLOW` on APFS; Xcode Debug and Release builds; the packaged app verified by `install-local.sh --no-build --dry-run` |
| Simulated | Screen Recording permission and the window picker (fakes); the island's open/close (model calls, as the notch controller makes them); the installed plugin version (a stand-in record in an isolated HOME) |
| Owner verification required | everything in [PHASE17_ACCEPTANCE.md](PHASE17_ACCEPTANCE.md): the installed 0.9.0 app, real Claude Desktop / CLI sessions, the real Screen Recording prompt, real pointer hover, paste into ChatGPT |
| Not tested | Codex live sessions; an external display; the real plugin update path (`claude plugin` commands are the owner's) |

## 8. Install (owner, after approval)

No Xcode needed. Nothing below was run.

1. App: `~/Projects/prompt-relay-phase16/scripts/install-local.sh --no-build`
   (shows installed vs new, asks, backs up, verifies; `--rollback` undoes).
2. Plugin — it must come from this worktree (today's marketplace points at
   `~/Projects/prompt-relay`, 0.6.0):
   ```bash
   claude plugin marketplace remove prompt-relay
   claude plugin marketplace add ~/Projects/prompt-relay-phase16
   claude plugin install prompt-relay@prompt-relay
   claude plugin list | grep -A2 prompt-relay
   ```
3. Start a **new** Claude Code session (Desktop: new conversation or restart).
4. Prompt Relay → Settings → Daily Use → **Set Up…** → Enable Recommended
   Daily Use (All Projects; screenshots if you want them).
5. Screenshots: open a conversation → Daily Use → **Link Window…**, pick the
   Claude window; allow Screen Recording when macOS asks.
6. Run the ten checks in [PHASE17_ACCEPTANCE.md](PHASE17_ACCEPTANCE.md).

Order matters: plugin before All Projects. If you press Enable first, the
app refuses the switch and says so; capture keeps working as before.

## 9. Remaining risks

1. Real-world behaviour is not verified until the acceptance checks are done.
2. The 30-minute association rule (§6) will still skip screenshots for a
   new chat started soon after another one.
3. Up to six existing files merely named in an answer are attached and
   ticked; an answer that lists files it only read will carry them unless
   unticked ("Select attached files for handoff" off avoids that).
4. Answers that were already in history get their named files prepared when
   first opened, unless the file changed after the answer.
5. `Phase16CaptureTests` says its HOME is isolated, but the app passes the
   Core no HOME, so those tests see this Mac's real plugin record (they do
   not depend on it). The Phase 17 tests pass an isolated HOME explicitly.
