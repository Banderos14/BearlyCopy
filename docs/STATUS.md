# Status

## 2026-11-17 — Plain menu-bar icon steps aside while the bear is at the notch

Owner's screenshot: the bear lay over Prompt Relay's own white menu-bar icon.
That icon (the fallback way in) is now hidden while the bear is drawn beside
the notch (`NotchController.onBearAtNotch`, `MenuBarExtra(isInserted:)`); it
returns when the bear is off, the island yields to another notch app, or the
display has no notch. The island has the menu's actions. Other apps' icons are
not moved (macOS cannot reserve menu-bar room). Test:
`testPlainMenuBarIconStepsAsideWhileTheBearIsAtTheNotch`. Not checked on the
live screen. Two experiments (ears narrowed to content; chin below the notch;
bear as an `NSStatusItem`) were rejected by the owner and are not in `main`
except the narrowed right ear.

## 2026-11-17 — Narrow ears: the resting island covers only what it shows (not released, no version bump)

Owner's screenshot: the black right ear hid the arrow of a menu-bar manager
(`»`) right of the notch, and the bear's ear hid an item left of it. The
resting island now draws only the ears with content: left for the bear (or
the "new answer" bubble), right only while an activity or ready indicator is
shown; the floating pill is unchanged. `NotchLayout.compactFrame(left:right:)`,
regression test `testOnlyEarsWithContentCoverTheMenuBar`. XCTest 389/0 (18
skips), Swift Testing 177, `scripts/check.sh` OK. Not checked on the live
screen. The bear's own 38 pt ear on the left still covers items next to the
notch (a smaller bear needs a new pose budget). Release 0.9.4 not built.

## 2026-11-17 — 0.9.3: install and tour fixes

One-line Terminal installer (`scripts/install.sh`, signer-pinned, no quarantine warning) is the primary install path; DMG steps corrected for macOS 15+ (Open Anyway). The Quick Tour is shown by itself at most twice (a first launch whose island closed at once gets a second chance); Done or Skip ends it. Plugin/app/Core 0.9.3.

## 2026-11-16 — 0.9.2: screenshot mode picker, bear in the tour

Settings → Attachments → Final screenshots: Automatic (recommended) / Manual / Off, so a person with permission or window-link trouble can change it. Quick Tour opens 0.6 s after the first launch; the welcome and bear pages show Relay instead of an icon. Plugin/app/Core 0.9.2.

## 2026-11-16 — 0.9.1: Quick Tour (first-run guide)

Nine-page tour in the island (hover the notch → Quick Tour), shown once on the first launch, reopened from Settings → About → Show Quick Tour or the ⋯ menu. Explains only; changes no setting. Setup welcome text updated for global capture. XCTest 386/0, Swift Testing 177, Python 295+15. Plugin/app/Core 0.9.1.

## 2026-11-15 — Auto window link (ADR-030)

Automatic final screenshots now link the window of the app in front when a
conversation starts working (any app, per conversation). Tests added; real
mouse/window behaviour and Screen Recording: owner.

## 2026-11-15 — QA pass on 0.9.0: notch stays on the MacBook, 10 images, advanced tools hidden

Second monitor as main display: the island no longer falls back to the first
(external) display when macOS reports no notch for the built-in one — the
built-in display wins and its last-seen notch size is restored (test added,
not verified with a real second monitor). Clipboard image history 5 → 10.
The "Export Bundle…" menu item is removed (Context Pack stays; its export
keeps the writer). Capture modes already exist since Phase 16 (`prompt-relay
capture --global`); the parallel ADR-029 attempt was dropped.

## 2026-11-12 — Phase 17.1: Daily Use card and Screen Recording after an update (installed `b2b3eac`, signed)

From the owner's screenshots of the installed 0.9.0: the Daily Use card had
a tall gap and a one-letter column on the right ("Show Checks" squeezed by
three buttons), and "Permission required" stayed although Prompt Relay was
switched on in Screen Recording. Cause of the second: the build was ad-hoc
signed, so for macOS every update is another app and the switch shown
belonged to the previous build. Fixed: compact card (one sentence, numbered
steps, one primary action, small Set Up / Details links), shorter wording
everywhere in Daily Use, the permission state says "off, then on, reopen"
and offers Quit, Check Again clears a remembered refusal after a real
grant. Installed with `install-local.sh --sign "Apple Development" --yes`
(owner asked for the fix): one Release copy, 0.9.0 `b2b3eac`, signed with
the owner's development certificate, so later updates keep the permission.
XCTest 375/0 (16 opt-in skips), Swift Testing 172/172; Python unchanged
since the last check. The card was checked in an offscreen render of the
real view, not in the live island. Still the owner's: switch Prompt Relay
off and on once in Screen Recording for the signed build, then the ten
acceptance checks. The second "Prompt Relay" row in that list (generic
icon) is the Debug build's record.

## 2026-11-12 — Phase 17: daily workflow stabilization, 0.9.0 (built `9e1784e`; **app installed** with the owner's approval, plugin still 0.4.1)

Installed 2026-11-12 with `install-local.sh --no-build --yes`: one Release
copy runs from `~/Applications`, 0.9.0 `9e1784e`; the 0.7.0 app is kept in
`PromptRelay-AppBackups`. Before installing, the owner's real history was
replayed read only through the new selection logic: six opens, the same
newest answer each time. Preferences and capture config were not changed
(Selected mode, schema 1). The ten acceptance checks are still the owner's.
What follows was written before the install.


Branch `phase/17-daily-stabilization` from `1afa08b`. Two owner reports
reproduced by tests first, then fixed. **Older answer after reopening:**
opening the island selected the newest *unopened* answer, not the newest
one; an unfinished file hand-off held its report forever (7 found in the
owner's data, read only); a report read in Details was kept without limit.
Now: closed island + no pin = Latest; hand-off holds 10 min, Details 90 s;
only a deliberate pin persists; "Pinned" / "Jump to Latest" are in the Home
header. **`api-v1.schema.json` with Add:** JSON/HTML were not prepared
types and a file not changed in the turn was only offered. Now result files
are attached and ticked when the answer arrives (all conversations), named
existing files too (≤ 6, honest provenance), with reasons for every skip,
a freshness check and "original changed since". Also: JSON-form secrets
(`"api_key": "…"`) were not detected (app and Core, fixed); All Projects is
refused while the plugin is older than 0.8.0 (before, capture stopped); an
unknown capture mode no longer breaks the project list. New: Daily Use —
one setup (All Projects, screenshots, screenshots in hand-offs; the user's
own press) and a readiness status from the working state. Settings
inventory, API contract tests against the current schema (the older
attached snapshot was not used), ADR-029. Python 295+15 ×2 (3.14, 3.9.6; 1
skip by design), XCTest 373/0 (16 opt-in skips), Swift Testing 172/172,
Xcode Debug/Release 0 source warnings, `git diff --check` clean, packaged
0.9.0 verified (`install-local.sh --no-build --dry-run`). After the last
full run one line changed (a `try?` warning): the two affected suites and
both builds were rerun. At that point: app 0.7.0, plugin 0.4.1 — untouched.
Not verified live: the installed app, real Claude sessions, the real Screen
Recording prompt. Open owner decision: ADR-028's 30-minute association rule
skips screenshots for a new chat started soon after another one.
[Phase 17](PHASE17.md) · [acceptance](PHASE17_ACCEPTANCE.md). Next agreed
stage: owner approves app 0.9.0 + plugin 0.9.0 (plugin first, then All
Projects), runs the ten acceptance checks; then merge into `develop`.

## 2026-11-12 — Global Capture, 0.8.0 release candidate (built `6020544`, **not installed**)

The theatre answer was rejected by the hook (`handler.log`: `Stop …
project_not_enabled`, 2026-11-09 13:32:25 UTC) because that repository was
never switched on; nothing was stored, so it cannot be recovered from
Prompt Relay (Import AI Result is the way to keep it). New capture modes —
All projects (global), Selected projects (default, as before), Paused — with
exclusions that always win, protected locations, fail-closed config (schema
2, refused by plugins before 0.8.0, which then store nothing). Projects are
discovered from stored sessions and grouped by the existing Project
Intelligence. App: capture card with a one-time offer, Pause/Resume in the
menu-bar menu, project switches exclude in global mode, "Plugin update
required" instead of a false "capturing". Python 290+15 ×2 (3.14, 3.9.6),
XCTest 362/0 (16 opt-in skips), Swift Testing 145/145, Xcode Debug/Release
0 warnings, packaged 0.8.0 verified (`--no-build --dry-run`). Installed:
app 0.7.0 (`49ef5d3`, installed by the owner), plugin 0.4.1 — its
marketplace source is `~/Projects/prompt-relay` (0.6.0), so the plugin
needs a re-pointed marketplace ([GLOBAL_CAPTURE.md](GLOBAL_CAPTURE.md)).
Next: owner approves app 0.8.0 + plugin 0.8.0, turns on All projects, and
checks one real answer from an unknown repository.

## 2026-11-09 — Phase 16 pre-install corrections (built `49ef5d3`, **not installed**)

Fixed before the first real install: (1) `--no-build` required the build's
commit to equal HEAD, so the proposed command could not run after a docs
commit — now a build from an earlier commit is accepted only when nothing
the app is built from changed since and the checkout is clean there (tested
in a throwaway repo); (2) the attachment-store lock wrote unprotected when
the lock could not be taken — now fails closed (`lockUnavailable`); (3)
installer: the verified copy is staged before anything is quit, copy/replace
failures reopen the previous app, a failed launch restores and reopens the
previous app (failed one kept as "(failed launch)"), `--rollback` picks the
most recently replaced version by name stamp (not folder time) and keeps all
backups; (4) the time-dependent Phase 12.1 test uses a pinned clock. Python
271+15 ×2 (3.14, 3.9.6), XCTest 358/0 (16 opt-in skips), Swift Testing
145/145 in the full run, Xcode Debug/Release 0 warnings, packaged build
`macos/build/Prompt Relay.app` 0.7.0 `49ef5d3` verified. Install command:
`~/Projects/prompt-relay-phase16/scripts/install-local.sh --no-build`.

## 2026-11-09 — Phase 16: daily-driver release 0.7.0 (branch `phase/16-daily-driver`, built, **not installed**)

Relay bear app icon drawn from `MascotView.shapes`, bundled identically by
Xcode Debug/Release and `scripts/build-macos-app.sh`; bear in the menu bar;
reopening the running app opens the island. Installer hardened (bundled-Core
smoke test, icon/Release-id checks, verified copy before replacing,
automatic put-back, Launch Services registration, launch verified by path,
survival and commit, Debug copy asked never killed, `--status`/`--tidy` for
the 0.2.0/0.3.0 copies found inside `~/Applications`, `--system`, `--sign`,
`Update Prompt Relay.command`). Fixed: Add under "From this turn" could do
nothing visible (duplicate bytes, errors below the fold, unattachable
kinds); S8 confirmed as a real lost update between two running copies and
fixed with a cross-process lock. Python 262+15 ×2 (3.14, 3.9.6; +13
isolated installer tests), XCTest 358/0 (16 opt-in skips), Swift Testing
143/144 in the full run — the one failure is a pre-existing time-based Phase
12.1 test that stalled 33 s under load and passes 3/3 alone; Xcode Debug and
Release BUILD SUCCEEDED, 0 compiler warnings; packaged build verified by
`install-local.sh --dry-run`; isolated launch probe 0.16 s, ≈83 MB, 0 % idle
CPU. Installed app still 0.4.1, plugin 0.4.1. [Phase 16](PHASE16.md) ·
[acceptance](PHASE16_ACCEPTANCE.md). Next agreed stage: owner approves the
install (and optionally `--tidy`, `--sign "Apple Development"`), then runs
the 15 acceptance checks (Phase 17: acceptance and closure only).

## 2026-11-08 — Phase 15.2: product audit as a new user, screenshot reliability, safe Debug switch (not installed)

Observed snapshot: an old Xcode Debug copy (`17844fe`, bundle id `.debug`,
display name "Prompt Relay Dev") and installed Release 0.4.1 both running,
both **ad-hoc signed**; plugin 0.4.1. Fixed: **R1 (P1)** — any non-permission
capture error removed the window link, so a minimized/other-Space window lost
it; now dropped only when macOS no longer lists the window ("Window closed"),
else kept ("Window not available right now" / "Capture failed"); **Open
Screen Recording Settings** in every no-screenshot state (pane verified:
`Privacy_ScreenCapture` = record your screen, never audio-only); "Window not
linked" explains links end at quit and Link vs Capture Now; Debug hint names
"Prompt Relay Dev" and the ad-hoc rebuild pitfall; About explains plugin vs
app versions; new `scripts/run-latest-debug.sh` (dry run default, `--build`,
`--switch` with normal Quit only). XCTest 358/0 (16 skips), Swift Testing
132/132 (+9), Python 249+15 ×2, Xcode Debug/Release 0 warnings. Nothing
installed, quit or switched. [15.2 audit](PHASE15_2_PRODUCT_AUDIT.md) ·
[owner guide](PHASE15_2_OWNER_GUIDE.md). Next agreed stage: owner runs the
switch (guide §A) and acceptance rows 1–39; then merge into `develop`.

## 2026-11-08 — Phase 15.1: evidence classification corrections (branch `phase/15-mvp-readiness`, not installed)

Four review findings, each confirmed in the code first: (1, P1) a piped or
`;`-chained test/build (`swift test | tee log`, `pytest | tail -20`,
`swift build; echo done`) counted as passing on exit 0 — now "result
unknown"; (2) Failure Inspector still said "the build did not succeed" for
`swift build && swift test` where the failing step is unknown; (3) a grep
exit 1 raised an alarm and a "run the build" checklist item; (4) withheld
compound lines were trusted. One shared rule (`FailureBreakdown.stageResult`:
passed / failed / unclear, with `&&`, `set -o pipefail`, `;`, `|`, setup
stages) now feeds Failure Inspector, Evidence Check, the chip, Quick Peek
and the Commands row; Core, Copy with Context text and JSON API v1
unchanged. Python 249+15 ×2, XCTest 358/0 (16 opt-in skips, +9), Swift
Testing 123/123, Xcode Debug/Release 0 warnings, `git diff --check` clean,
five mutation checks. Second backup in
`~/Backups/PromptRelay/2026-11-08-phase15.1/`. Nothing installed or merged.
[Audit §7](PHASE15_AUDIT.md) · [tests](PHASE15_TEST_RESULTS.md) ·
[Git](PHASE15_GIT_RECOVERY.md). Next agreed stage: unchanged (see below).

## 2026-11-07 — Phase 15: Git recovery, independent audit, MVP readiness (branch `phase/15-mvp-readiness`, not installed)

Git: the latest work (`17844fe`) existed only on this Mac — GitHub had the
Phase 4-era `f72a8ce`. Private verified bundle of all 27 refs plus the
owner's staged/untracked acceptance files in
`~/Backups/PromptRelay/2026-11-07-phase15/`; new `develop` = `17844fe`
pushed; Phase 15 work on `phase/15-mvp-readiness` in the worktree
`~/Projects/prompt-relay-phase15`; `main` and the legacy branch untouched;
the main checkout's staged/untracked files left exactly as found
([Git recovery](PHASE15_GIT_RECOVERY.md)). Audit of Phases 14–14.2: every
reported count reproduced (XCTest 339/0/16, Swift Testing 123/123, Python
249+15 ×2). Fixed: **D1 (P1)** review marks were pruned in hash order, so
past 200 marked answers a fresh tick could vanish — now kept by recency;
**D2 (P1)** `swift build 2>&1 | grep …` on a clean build read "1 build
failed" — now "1 build unclear", grep/diff non-matches "1 likely not an
error", quotes and `2>&1` no longer split a line; **D3** SECURITY.md wrongly
said no Screen Recording is used; **D4** two compiler warnings. Four weak
Phase 14.2 tests strengthened (one asserted nothing). After: Python 249+15
×2, XCTest 349/0 (16 opt-in skips, +10), Swift Testing 123/123, Xcode
Debug/Release 0 warnings, `git diff --check` clean, two mutation checks.
Nothing installed; installed app/plugin still 0.4.1. Live GUI, permissions
and ChatGPT paste: owner ([MVP acceptance](PHASE15_MVP_ACCEPTANCE.md)).
[Audit](PHASE15_AUDIT.md) · [tests](PHASE15_TEST_RESULTS.md) ·
[handoff](PHASE15_HANDOFF.md) · [next chat](PHASE15_NEXT_CHAT_PROMPT.md).
Next agreed stage: owner reviews Phase 15, merges it into `develop`,
decides on installing 0.6.0 + Phase 15 (consent) and runs the MVP
acceptance; deleting `claude/loving-mccarthy-ossw3q` only on the owner's
yes; Phase 16 only after approval.

## 2026-11-07 — 0.6.0 addendum: accurate verification, failure classification, compact Copy with Context (not installed)

Three real bugs from using Prompt Relay on itself. (1) The Answer chip's
"not verified" count was `EvidenceCheck`'s own fixed claim list, never
affected by the four Review Checklist ticks — a new `reviewProgress` ("N
checks left" / "All checks completed") tracks the user's own progress
separately and updates immediately; checklist rows now say Pending /
Checked by you / Not applicable (CI only) explicitly, and a tick is never
promoted to "Confirmed locally". (2) "1 failed" conflated a diagnostic
shell command with a test or build failure — confirmed from this session's
own captured turn 4 (a `plutil`/`grep` exit 1, `kind: "other"`, amid
passing builds and tests); a new `FailureBreakdown` names commands, tests
and builds separately everywhere a failure count is shown. (3) Copy with
Context showed one row and "+4 more" at common compact heights with slack
left in its own row's budget (`PairedRows`' cap used only Task's height,
never informed by how little the Answer actually needed); it now floors at
two rows of the right card when the existing budget allows it, without
growing the island — measured with real `IslandHost` layout at 268–568 pt,
not arithmetic. XCTest 339/0 (16 opt-in skips, +20 new), Swift Testing
123/123, Python 249+15 ×2 (3.14, 3.9), Xcode Debug/Release, `git diff
--check` clean, two mutation checks confirm the new logic is exercised.
Fixed a doc error: window links (Auto Final Screenshot) do not survive a
restart, contrary to a line in `ACCEPTANCE_PHASE141_PERMISSION.md`. Version
stays 0.6.0 (not installed/published). [Phase 14.2](../macos/PHASE14.2.md),
[ACCEPTANCE_PHASE14.2](../macos/ACCEPTANCE_PHASE14.2.md).

## 2026-11-07 — 0.6.0 addendum: one-click Screen Recording permission recovery (not installed)

"Auto screenshot needs permission" now offers Open Screen Recording Settings
(the pane verified on this Mac, with fallbacks) and Check Again directly in
Attachments — never reading Settings having opened, or the non-prompting
system API alone, as "granted": Check Again also attempts one real, discarded
capture of the linked window. A mismatch (API says granted, capture still
denied) shows "Restart required" with a plain Quit action and no state loss;
a closed window is never reported as a permission problem; Debug and Release
builds have separate bundle ids and therefore separate, never-confused
authorization records (verified via `codesign -dv` on both running copies).
Still 0.6.0 (not installed, so no new version number). XCTest 319/0 (16
opt-in skips, +15 new), Swift Testing 123/123, Python 249+15 ×2 (3.14, 3.9),
Xcode Debug/Release, `git diff --check` clean, mutation check on the new
logic. Which System Settings pane actually opens and the Debug-granted /
Release-still-blocked scenario: owner
([ACCEPTANCE_PHASE141_PERMISSION](../macos/ACCEPTANCE_PHASE141_PERMISSION.md)).
[Phase 14 §7](../macos/PHASE14.md).

## 2026-11-07 — 0.6.0 (Phase 14.1): hover-resize without a click trap; ready to install (not installed)

The island now shrinks its window at once; the strip it leaves is a short
"corridor" (bounded mouse monitor) where resting or moving keeps it open,
and a click there reaches the app below and closes it. Auto screenshot: one
more scenario (two finals in one refresh). App, Core and plugin at 0.6.0;
JSON API v1 and Context Pack v1 unchanged; hooks unchanged since 0.4.1.
XCTest 304/0 (16 opt-in skips), Swift Testing 123/123, Python 249+15 ×2
(3.14, 3.9), Xcode Debug/Release, `git diff --check` clean. Two tests that
read the real mouse button / system clipboard failed once in a full run
while the Mac was in use; they now use injected state. Installed app still
0.4.1, plugin 0.4.1, Xcode Debug copy running. Install and plugin update:
owner's consent ([ACCEPTANCE_0.6.0](../macos/ACCEPTANCE_0.6.0.md)).

## 2026-11-06 — Phase 14: no clipped rows, island stays open on resize, auto screenshots (not installed)

Fixed and covered by tests that failed before: Copy with Context rows and
the Answer's last line are never half visible (scroll viewport ends on a
row/line boundary, "+N more"); the island no longer closes when a view needs
less height (the smaller window frame waits until the pointer is on the
island; a real exit still closes it). Automatic final screenshots extend the
Phase 9.4/10 pipeline: windows linked per agent · profile · host · project
(or one conversation) in macOS's picker, captured once per new final answer
after a short settle check, never when another active conversation could be
in that window ("Window association required"); memory only, unchecked
unless "Include auto screenshots in handoff" is on (ADR-028). Results:
XCTest 302/0 (16 opt-in skips), Swift Testing 122/122, Python 249+15 ×2 (3.14, 3.9), Xcode Debug/Release BUILD SUCCEEDED, `git diff --check` clean. Live mouse, Claude Desktop timing, permissions and displays:
owner ([ACCEPTANCE_PHASE14](../macos/ACCEPTANCE_PHASE14.md)). Proposal:
0.6.0 for App, Core and plugin before the next install (not applied).
[Phase 14](../macos/PHASE14.md). Next agreed stage: owner install (consent)
and Phase 14 checks; MCP not started.

## 2026-11-06 — 0.5.0 ready to install (not installed)

App, Core and plugin at 0.5.0 (`e245bfe`); JSON API v1 and Context Pack
format v1 pinned by the version test. Fixed: documents the user adds to a
pack are secret-checked; Copy Files and Drag wait for the same yes as the
text, Export stays refused. Python 249+15 ×2 (3.14, 3.9), XCTest 291/0 (16
opt-in skips), Swift Testing 102/102, Xcode Debug/Release, `git diff
--check` clean; `install-local.sh --dry-run` verified (0.5.0 = Core, digest,
commit, no `.pyc` in the bundle). Installed app still 0.4.1; Xcode Debug
copy still running. Install, plugin update and live checks:
[ACCEPTANCE_0.5.0](../macos/ACCEPTANCE_0.5.0.md) — owner's go-ahead needed.

## 2026-11-06 — Phase 13: multi-result Context Packs, Handoff History (not installed)

Choose results in the Inbox (`+`), order them, add your own review
instructions and a receiver, Prepare: one Markdown pack, one verbatim
section per result (Core `context-pack`, Copy with Context sections one
level deeper), attachments with availability, manifest without paths or ids
(format v1, docs/CONTEXT_PACK.md, ADR-026). Copy Text → Copy Files / Drag →
Export; snapshots stay image data; History records Prepared / Copied /
Drag started / Exported, never delivery. MCP still a design (ADR-027).
Python 249+15 ×2 (3.14, 3.9), XCTest 290/0 (16 opt-in skips), Swift Testing
102/102, Xcode Debug/Release. Real pastes into AI apps and the Phase 12.2
checks: owner. 0.5.0 proposed, not applied. [Phase 13](../macos/PHASE13.md).
Next agreed stage: owner install (consent) and checks; Phase 14 only after
approval.

## 2026-11-06 — Phase 12.2: first-interaction Drag, live Needs Input

Drag from the hover-opened (non-key) island failed on the first press: the
AppKit drag source kept `acceptsFirstMouse == false`, so the press only made
the panel key. Fixed locally on the drag source (first mouse, delayed window
ordering, 3 pt threshold), reproduced and verified on the real panel event
path. AskUserQuestion, ExitPlanMode and an allowed permission confirmed with
real events in Claude Desktop; a question's own PermissionRequest no longer
changes its kind. Scroll tests: locked screen confirmed as the cause; now
skipped as "environment blocked". XCTest 278/0, Swift Testing 102/102,
Python 232+15 ×2, Xcode Debug/Release. Not installed (consent pending).
[Phase 12.2](../macos/PHASE12.2.md).

## 2026-11-06 — Phase 12.1 acceptance: 0.4.1 installed, live waits not yet observed

Fixed: subagent `<agent-message>` reports are automated messages in Copy
with Context; unconfirmable waits shown as "May need input" (never removed by
time). App 0.4.1 `0dffa80` and plugin 0.4.1 installed with consent (backups
kept). Isolated live probe confirmed the installed hook and real
UserPromptSubmit/SessionEnd fields; the CLI login had expired, so question,
plan and permission events are still documented-only. Two scroll tests need
an unlocked screen. [Phase 12.1 §9](../macos/PHASE12.1.md).

## 2026-11-05 — Phase 12.1: Needs Input (0.4.1, not installed)

Observer hooks for AskUserQuestion, ExitPlanMode, PermissionRequest,
waiting notifications and SessionEnd (exit 0, no decision, no text stored);
`attention` per session ended by the next confirmed activity, never a timer;
static amber notch dot, "Needs input" in Quick Peek / Details, optional
notification (off). Python 228+15 (3.14, 3.9), XCTest 271/0, Swift Testing
98/98, Xcode Debug/Release. **No live hook payload observed yet**; installed
app and plugin still 0.4.0. [Phase 12.1](../macos/PHASE12.1.md).

## 2026-11-05 — 0.4.0 installed for live acceptance

With the owner's consent: app 0.4.0 `e75cdd5` installed (0.3.0 backed up,
rollback available), Claude Code plugin updated 0.3.0 → 0.4.0 from a clean
`plugin/` (byte-identical to HEAD, settings.json unchanged). The old plugin
cache turned out to be the 2026-10-29 snapshot. Live checks pending; restart
Claude Code sessions; stop the Xcode Debug copy. [Phase 12 §18](../macos/PHASE12.md).

## 2026-11-05 — Version 0.4.0; Phase 12 closed on the code side

Core, plugin and Xcode at 0.4.0 (`7db1e4b`), JSON API still v1. Python
213+15 (3.14, 3.9), XCTest 271/0 failures, Swift Testing 90/90, Xcode
Debug/Release, plugin manifests valid, install dry-run verified (0.4.0 =
Core, digest, commit). Claude Code still runs plugin 0.3.0 (no profile
capture until the owner runs `claude plugin update`); app not installed.
Both wait for the owner's consent: [Phase 12 §17](../macos/PHASE12.md).

## 2026-11-05 — Phase 12 acceptance pass

Inbox now separates Finished from **Needs attention** (completion unknown:
own section and filter, never unread or Latest; history kept). Final code
`88a1e73`: XCTest 271/0 failures (16 skipped), Swift Testing 90/90, Python
212+15 on 3.14 and 3.9, Xcode Debug/Release, `git diff --check` clean;
`install-local.sh --dry-run` verified, nothing installed (owner consent
pending). Proposal: raise to 0.4.0 before the live-check install. Manual
checks and closure: [Phase 12 §16](../macos/PHASE12.md). Phase 13 not started.

## 2026-11-05 — Phase 12: multi-agent workspace, Results Inbox, daily workflow

Local agent profiles = the agent's config folder (`CLAUDE_CONFIG_DIR`,
`CODEX_HOME`), stored in the record envelope (payload verbatim); never an
account, no credentials read (ADR-023). Equal native ids from two folders
never share a history; old Claude Code records read as Unassigned, old Codex
records map by `installation_id`; nothing rewritten. New read-only Core
command `results`. App: By Project / By Agent, Results Inbox with per-result
read state, Go To (⌘K), ⌘I / ⌘J, optional global shortcuts (off by default),
Follow Latest never replaces the answer being read, Open at Login via
SMAppService (off by default, installed Release only, ADR-024), "What can be
trusted?" card with the old Evidence sections under Details. Tests and
offscreen renders only — **nothing verified in the live GUI**; installed app
not updated; nothing pushed. Details and owner checks:
[Phase 12](../macos/PHASE12.md). Next agreed stage: owner live checks of
Phases 11–12; Phase 13 (Universal Handoff) only after approval.

## 2026-11-05 — Phase 11: installable app, first-run setup, release preparation

`scripts/install-local.sh` builds, verifies (signature, version = Core,
Core digest, commit = HEAD), backs up, installs to `~/Applications`, opens
and checks one running copy; `--dry-run`, `--status`, `--rollback`.
Settings → About shows commit, build date, location, Core and mismatches
with the installed app. Release scripts for Developer ID + Hardened Runtime
+ notarization exist; only an ad-hoc `--unsigned-test` package was built (no
Developer ID certificate on this Mac). Python stays a checked system
dependency (ADR-019). New Set Up page: per agent and host status, Connected
only after a stored event (ADR-021). Settings regrouped; 11 pt text floor,
24 pt menus, unified radii. Tests no longer create real UserDefaults suites
(0 new plists per run). MCP evaluated, deferred (ADR-022). Details and the
owner's live checks: [Phase 11](../macos/PHASE11.md). Installed app **not**
updated; nothing pushed.

## 2026-11-05 — Phase 10: audit, in-memory window snapshots, minimal notch status

Window snapshots (Capture Final Window, opt-in auto-capture) are now kept in
memory only: listed and selected like any attachment, copied and dragged as
image data, never written to the attachments folder, index or hand-off
folder, bounded (12 / 96 MB / 4 h) and gone at quit; export writes them only
into the folder the user picks. The notch shows one green dot without a
number and clears it when the island is opened; other conversations stay
unread in Project and Session. Test runs no longer leave plists in
`~/Library/Preferences`. Product, technical, UX, privacy and release audit
with roadmap and Phase 11 proposal: [Phase 10](../macos/PHASE10.md). Picker,
consent and paste into other AIs are **not verified live**; installed app
not updated.

## 2026-11-05 — Phase 9.4 completed (final-only UI, dots, Details, host, conversations)

Intermediate Stops no longer appear as answers anywhere (carousel/counter,
History, search, Copy Answer, counts); one user task with several technical
turns shows one final answer. Animated Core Animation dots while working or
waiting, a small green dot only for a final answer. Hover reopens Details
after an automatic close; "Quick Peek" returns. Claude host from
`CLAUDE_CODE_ENTRYPOINT` (needs the owner's plugin update to reach Claude
Code). Project and Session: expandable conversations with their final
answers. Capture Final Window via the system picker (not tried live).
Details: [Phase 9.4](../macos/PHASE9.4.md). Nothing installed.

## 2026-11-05 — Phase 9.4 (sections 0–2): intermediate Stops, attachments without Add

A Stop that reports running `shell`/agent work is no longer an answer: the
Core's new `completion` marks it `waiting_background` or `intermediate`
(Claude Code 2.1.268 continues in a new `<task-notification>` turn, observed
on this Mac); only the follow-up final answer becomes Latest, lights the
green dot and is announced once. Waiting ends after 2 h as "Completion
unknown". `show` gains `work_chain`, so files written before the background
wait are auto-prepared with the final answer — no Add, no Details. The task
text received ended inside section 2; later sections were not received.
Details: [Phase 9.4](../macos/PHASE9.4.md). Installed app not updated.

## 2026-11-05 — Phase 9.3: one Latest across agents, logical projects, smart attachments

Latest now follows the newest *completed* answer with text from Claude Code or
Codex (`last_turn.answered_at`); the provider filter that blocked it is gone.
Pinning is an explicit Behavior setting ("Stay on the session I choose"), off
for new installs; an existing saved pin is migrated to On and kept, with
Follow Latest / Jump to Latest one click away. An unfinished file hand-off
holds its report. The Core reports a `logical_project` (enabled project → Git
root → workspace → folder, stat only), so `prompt-relay/macos` joins
`prompt-relay`. Named result files that changed during the turn are
auto-selected as "named · changed this turn". Short continuations keep their
request and get labelled earlier-task context. Details, checks and limits:
[Phase 9.3](../macos/PHASE9.3.md). Installed app not updated (owner consent
needed). Earlier checkpoints below are historical.

## 2026-11-04 — Phase 9.2 delivery diagnosis

Real Xcode UserPromptSubmit/PostToolUse now reach storage and Swift AppModel
without changing hooks or trust. Two sessions show `Codex · Xcode · This Mac`;
no completed Stop/answer is verified yet. A running installed pre-Codex build
misclassified the same stored sessions; fresh Core recognizes them. Fixed stale
integration status refresh, added source-specific metadata diagnostics and
recognized successful Xcode write results with absolute paths. Python 3.14/3.9,
Swift regressions and Xcode build passed. Full live acceptance remains pending
one completed owner smoke, not another hook installation. See
[Phase 9.2](../macos/PHASE9.2.md). Earlier checkpoint below is historical.

## 2026-11-04 — Phase 9.1 acceptance checkpoint

Phase 9 implementation is committed through `1686384`. Phase 9.1 confirms the active Xcode CODEX_HOME, absent Relay hook configuration and zero recorded Codex sessions. Preview succeeded; owner consent to profile changes and real hook trust/session delivery remain pending. Real Xcode and CLI capture are **not verified**. Integration status UI now distinguishes installed adapter, hook definitions and recorded events. Relevant Swift tests, Python regressions and Debug/Release builds pass; interactive live acceptance remains open. See [Phase 9.1](../macos/PHASE9.1.md) and [Phase 9](../macos/PHASE9.md). No Phase 10 work.

## Earlier status (retained)

Last updated: 2026-10-31, local Mac session (Phase 8 committed on the branch, owner validation pending),
branch `claude/loving-mccarthy-ossw3q`.

## Completed
- **Phase 0 — research & architecture**: docs, ADR-001…005, hook schema
  research, data model, threat model, UI foundation research.
- **Phase 1 — cloud-verifiable part**: hook handler, JSONL store,
  correlation, CLI (show / copy / context / copy-context / sessions / turns
  / enable / disable / delete / hook-config / doctor), and automated tests.
- **Core self-review** (`docs/SELF_REVIEW.md`): 14 confirmed defects fixed in
  `1d71087`, each with a regression test. The suite now has 79 tests.
- **Phase 1.5 — Mac validation, partial** (`docs/LOCAL_MAC_VALIDATION.md`
  §10): the main path **Claude Desktop → Stop hook → Prompt Relay → system
  clipboard** passed on a real Desktop run. Remaining checks are listed under
  "Requires macOS validation" below.
- **Phase 2A — Cloud Core for the app** (cloud): JSON API v1
  (`docs/JSON_API.md`, schema, ADR-006), 13 golden cases including the
  redacted real payloads, history management (`retention`, `prune`, `delete`
  preview/confirmation, active-session protection, ADR-007), storage path
  hardening. Two defects fixed with regression tests: the unlink race
  (a hook waiting on the lock of a deleted file lost its event) and a
  damaged duplicate line crashing an append. 105 tests.
- **Phase 2B — Claude Code plugin** (cloud; **main Mac check passed**
  2026-10-29, LOCAL_MAC_VALIDATION §11): plugin
  package `plugin/` plus a marketplace at the repo root (ADR-008,
  `docs/PLUGIN.md`), a POSIX launcher with interpreter pinning
  (`pin-python`, auto-pinned by `enable`), read-only `doctor --json`
  diagnostics (plugin records, settings hooks, double registration, observed
  `via=`), and the Core moved to `plugin/prompt_relay`. One defect found by
  the new tests and fixed: the launcher could not resolve its own directory
  with a minimal `PATH`. 137 tests.
- **Phase 3A — native macOS app** (Mac): SwiftUI + AppKit menu-bar app in
  `macos/` (ADR-009, `docs/MACOS_APP.md`): projects, sessions and answers,
  full verbatim answer, Copy Response / Copy Context through NSPasteboard
  with read-back confirmation, connection status from `doctor --json`, empty
  and error states, FSEvents live updates with a fallback. Integration only
  through the JSON API v1; the Core is bundled into the app. 39 Swift tests.
  The Python Core was not changed.
- **Phase 3B — notch UI and Xcode foundation** (Mac; accepted by the owner
  on the real screen): Dynamic-Island-style island around the MacBook notch
  (custom NSPanel + SwiftUI, ADR-010, `docs/MACOS_APP.md` §2B) over the same
  AppModel; Settings; "answer ready" indicator; coexistence with Coucou;
  `macos/PromptRelay.xcworkspace` with a Debug/Release app target and
  Previews. The first design was rejected in review (too large, window-like)
  and redesigned; a grey shadow halo found in review was removed with a
  regression test. 70 Swift tests. Python Core, plugin and JSON API unchanged.

## Verification matrix
### Verified in Cloud (real code, real processes, Linux)
| Item | Evidence |
|---|---|
| Hook handler: stdin parsing (any key order), event filter, allowlist, exit 0, empty stdout | `test_s01`…`test_s18`, `HookUnitTests` |
| Verbatim storage of Unicode, Markdown, nested fences, >100 KB, CRLF, NUL, lone surrogates | `test_s08`, `test_s09`, `test_lossless_roundtrip…` |
| Session separation, prompt_id linking, sequence/ambiguous labeling | `test_s02`, `test_s03`, `test_s12`, `CorrelationTests` |
| Duplicate delivery, concurrent writers (12 processes), crash-truncated line recovery, lock timeout | `test_s04`, `test_s05`, `test_s18` |
| Storage unwritable → handler exits 0 within bounds | `test_s11`; `test_s11b` passes as non-root (`nobody`) and is skipped as root |
| Background tasks and API-error statuses; API error never exported as a response | `test_s13`, `test_s14` |
| Copy Context: provenance labels, fence escaping, secret-scan blocking, read-only git (`.git` unchanged) | `ExportTests` |
| No network constructs in sources; sockets patched to fail during hook + all export commands | `test_s16`, `SourceSafetyTests` |
| No captured text in the repository or in `git status` | `test_s17` |
| Python 3.9 compatibility (macOS CLT version) | full suite on 3.9.25 and 3.13.17 |
| Documented hook schemas (all documented fields, three JSON encodings, verbatim, single storage) | `SchemaConformanceTests` |
| Hook entry point exits 0 when the package or Python is unusable | `test_hook_entry_point_exits_zero_when_package_missing` |
| Concurrent `enable` without lost updates | `test_concurrent_enable_keeps_every_project` |
| Repo-configured `core.fsmonitor` not executed during git collection | `test_repo_configured_fsmonitor_is_not_executed` |
| Hook latency | `scripts/check.sh`: median 72.6 ms, p95 88.2 ms (cloud VM, 20 KB payload) |

| JSON API: one ASCII document, empty stderr, schema-valid, `ok` ⇔ exit 0, usage errors as JSON, lossless Unicode | `test_api.JsonApiTests`, every golden query |
| Golden cases (13) incl. real Desktop/CLI payloads | `test_api.GoldenTests` |
| History management: preview by default, `--yes`, retention never automatic, active protection, changed-since-plan kept | `test_api.HistoryManagementTests` |
| Path safety: symlinked files/`events/` refused, foreign names ignored, nothing outside `events/` deletable | `test_api.PathSafetyTests` |
| Concurrent hooks + deletes: no lost event, no corruption | `test_concurrent_hooks_and_deletes_never_corrupt`, `test_hook_waiting_for_lock_survives_concurrent_delete` |
| GitHub Actions (Linux, Python 3.9 + 3.13) | green up to `7ef3368` (Phase 2A); Phase 2B run: see the final report |
| Plugin package accepted by the **real Claude Code 2.1.312 parser** | `claude plugin validate plugin --strict --json` (no errors, no warnings), marketplace validates, `claude --plugin-dir plugin plugin details` → "Hooks (3) UserPromptSubmit, Stop, StopFailure", ~0 tokens. Isolated HOME, no install, no API call (`ClaudeCliValidationTests`) |
| Plugin launcher: verbatim capture from a root with spaces/Unicode, cwd-independent, pin fallback, no-Python exit 0, missing package exit 0, `PYTHONPATH` injection ignored, root change after update keeps history | `test_plugin.LauncherTests` (launcher run as `/bin/sh <root>/hooks/run-hook`, like Claude Code) |
| Plugin + settings hook at the same time → event stored once | `test_double_registration_stores_each_event_once` |
| Foreign (NotchBuddy-like) hooks: counted, never printed, settings bytes unchanged | `test_plugin.CoexistenceAndDiagnosticsTests` |

Test run, Phase 2B (2026-10-29, cloud): Python 3.13.17 — 137 run, OK,
1 skipped (root-only permission test); Python 3.9.25 — 137 run, OK,
1 skipped; as user `nobody` — 137 run, OK, 0 skipped. Failures: 0.
Hook latency: `bin/prompt-relay hook` median 72.5 ms, plugin launcher median
88.0 ms, p95 106 ms.

### Verified on macOS (2026-10-29, real Mac, real Claude Desktop)
| Item | Evidence |
|---|---|
| Environment | macOS 27.0.1 arm64 M3 Pro; Python 3.9.6 (Xcode), 3.11.14, 3.14.0; CLT installed; CLI 2.1.268; Desktop 4.29.0 with Claude Code 2.1.309 (D4) |
| Automated suite | 81 tests (79 + 2 added in Phase 1.5), OK, **0 skipped**, on all three Pythons. First run found one test defect (`test_s17` hard-coded the Linux data path), fixed |
| Real clipboard, byte-exact | 11 cases incl. Cyrillic, emoji/ZWJ, Markdown, nested fences, CRLF, C0 controls, **NUL (D5: preserved)**, 1.18 MB; read back via `pbpaste` and NSPasteboard |
| Real Desktop hooks | UserPromptSubmit + Stop fired from the sandbox `.claude/settings.local.json` and were stored in the isolated data dir |
| `prompt_id` on Stop (D1) | present and equal to the prompt's → `link=prompt_id` |
| Full final response | Stop `last_assistant_message` equals Claude's final text in the session transcript, byte for byte |
| `agent_id` on a main turn (D6, partial) | absent on both events of a main-session turn |
| CLI shows the right session and text; `copy --verify` | passed on the captured Desktop answer (real pbcopy) |
| Real CLI UserPromptSubmit | stored via `claude -p --settings`; `prompt_id` present |
| Data isolation | `hook-config --data-dir` keeps Desktop hooks in the validation dir; the default data dir was never created |
| Hook latency | median 37.1 ms, p95 39.3 ms |
| `~/.claude/settings.json` unchanged | SHA-256 identical before and after; other tools' global hooks untouched |

Real payloads (redacted) are fixtures: `tests/fixtures/real_*.json`.

### Verified on macOS — Phase 2B plugin (2026-10-29)
| Item | Evidence |
|---|---|
| Phase 2A + 2B suite on macOS | 137 tests on 3.9.6 / 3.11.14 / 3.14.0, OK, 1 skipped by design (no-Python path, covered on Linux); `ClaudeCliValidationTests` ran against CLI 2.1.268 |
| Official install from the local marketplace | `claude plugin marketplace add` + `install`, scope user; `details`: 3 hooks |
| Desktop → plugin → Stop → storage → copy → clipboard | `via=plugin` UserPromptSubmit + Stop, same `prompt_id`, full final text, `copy --verify` passed |
| No double write | 2 records, no `duplicate`; Prompt Relay ran once per event (`stop_hook_summary`) |
| Coexistence with NotchBuddy | both ran on Stop, `hookErrors: []`; `hooks`/`permissions` in `~/.claude/settings.json` identical |
| Launcher interpreter | pinned Xcode Python 3.9.6 used (`doctor`: hook python ok) |

### Verified on macOS — Phase 3A app (2026-10-29)
| Item | Evidence |
|---|---|
| Build | `scripts/build-macos-app.sh` (Xcode 27.0, Swift 6.4, macOS SDK 27.0), ad-hoc signed; signature still valid after use (`-B`: no bytecode in the bundle) |
| Swift tests | 39 run, 0 failures, 1 opt-in render test skipped by default |
| Real Core from the app | integration tests against the checkout's Core with a temp data dir; the bundled Core lists the real session |
| Real history in the UI | offscreen renders with the user's history (read-only): the Phase 2B plugin answer, status screen with 5 `via=plugin` events |
| Owner's check | menu-bar icon opens the panel; **Copy Response** copied the answer; ⌘V pasted it without loss |
| Idle cost | 0 % CPU, ≈120 MB RSS |

### Verified on macOS — Phase 3B notch UI (2026-10-29)
| Item | Evidence |
|---|---|
| Xcode | workspace scheme "Prompt Relay": Debug and Release BUILD SUCCEEDED; `xcodebuild test`: 70 tests, 0 failures (1 opt-in render test skipped) |
| `swift test` | 70 tests, 0 failures, stable across repeated runs |
| Real panel geometry | Debug capture on the built-in display: resting 185 × 32 at the notch; expanded 400 × 142 = the island; back to 185 × 32; nothing on the external display |
| No halo | only black and transparent pixels around the island (264 anti-aliased edge pixels); `NotchAppearanceTests` fails if a shadow returns |
| Idle cost | notch on: 0 % CPU, ≈119 MB RSS, no Python in 30 s of sampling; notch off ≈118 MB |
| Owner's visual check | island opens from the physical notch; geometry and look correct; no grey halo; answer shown in the notch and main window |

### Verified with Mocks
| Item | Mock |
|---|---|
| Copy Response / Copy Context to the clipboard, byte-exact, `--verify` read-back | file MOCK clipboard (`PROMPT_RELAY_CLIPBOARD=file:…`) |
| pbcopy invocation: exact argv, UTF-8 bytes, UTF-8 locale, no shell | `subprocess.run` patched (`test_pbcopy_backend_sets_utf8_locale`) |
| macOS default data path | `paths.data_dir(platform="darwin")` |
| Same directory under another spelling (case-insensitive APFS) | `os.stat` patched (`test_enabled_project_matched_by_identity`) |
| Hook payloads | synthetic fixtures copied from the documented examples, not captured from a real Claude run |

### Implemented, requires macOS validation
| Item | How to validate |
|---|---|
| Manual ⌘V paste of a copied answer into another app (TextEdit) | M2 — not done: the clipboard was overwritten before pasting |
| CLI Stop (`claude --settings`) | M3 — blocked: the CLI's OAuth session had expired (log in first) |
| Interrupt with Esc → no Stop, turn stays pending | M6 |
| Background task: `stop_received_background_tasks_pending` and the wake-up Stop (D3) | M3/M4 prompt 3 |
| Multi-tool final text (D2) | M3/M4 prompt 2 |
| Several messages in one session; two parallel sessions (M5) | M4/M5 |
| StopFailure from a real API error (M8). Observed: an expired-OAuth failure in CLI 2.1.268 fired **no** StopFailure | M8 |
| `agent_id` with a subagent turn (D6) | M3 prompt 5 |

| JSON API consumed by a Swift client (`JSONDecoder`, surrogate pairs) | Phase 3 |
| Plugin: CLI hooks via the plugin; update/reload (M14); disable and uninstall keep history (M15) | LOCAL_MAC_VALIDATION §11 |
| Launcher fallback without a pin (Homebrew / CLT order) on macOS | M11 with `pin-python --clear` |

### Not Implemented (by design in this phase)
App settings for enabling projects, retention and deletion (the app has interface settings only), launch at login, app icon, notarization, settings-merge installer (not needed: plugin
first, ADR-008), ChatGPT integration, clipboard import, encryption at rest,
SessionStart/SessionEnd/Notification handling, automatic pruning (deliberately
never automatic), per-record expiry inside a session.

## Known risks
1. Real payloads may differ from the docs (for example `prompt_id` missing
   on Stop). Mitigation: order-based fallback with explicit labels; real
   payloads will become fixtures.
2. `last_assistant_message` may hold only the final text block of a
   multi-tool turn (D2). Prompt Relay copies exactly what Claude Code
   provides.
3. pbcopy and NUL / unusual characters (D5).
4. The Core needs some Python 3.9+ on the Mac (the CLT's `/usr/bin/python3`,
   Homebrew or python.org; ADR-004). The app will need the same path (ADR-006).
5. History is stored unencrypted (SECURITY §3).
6. The OpenNook API is not frozen, and it requires macOS 15+ (UI_RESEARCH).
7. `git status` can run a clean filter configured in a project's
   `.git/config` (SECURITY T9). The risk equals running git there yourself.
8. Without `prompt_id`, an interrupt or a prompt blocked by another hook
   makes the next answer `ambiguous` (by design).
9. JSON API v1 is not frozen until the first app build (JSON_API.md §6.6).
   After that, changes follow the compatibility rules.
10. Each JSON call starts Python (about 50–100 ms). The app must cache and
    refresh on file changes, not poll in a tight loop.
11. The 30-minute active-session grace is a heuristic (ADR-007).

## Cloud environment notes
- Swift toolchain unavailable: `download.swift.org` is blocked by the
  egress policy (HTTP 403). This drove ADR-004.
- No real Claude request was made to test hooks. The installed Claude Code
  2.1.312 binary contains the expected field names (HOOKS_RESEARCH §1).

## Phase 1.5 changes
- `hook-config --data-dir DIR`: the hook runs as `/usr/bin/env
  PROMPT_RELAY_HOME=DIR <python> bin/prompt-relay hook` (exec form, no shell),
  so isolated checks work in Claude Desktop, which does not pass the shell
  environment to hooks. Test: `test_hook_config_data_dir_isolates_hooks_without_env`.
- `test_s17` now resolves the platform data dir instead of the Linux path.
- Validation guide: every step uses an isolated `$PR_VAL/data`; the cleanup
  removes only the marked validation workspace and never runs `delete --all`
  on the default data dir.
- Real redacted fixtures and `test_real_desktop_turn_links_by_prompt_id`.

## Phase 2A changes
- New: `api.py` (JSON API v1), `retention.py` (history management),
  `docs/JSON_API.md`, `docs/api/api-v1.schema.json`, `tests/test_api.py`,
  `tests/jsonschema_lite.py`, `tests/golden/`.
- CLI: `--json` on projects/sessions/turns/show/context/delete/prune/retention;
  new `prune` and `retention`. `delete` now previews without `--yes`
  (still exit 2), has `--dry-run`, and keeps active sessions unless
  `--force-active` (exit 6). `--session` also accepts a `session_key`. Text
  output of the existing commands is unchanged, except that context
  timestamps now have microseconds.
- Store: `O_NOFOLLOW`; symlinks and non-session names in `events/` are
  ignored; a symlinked `events/` is refused; `safe_unlink`; reopen after a
  concurrent unlink; damaged-epoch dedup fix. `Store.delete_path` and
  `delete_all` were removed in favour of `retention`.
- config.json: optional `retention_days` (old readers ignore it).

## Phase 2B changes
- Layout: `prompt_relay/` → `plugin/prompt_relay/` (git mv). `bin/prompt-relay`
  and the tests import from `plugin/`. `hook-config` defaults to the
  checkout's `bin/prompt-relay`.
- New: `plugin/.claude-plugin/plugin.json`, `plugin/hooks/hooks.json`,
  `plugin/hooks/run-hook`, `plugin/hooks/prompt_relay_hook.py`,
  `.claude-plugin/marketplace.json`, `runtime.py`, `integration.py`,
  `docs/PLUGIN.md`, `tests/test_plugin.py`, ADR-008.
- CLI: `doctor --json --project/--no-project` (new `doctor_data` in schema
  v1, a compatible addition), `pin-python`. `enable` pins the running
  interpreter if no valid pin exists.
- `handler.log` lines gain `via=plugin|direct` before the outcome.
- Version 0.2.0 (package and plugin manifest).

## Phase 2B Mac validation (2026-10-29)
- Main path passed: Claude Desktop → plugin hook → storage → Copy Response →
  clipboard (LOCAL_MAC_VALIDATION §11, M10–M13).
- Discrepancy fixed in the docs: a local-path marketplace install is copied
  into `~/.claude/plugins/cache/…/<version>/`; it is not loaded in place
  (PLUGIN.md §2, ARCHITECTURE). No code defect was found; no code changed.
- The plugin stays installed (user scope) with capture on for the sandbox
  only.

## CI fix after Phase 2B (cloud, 2026-10-29)
GitHub Actions run 40910039983 (`ab57b74`) failed on Linux / Python 3.13:
`test_context_git_section_and_read_only` saw `.git/objects` mtime change.

- **Cause:** a race in the test setup, not a write by `gitinfo.collect()`.
  The test's own `git commit` starts `git maintenance run --auto`, which on
  git ≥ 2.47 (the runner has 2.56.0) detaches. It holds
  `.git/objects/maintenance.lock` after `commit` returns and removes it
  later. This was confirmed in git 2.56 sources: `run-command.c`
  `prepare_auto_maintenance` and `builtin/gc.c` `maintenance_run_tasks`.
  Locally (git 2.43) maintenance runs in the foreground, so the failure
  could not show there.
- **Fix:**
  - Fixture repos are created with `maintenance.auto=false`/`gc.auto=0`.
  - The `.git` snapshot got stricter: SHA-256 and size per file, in
    addition to all mtimes.
  - Hardening: `gitinfo` passes the same two settings, so no future git
    version can start maintenance from the read-only collection.
- **Regression tests:**
  - `test_git_fixture_starts_no_maintenance`;
  - `test_git_collection_never_starts_maintenance` (trace2, repo with
    auto-maintenance on);
  - `test_git_dir_snapshot_detects_transient_writes`.

  Both fixes were checked by mutation: with either one removed, the
  matching test fails.
- **Not reproduced:** the exact detached race on git 2.56 in the cloud.
  Building git 2.56 here was not permitted, so CI on git 2.56 is the check.

## Phase 3A changes
- New: `macos/` (Swift package), `scripts/build-macos-app.sh`,
  `docs/MACOS_APP.md`, ADR-009.
- No change to the Python Core, the plugin or the JSON API.
- Known limitations: `docs/MACOS_APP.md` §8 (Python start per call, ≈120 MB
  RSS, no settings UI or app icon, local signing only).

## Phase 3B changes
- New: `Sources/PromptRelayKit/Notch/` (geometry, state machine, controller,
  views, settings, coordinator, hot key), `UI/PreferencesView.swift`,
  `Services/ReadyNotifier.swift`, `Previews/PreviewSupport.swift`,
  `macos/Xcode/` (project, Info.plist, shared scheme),
  `macos/PromptRelay.xcworkspace`, ADR-010.
- AppModel: ready-answer tracking across projects (one extra `sessions`
  call, only while the notch or notifications are on), remembered "seen"
  answer, `revealReadyAnswer`, background observation without the fallback
  timer, `refreshNow` now waits for a refresh already running (a defect found
  by the new tests), and no Python call when a surface opens while FSEvents
  is live.
- Known limitations: `docs/MACOS_APP.md` §8 (Coucou coexistence not observed
  live, black island in both themes by design, ≈120 MB RSS).

## Phase 3C changes (implemented, not committed)
- Settings → Projects: Add Project (folder picker, path only, capture off),
  capture switch through `prompt-relay enable|disable`, inherited capture,
  removal of added-only folders (history untouched). Settings → Status:
  Core/Python, plugin, selected project's capture, last captured answer,
  with actions when something is missing.
- The app opens on and follows the newest finished answer unless the user
  is looking at another one; copy hides nothing.
- 82 Swift tests at the end of 3C. The owner's real check (add a project in
  Settings, new answer in the notch, Copy Response, capture off) has not
  been confirmed in chat yet.

## Phase 3D.1 changes (redesigned, not committed, awaiting visual review)
- First version (tabs Answer / Projects / History in a fixed 440 × 340
  workspace, plus the old windows) was **rejected** by the owner: it looked
  like a shrunken desktop app. Backups of that state and of Phase 3C are in
  the session scratchpad (`tracked.patch`, `untracked.tar`).
- Redesign (`docs/PRODUCT_UX_SPEC.md`): one island. Resting / Quick Peek /
  Expanded; Home = project picker, status, request, answer, Copy Response,
  Review Pack, Recent, All Responses, ⚙, ⋯ (Quit). Projects (capture
  switches, Add Project with the island held open), Recent, All Responses,
  Settings (General, Capture, Connection, About) and Full Response open
  inside the island with Back/Esc. Navigation: `AppModel.route`.
- Height follows content in every state (56–388 pt below the band, ≤ 60 %
  of the display); lists scroll inside with a fade.
- Displays without a notch: the same island floats below the menu bar,
  opened from the menu bar or ⌃⌥⌘P.
- App shell: no regular windows; the menu-bar item is a small menu (Open,
  Recent, All Responses, Settings…, Quit). "Open on hover at the notch" is
  now on by default (the island is the interface).
- Debug/Release: Debug is named "Prompt Relay Dev" (display name) with its
  own menu-bar icon; Release steps aside at the notch while Debug runs; a
  dot on ⚙ and Settings → About name the other build and offer to quit it
  on request.
- Fixed with a regression test: a relayout re-showed the resting panel
  with hover turned off.
- Verified on this Mac: `swift test` 98 tests, 0 failures (1 opt-in render
  test skipped); Xcode Debug and Release BUILD SUCCEEDED; `xcodebuild test`
  98 tests, TEST SUCCEEDED; the real panel captured on the built-in display
  (Debug build, real data): resting 185 × 32, peek 440 × 131, Home 440 ×
  188, Projects 171, Recent 94, All Responses 125, Settings 388 (scrolls),
  Full Response 122, back to 185 × 32; idle 0 % CPU, ≈137 MB RSS.
- Not verified: a real pointer (hover, clicks while open, the ⋯ menu, the
  folder picker) and the floating island on a real external display — the
  capture drives the same state machine without a mouse. Needs the owner's
  check on the real screen.

## Phase 4 changes (implemented and tested; owner validation pending)
- Recovery point before any change: `refs/backup/phase4-start` (all tracked
  and untracked work of 3C and 3D.1), plus patch/tar copies in the session
  scratchpad.
- Single island, redesigned (`PRODUCT_UX_SPEC.md`, ADR-011): Home answers
  project / task / answer / which button; graphite cards on black; one white
  primary action; Projects, Recent Copies, History (search, pins, imports),
  Import, Settings (plain language; Diagnostics only there) and Full Report
  (formatted or exact text, always complete) inside the island. Removed:
  the main, status and settings windows, the old menu-bar panel, the ⋯ menu,
  the duplicate "Recent answers" view, the Debug badge.
- Reports: `ReportRef` for local turns and imports; Review Pack gets a
  "Review Pack" title and a "Source" line in the Core (the only Core change;
  goldens updated) and an app-written pack for imports in the same format.
- Cloud: researched in the official docs (cloud sessions run on Anthropic
  VMs; local hooks cannot see them; `--teleport` changes the repository);
  manual Import with verbatim storage, dedup and provenance labels.
- Attachments: images added by the user, private copies with checksum;
  Copy Image, drag, Copy Text + Images (multi-item pasteboard).
- Relay the bear: original vector mascot, facts-only moods, pointer gaze
  only inside the island, blinking only while visible, Reduce Motion and an
  off switch.
- Debug/Release: Debug is "Prompt Relay Dev" with its own icon; Release
  steps aside at the notch while Debug runs; Settings → About offers to quit
  the other build on request. Root cause: two bundle IDs launched at once.
- Verified on this Mac: `swift test` and `xcodebuild test` 109 tests,
  0 failures (1 opt-in skipped); Xcode Debug/Release BUILD SUCCEEDED;
  Python 141 tests OK; a 100 KB+ report through the real hook (twice) copied
  byte-identical; real island captured in every view; idle 0 % CPU,
  ≈164 MB RSS (Debug).
- **Not verified (needs the owner):** text + images pasted into ChatGPT
  (desktop and web); a real cloud report import; a real long local report
  through the new UI; the floating island on an external display; real
  pointer hover/focus after the redesign.

## Phase 4 real-session audit (2026-10-30)
- Found: the prompt-relay repository itself was not captured (only the two
  sandboxes were enabled). Capture was enabled for it with `prompt-relay
  enable` (the previous `config.json` is kept in the session scratchpad).
- **Real capture, byte-level:** the final answer of this Claude Code session
  (Desktop, installed plugin 0.2.0) was stored by the hook: 4040 UTF-8 bytes,
  SHA-256 `b047601d…`, byte-identical to the same message in the session
  transcript. Its request is labeled unavailable (the prompt came before
  capture was on).
- Through the app's own code on the real store (read-only, private
  pasteboard; opt-in `RealSessionAuditTests`): Full Report text, Copy
  Response bytes and the Review Pack (the report exactly once) equal the
  transcript bytes; the Formatted reader drops no line.
- Defects found and fixed, each with a regression test:
  1. Sending the next prompt hid the previous answer: the session's last
     turn was "awaiting response", so the newest answer fell back to an
     older session in another project and the island would switch to it.
     The newest finished answer of such a session is now kept (one cached
     `turns` call). Seen on the real store: "Last capture" showed
     sandbox-a; it now shows this session.
  2. Recent Copies named the folder Claude ran in (possibly a subfolder),
     not the enabled project.
  3. A code block inside a list item kept the list's indent on every line.
- Manual paste kit for ChatGPT: `PasteInteropKit` (opt-in) writes a known
  text and a generated test image to the general pasteboard with the app's
  own clipboard code. Not run by the agent (it would overwrite the owner's
  clipboard); the result is pending.
- Memory: Release build idle ≈91 MB; Debug with the real data and the
  island open in every view ≈149 MB; 0 % CPU idle.
- Not verifiable by the agent: real pointer hover and the mascot's eye
  movement, image paste into ChatGPT, a real cloud import.

## UI/UX polish, Review Pack and mascot (2026-10-30)
- **Spacing:** the content was laid out from the window edge, but the notch
  outline's sides stand 14 pt in from it, so cards sat ≈4 pt from the
  visible side. One rule now (`IslandMetrics`, measured from the visible
  side): 22 pt sides, 22 pt bottom, 12 pt between blocks; tighter on short
  displays and in Quick Peek; band and cards share one left edge; island
  480 pt wide. Regression tests render the real views and check blocks and
  buttons against the outline (also with the copy line shown, on a 380 pt
  display).
- **Response scrolls inside its card** (76–260 pt by display height), Home
  never clips; the wheel scrolls only the answer (no nested scroll); a
  different answer starts at its top; View Full Report kept; Copy Response
  copies the original whatever is scrolled. Tested with real scroll-wheel
  events on the rendered view.
- **File picker:** it opened under the island (the panel is above normal
  windows). Now the island steps aside synchronously before `NSOpenPanel`
  shows and returns as it was (view, report, frame, keyboard) on a choice,
  Cancel or Esc; one dialog at a time; images go to the report the picker
  was opened for; unreadable files are named. Same path for Add Project.
  Tested with an injected picker; the real dialog needs the owner.
- **Relay:** 22/24 pt (≈ +25 %), redrawn eyes with highlights, ears perk
  when curious; smooth eye and head movement toward the pointer (tilt ≤ 7°),
  back to neutral on exit; copy: hop + happy closed eyes; failure: worried
  brows + head shake (no success reaction). Reduce Motion respected.
- **Review Pack tests:** the response is now read back out of the pack
  (`ReviewPackReader`) and compared byte for byte; the whole pack is not.
  Real data: this session's turn 2 (request «продолжи где остановился»,
  linked by `prompt_id`): captured 5253 bytes, SHA-256 `528b4684…`, equal to
  the transcript, to Full Report, to Copy Response and to the response
  extracted from the Review Pack; appears once; reader drops no line.
- "Continue where you stopped": proposal only (PRODUCT_UX_SPEC §12); needs a
  Core change, not made.
- Swift 125 tests (4 opt-in skipped), `scripts/check.sh` OK, Xcode Debug and
  Release build. Release idle, island not drawn (yields to the running Debug
  build), same conditions: before 20 MB footprint / 87 MB RSS, after 21 MB /
  91 MB; 0 % CPU both.
- Not verified by the agent: real pointer hover, eye/head following and the
  copy reaction in the running app; the real NSOpenPanel above/under the
  island; memory with the island open on a long real report.

## UX polish 2: attachments, file picker, Relay, Review Pack audit (2026-10-30)
- Context: the owner's real-Mac check ran the Debug build started 12 h
  earlier from `2c7249d`, i.e. without the first polish. Both rounds are in
  the working copy; backup ref `refs/backup/ui-polish-1` (first round).
- **Defects found and fixed:**
  1. Images showed nearly island-wide: a `Menu` with an image label is drawn
     by AppKit at the image's own size. Now compact file cards (thumbnail
     decoded at 96 px, name, type, size, ⋯, ×) in one sideways row.
  2. NSOpenPanel under the island (the panel's level is above normal
     windows). The island steps aside before the dialog shows and returns
     after it; the shortcut and the menu bar bring an open dialog forward.
  3. Attachments were typed by file extension and a damaged PNG was
     accepted; now typed by content, damaged and permission-denied files
     are named. Removal could leave a record pointing at a deleted file and
     never reported failures; now index first, file only when unused,
     errors shown. A stored name in the index could point outside the
     folder; now refused.
  4. Copy Image / file drags used the private name ("3f2a….png"); now
     hand-off copies under the original names (`<data dir>/app/handoff/`,
     rebuilt on each use).
  5. Pasted prompts showed `<pasted_content id="…">` in the Task card and
     History (seen on the real store); display now drops the wrapper (copies
     and the Review Pack stay verbatim).
  6. A spring animation on Relay's gaze redrew the panel at the display
     rate: ≈ 26 % CPU while the pointer moved. Now eased at 30 fps until it
     arrives: ≈ 2 %.
  7. Home overflowed on short displays (≈ 420 pt, "Larger Text") with
     images: compact cards and a one-line task there.
  8. The local Review Pack listed images after "Request for review"; now
     before "Tests and CI" (anchored on the Core's own last heading).
- **Relay** follows the pointer anywhere on screen (global + local mouse
  monitors, no permission, no key events, ≤ 30 updates/s, no stored
  positions; stops when hidden, asleep, under Reduce Motion or a dialog),
  28 pt, ears 38 pt.
- **Review Pack audit** (real turns 2 and 3 of this session): Copy Response
  = transcript bytes (5253 B `528b4684…`; 8573 B `df3b8dbe…`); the response
  read back from the pack is identical, once, fenced longer than its own
  fences; source, project, session, turn, status and git state correct and
  labeled; Claude's claims [Not verified]; imports labeled as pasted by the
  user; images listed by name/type/size, "sent separately", no claim they
  were sent. Finding: the Project line includes the absolute path (user
  name) — Core change proposed in ADR-012 with earlier requests of the
  session for «продолжи где остановился»; not implemented (Core change).
- Tests: Swift 142 (6 opt-in skipped), Python 141 (`scripts/check.sh` OK),
  Xcode Debug and Release build. Real AppKit checks: scroll-wheel routing
  through the real panel; the real NSOpenPanel (opt-in, Esc and Cancel).
  Release idle (island yields to the running Debug build): 19 MB footprint,
  89 MB RSS, 0 % CPU.
- **Not verified by the agent (needs the owner):** keyboard focus of the
  real dialog after a real click on 📎; trackpad scrolling by hand; Relay
  following the real pointer; pasting or dropping images into ChatGPT (app
  and web) by each method.

- **Owner check (2026-10-30):** the owner checked both polish rounds on the
  real Mac and reported "All good"; committed on the branch, not pushed.

## Phase 5 implementation (2026-10-30; committed on the branch, not pushed)
Plan: `docs/PHASE5_PROPOSAL.md` rev 3.1 (R1–R11), ADR-013…016. Commits:
`7312d1c` (plan, ADRs), `7182436` (Core), `859c044` and `8679c76` (app),
plus this documentation commit. Backup refs `refs/backup/phase5-*`.

**Stages:** 5.0 done · 5.1 done in a Claude Desktop sandbox (the CLI is
logged out; V1 latency at scale and V5d `-p` teardown not observed) · 5.2,
5.3, 5.4, 5.5, 5.6, 5.7, 5.8 (step 2 hand-off; the ChatGPT paste matrix V8
is the owner's), 5.9 implemented · 5.10 (local rendering of mockup states)
not started: it waits for a separate security approval · 5.11 partly (see
below).

**Defects found in real payloads and fixed (regression tests):**
1. Background-task notifications and subagent hand-backs arrive as
   UserPromptSubmit with the turn's `prompt_id`; the Core made each a new
   turn "awaiting response" after Claude had stopped.
2. Publishing an Artifact arms a `monitor` background task that keeps
   running; every later Stop was "background tasks pending", shown as
   "tasks still running" (5 of 12 real Stops on this Mac). Monitors are now
   reported as watchers, not work in flight.
3. Opening the island revealed the newest answer of any session and
   replaced the session the user was reading (`revealReadyAnswer`).
4. `ClipboardImageHistory.poll()` worked while the mode was off (guarded).
5. Truncated labels and a duplicated time found in renders of the real
   history.
Also: the island's preference keys (`IslandFramesKey`, `BoundedScrollHeight`)
replaced by geometry callbacks; the scroller no longer depends on the
measured height; the window no longer forces a display inside SwiftUI's
layout pass. The Xcode warnings themselves were **not reproduced** here
(they are not in the system log of the test process): the owner's Xcode
console is the check.

| Item | Status |
|---|---|
| Python suite (3.11+ and Xcode's 3.9.6), `scripts/check.sh` | **Automated: 155 tests OK** (1 skipped by design); hook latency median ≈ 40 ms |
| Real plugin validation | `claude plugin validate plugin --strict`: no errors (CLI 2.1.268, no install) |
| Tool events in a real Desktop session (sandbox, capture-only hooks) | **Verified on this Mac** (22 events, redacted fixture) |
| Plugin 0.3.0 with the tool hooks installed for real | **Not done**: the owner installs it (`claude plugin` commands) |
| Swift `swift test` | **Automated: 161 tests, 0 failures** (6 opt-in skipped) |
| Xcode Debug and Release builds | **BUILD SUCCEEDED** both |
| Session switching, pinning across launches, "New in …" | Automated (fake Core); real history rendered: the two real `prompt-relay` sessions are separate and titled |
| Copy for ChatGPT on a real turn of this session | Verified with the real Core: response once, byte-exact, no absolute paths, "Watchers at Stop: 1" |
| Typed attachments, mockup states, hand-off names and order, suggestions | Automated (real files, real ImageIO/PDF, temp store) |
| Clipboard image history | Automated with a private pasteboard; **not verified** against macOS 27's paste-privacy prompt (V6) |
| Relay at rest: bounds, no camera overlap, no clipping | Automated: math for every pose and the **rendered** SwiftUI view at 4× (9 gazes × moods) |
| Relay motion feel, breathing, copy joy on the real screen | **Not verified**: needs the owner's eyes |
| Relay CPU (Debug test harness, pointer at 120 Hz) | idle ≈ 0 % over the loop; moving ≈ +6–8 points over the loop (Phase 4 code, same harness: +3.4). Release app not measured |
| Paste of text and files into ChatGPT Desktop / Safari / Chrome (V8) | **Not verified**: the owner's matrix |
| Local rendering of mockup states (5.10) | **Not implemented** (needs approval) |

## Phase 5.11 stabilization (2026-10-30; committed on the branch, not pushed)
Commits `564740b`, `44be234`, `44891a3`, `d573218`, `8b9b97b` and this
documentation commit. Backup ref `refs/backup/phase5.11-start` (= `ee9d359`).

**Plugin 0.3.0.** The `prompt-relay` marketplace is a `directory` source
pointing at this checkout. Claude Desktop already ran the working tree's
0.3.0 hooks (tool events stored `via=plugin`) while the registry still said
0.2.0; `claude plugin update prompt-relay@prompt-relay` recorded 0.3.0
(`Hooks (5)`), `~/.claude/settings.json` unchanged (SHA prefix 49269c3b).
Registry backup: `~/Library/Application Support/PromptRelay/backups/`.

**End-to-end on this Mac (real Claude Code, two sessions of project
`~/prompt-relay-validation/e2e-511`).** The worker session ran `echo`
(exit 0), a failing command (exit 4), `unittest` (exit 0), an Edit, a
script that wrote `blue.png` and a Write of `REPORT.md`; the viewer session
only answered. Stored: 4 commands with the right exit codes, 2 files
changed, each session separate. Copy Response = stored answer byte for
byte; Copy for ChatGPT holds the answer once, `exit 4`, the files and Git
state. `RealHandoffE2ETests` (opt-in) on that turn: suggestions for all
three files with their real source, pack, and step 2 — the three files on
a private pasteboard are byte-identical to the originals. Pasting into
ChatGPT was **not** verified (owner, `docs/OWNER_CHECKS_5_11.md`).

**Defects found and fixed (each with a regression test):**
1. A turn Claude Code starts itself (side session reporting back) was
   exported as "Original user request" with `<system-reminder>` /
   `<side-sessions-event>` text. Origin classification, ADR-017.
2. Titles and the Task card showed a leading `<system-reminder>`; requests
   carry `display_preview`; titles drop harness blocks; a session not
   started by the user takes Claude Code's title when one exists.
3. A failed non-test command left the chip at "1× exit 0":
   `observed.commands_nonzero`, failures shown first.
4. A file made by a script and named in the answer was not suggested; now it
   is, labelled "named in Claude's answer … not seen being written
   [Reported by Claude]" (never "Confirmed").
5. The step-2 bar pushed the copy line out of Details.
6. "layout during layout": traced with lldb (`_NSDetectedLayoutRecursion`)
   to `NotchController.resize` changing the window frame inside SwiftUI's
   layout pass; now done right after the pass. `scripts/check-layout-recursion.sh`: 0 hits.
7. "Invalid frame dimension": negative resting size without a notch.
8. Relay CPU while the pointer moves (below).

**Xcode warnings, real app log (`log show`, owner's Xcode runs).** Runs at
11:23 and 15:00 (before Phase 5) logged `Bound preference IslandFramesKey /
BoundedScrollHeight … multiple times per frame` and the layout recursion.
The Phase 5 Debug build started 16:02 ran 4.5 hours with **no**
preference warnings; it still logged the layout recursion once (fixed in
`d573218`, needs a rebuild to confirm on screen).

**Relay CPU** (same harness for Phase 4 `f72a8ce` and Phase 5, optimized
`-c release` test build with DEBUG test hooks, pointer at 120 Hz, medians of
4 alternating runs): moving minus the harness loop — Phase 4 4.50, Phase 5
before 6.05, after 5.15 percentage points; at rest 1.04 vs 1.07 %; RSS 57 MB
both. Frames published while moving fell from ≈ 19 to 11–12 per second
(gaze/head published only for steps ≥ 0.07 pt or on arrival). A main-thread
sample at rest shows no periodic work. Breathing runs in WindowServer; its
cost could not be separated from the system's (≈ 44 % WindowServer
background). The Release app itself was not profiled.

| Item | Status |
|---|---|
| Python suite (3.11+ and 3.9.6), `scripts/check.sh` | **Automated: 168 tests OK** on both (1 skipped); hook median 40 ms |
| Swift `swift test` | **Automated: 172 tests, 0 failures** (7 opt-in skipped); `plugin validate --strict` passed |
| Xcode Debug and Release (`Prompt Relay` scheme) | **BUILD SUCCEEDED**, 0 compiler warnings |
| Tool events, two sessions, Copy Response / Copy for ChatGPT | **Verified on this Mac** (real Claude Code turn) |
| Files to the clipboard (step 2) | **Verified** on a private pasteboard, byte-identical |
| Paste into ChatGPT Desktop / Safari / Chrome (V8) | **Not verified** (owner) |
| Relay feel on the real screen, Reduce Motion | **Not verified** (owner) |
| Clipboard image history vs macOS 27 paste prompt (V6) | **Not verified** (owner) |
| Local rendering of mockup states (5.10) | **Not implemented** (deferred) |

## Phase 6 (2026-10-31; committed on the branch, not pushed)
UX redesign, Clipboard workspace and functional polish; details, defects,
state table and owner checks in `docs/PHASE6.md`. Backup ref
`refs/backup/phase6-start` (= `7538a98`). App only: Core, plugin, JSON API
and stored data unchanged.

| Item | Status |
|---|---|
| Swift `swift test` | **Automated: 186 tests, 0 failures** (9 opt-in skipped) |
| Python suite, `scripts/check.sh` | **Automated: 168 OK** (1 skipped) |
| Layout recursion check | **0 hits** |
| Xcode Debug and Release | **BUILD SUCCEEDED**, 0 compiler warnings |
| Real history in the new views (offscreen, read-only) | no overlap; answer order verified |
| Running app on screen, Reduce Motion, external display | **Not verified** (owner) |
| Paste into ChatGPT Desktop / Safari / Chrome (V8), ⌃⇧⌘4 history (V6) | **Not verified** (owner) |

## Phase 6 polish (2026-10-31; committed on the branch, not pushed)
History toggle, answer-switch motion, in-island tooltips, one copy
confirmation, Copy Answer / Copy for Review, plain-language facts, three
themes (Soft Spectrum default). Details: `docs/PHASE6.md` § Phase 6 polish;
proposals for a public release: `docs/PRODUCT_ROADMAP.md`. Swift 195 tests
0 failures (10 opt-in skipped), Python 168 OK on 3.14 and 3.9.6, Xcode
Debug/Release succeeded, layout recursion 0. On-screen checks are the owner's.

## Phase 6 visual pass (2026-10-31; committed on the branch, not pushed)
Warm Cocoa (default), paired card rows, Task motion, compact in-island
tooltips, Copy with Context with a real Preview, attachment preview,
neutral package heading in the Core. Details: `docs/PHASE6.md` § Phase 6
visual pass. Swift 202 tests 0 failures (11 opt-in skipped), Python 168 OK
on 3.14 and 3.9.6, Xcode Debug/Release succeeded, layout recursion 0. The
live panel on screen is the owner's check.

## Phase 7 (2026-10-31; committed on the branch, not pushed)
UX stabilization and developer workspace; defects, causes, features and
owner checks in `docs/PHASE7.md`. Backup ref `refs/backup/phase7-start`.
Implemented: tooltip placement inside the visible island, thumbnail
hit-testing, View Full Task, Markdown Source, Standard / Full Copy with
Context (Core `--detail`), Preview sections, Evidence Check, Artifact
Completeness, Review Checklist, Import AI Result, Export Bundle.

| Check | Result |
|---|---|
| Swift tests | 221, 0 failures (11 opt-in skipped) |
| Python 3.14 / 3.9.6 | 172 OK each (1 skipped by design) |
| Layout recursion | 0 hits |
| Xcode Debug / Release | BUILD SUCCEEDED, 0 warnings |
| Live NSPanel hover, real mouse, Reduce Motion, paste into assistants | **Not verified** (owner) |

## Phase 7.1 (2026-10-31; committed on the branch, not pushed)
Persistent hand-off with the copied character count, one Relay across
running copies, tooltip width, short-display step 2, Living Relay (2.5D head,
idle machine, settings, no-notch pill), Intelligent Import AI Result,
Capture Health, About details, Full as default. Details, the clipboard
incident and owner checks: `docs/PHASE7.md` § Phase 7.1. Swift 243 / 0 failures, Python 172 OK ×2,
Debug/Release built. Live-screen behaviour is the owner's check.

## Phase 7.2 (2026-10-31; committed on the branch, not pushed)
Relay on a display link with Core Animation layers: 59 fps while moving
(was 12), paused at rest, ≈ 4 % CPU for Relay while following on the bench.
Coucou studied (MIT techniques, no artwork). Copy with Context always Full,
header fixed, audit fixes, display choice and Reduce Motion observer.
Details and measurements: `docs/PHASE7.md` § Phase 7.2.

## Phase 8 (2026-10-31; committed on the branch, not pushed)
Audit, tooltip/Answer/footer layout fixes, the black box in Observed Work
(a blank tooltip), Living Relay 2.0 (vertical tracking), Failure Inspector,
Report Ready indicator (working / unseen / automated / count), Preview
Formatted + Markdown Source, structured ⓘ explanations, product analysis in
`PRODUCT_ROADMAP.md`. Details, measurements and owner checks:
`docs/PHASE8.md`. Core unchanged (Python 172 OK ×2). Backup ref
`refs/backup/phase8-start`.

## Next agreed stage

**After Phase 15 (2026-11-07):** see the top entry — owner review and merge
of `phase/15-mvp-readiness` into `develop`, install decision (consent), MVP
acceptance (`docs/PHASE15_MVP_ACCEPTANCE.md`), then a Phase 16 the owner
approves. The notes below are older plans, kept for history.

**After Phase 11 (2026-11-05):** owner live acceptance (macos/PHASE11.md
§4 and §13), the license decision, and a Developer ID certificate before any
public beta. No Phase 12 work without approval. The text below is the
earlier plan, kept for history.
Phases 7–8 are committed locally; the owner checks `docs/PHASE8.md` § 8 (first:
quit old copies). Push only when the owner asks. Verification Timeline,
multi-turn export, Target Profiles, ADR-012 and source adapters wait for approval.
