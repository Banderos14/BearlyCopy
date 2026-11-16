# Phase 15.2 — Product audit as a new user, lifecycle, screenshots

Date: 2026-11-08. Branch `phase/15-mvp-readiness` (worktree
`~/Projects/prompt-relay-phase15`). Companion: [owner guide (Debug switch,
screenshot troubleshooting)](PHASE15_2_OWNER_GUIDE.md), [Phase 15 audit](PHASE15_AUDIT.md),
[test results](PHASE15_TEST_RESULTS.md), [MVP acceptance](PHASE15_MVP_ACCEPTANCE.md).

Test-type legend: **Auto** automated test on this Mac · **Mac** real macOS
read-only observation by Claude · **Code** source reading only · **Owner**
needs the owner's mouse/System Settings · **—** not tested.

## 1. Observed state (historical snapshot, 2026-11-08 ~09:00 CET)
Not a permanent assumption — re-check with `scripts/run-latest-debug.sh`.
| Item | Value (verified) |
|---|---|
| Running Debug | `…/DerivedData/PromptRelay-cbijvubt…/Build/Products/Debug/Prompt Relay.app`, bundle id `io.github.banderos14.PromptRelay.debug`, 0.6.0, commit `17844fe` (Phase 14.2), started from Xcode, up ~9 h |
| Running Release | `~/Applications/Prompt Relay.app`, bundle id `io.github.banderos14.PromptRelay`, 0.4.1, commit `0dffa80`, up ~2 days |
| Signing | **both ad hoc** (`Signature=adhoc`, no team) |
| Plugin | 0.4.1 (cache also holds 0.2.0–0.4.0) |
| Source | `phase/15-mvp-readiness` = `c57c799` before this phase (= GitHub); `develop` = `17844fe`; `main` = `775c5c9` |
| History | `~/Library/Application Support/PromptRelay`: 36 MB, 17 session files (size only; not read) |

## 2. Product inventory
**Implemented and covered by automated tests:** opt-in capture per project;
verbatim answer; StopFailure ≠ answer; Results Inbox, projects, sessions,
agent profiles; Quick Peek / Details; Copy Response; Copy with Context (Full);
Context Packs; imports; attachments (files, images, clipboard images, window
snapshots in memory); Evidence Check / Review Checklist / Failure Inspector
(Phase 15/15.1 attribution); Needs Input model; Settings, About (version,
commit, location, Core, plugin, running copies, quit other build); Set Up page
with per-agent states (Not detected / Installed / Capture disabled / Waiting
for first event / Connected / Error); menu-bar item with Quit; notch and
no-notch placement; display, sleep/wake and screen-lock observers; local
install script with dry run, backup and rollback.
**Implemented, needs the owner (live):** hover/resize/drag with a real mouse;
auto screenshots with real windows; Screen Recording grant/deny/restart;
Debug/Release grants; paste into ChatGPT; sleep/wake, display changes,
external displays, lid close.
**Partial:** Codex (adapters exist; delivery depends on Codex config); Needs
Input observed live only for some hosts; Claims detection is phrase matching.
**Missing (not in scope):** Developer ID signing / notarization (so every
Debug rebuild may be a "new app" to macOS privacy), an installer for
non-developers (the plugin install still needs `claude plugin` commands),
encryption at rest, automatic updates.

## 3. Can a new user succeed? (verdict per stage)
| Stage | Verdict | Why |
|---|---|---|
| Install | **Developer-only** | No signed download; `scripts/install-local.sh` and `claude plugin marketplace add <checkout>` require a checkout and Terminal. Fine for the owner; not for "ordinary developers" yet (needs Phase 5-style release work, ADR-020). |
| First launch | OK (Code/Auto) | Set Up page explains what is captured and that nothing is captured until a project is enabled; empty states name the next step; menu-bar icon always present. |
| Connect | OK (Code/Auto) | The five situations the brief asks about map to distinct states: plugin missing → "Not detected" + Copy Commands; capture disabled → "Capture disabled"; connected, no answers → "Waiting for first event"; Core unavailable → "Prompt Relay can't read its history" + Diagnostics; working → "Connected — events observed". |
| Version clarity | **Was confusing → fixed (P2)** | About showed "Plugin 0.4.1" beside app 0.6.0 without meaning; now says compatible/update/newer with the exact command. |
| Daily workflow | OK (Auto), live: Owner | See journey matrix §5. |
| Screenshots | **Was confusing/fragile → fixed (P1/P2)** | See §4. |
| Switching builds | **Was impossible for the owner → script (P1 for acceptance)** | `scripts/run-latest-debug.sh` (dry run by default). |

## 4. Automatic screenshots — findings
1. **"Window not linked" is correct behaviour, not a permission failure.**
   The status is decided *before* any capture: no link exists for that
   conversation's agent·host·project in **this running copy**. Links are in
   memory only (ADR-028): every restart, every *other* copy (Debug vs
   Release) and every rebuild starts with no links. With two copies running,
   a link made in one copy is invisible to the other. The Screen Recording
   list being "on" is unrelated to this status.
2. **Ad-hoc signing (high likelihood, Owner to confirm).** Both builds are
   ad-hoc signed. macOS ties privacy grants of ad-hoc apps to the exact
   binary, so a rebuilt Debug app can show "on" in Screen Recording while the
   new binary is still not allowed. The Debug permission hint now says to
   switch it off and on again after a rebuild.
3. **R1 confirmed and fixed (P1).** Any non-permission ScreenCaptureKit
   error dropped the link — in `WindowCapture.capture` (dropped the source
   filter), `finishCapture` and `checkAutoCaptureAccess`. A minimized window,
   one on another Space, or a transient error therefore lost its link
   silently. Now `WindowCapture.presence(of:)` asks macOS's window list
   (metadata only, no pixels, no title, no permission) whether the linked
   window still exists: **gone** → link removed, "Window closed"; **exists
   off screen** → link kept, new status "Window not available right now";
   **exists on screen** → link kept, "Capture failed"; **unknown** (no window
   number) → link kept. Never another window as a fallback. ADR-028 intact.
4. **Open Screen Recording Settings now always reachable (P2, owner
   request).** Shown with every no-screenshot status (Window not linked,
   closed, not available, failed, association required) as well as in the
   permission states. Destination verified on this Mac:
   `Privacy_ScreenCapture` = "Allow applications to record your screen"
   (Screen & System Audio Recording); `Privacy_AudioCapture` (audio only) is
   never used. The button changes no status by itself.
5. **Link Window vs Capture Now** now explained in the status text and in
   tooltips: Link = this conversation's next final answers are captured
   automatically until quit; Capture Now = one picture, no link.
6. Manual capture (Capture Now / Capture Final Window) is independent of auto
   capture; its success proves nothing about the auto trigger (unchanged,
   documented in the owner guide).

## 5. Real-user journey matrix (A–Z)
Status: Pass (automated only) / Owner / Blocked / Not tested. "Pass" here
never means a human used the GUI.
| # | Scenario | Expected | Evidence / type | Status | Sev. if failing |
|---|---|---|---|---|---|
| A | First install & onboarding | Set Up explains opt-in; menu-bar icon | Code; Phase 11 tests (Auto) | Owner (install needs consent) | P1 |
| B | Returning user with history | history listed, Latest = newest final | Phase 9.3/12 tests (Auto); Core 0.1 s on real 36 MB (Mac) | Pass (Auto) | — |
| C | Claude Code CLI | capture via plugin | Phase 1.5 live (historical), Python suite (Auto) | Owner re-check | P1 |
| D | Claude Desktop Code tab | capture, host recorded | live 2026-10-29 (historical); this very session is captured (Mac, Core `results`) | Pass (Mac, read-only) | — |
| E | Multiple sessions | never mixed | Phase 12/15 tests (Auto) | Pass (Auto) | P0 |
| F | Multiple projects | never mixed | tests (Auto) | Pass (Auto) | P0 |
| G | Missing / outdated plugin | "Not detected" + commands; version note | Code + Phase152 test (Auto) | Pass (Auto), Owner look | P2 |
| H | Capture disabled | nothing stored; "Capture disabled" | Python `project_not_enabled` (Auto) | Pass (Auto) | P0 |
| I | Working → Needs input → Working → Final | amber dot, cleared by next activity | Phase 12.1/12.2 tests (Auto); partly live | Owner | P1 |
| J | StopFailure / interrupted | API error, never an answer; interrupted = unclear | Python + Phase151 (Auto) | Pass (Auto) | P1 |
| K | Long answer, many commands | verbatim, no clipped rows | 300 KB probe (Mac); Phase 14 layout (Auto) | Pass (Auto/Mac) | P1 |
| L | Real failed test/build | "1 build failed", alarm, rerun item | Phase151 (Auto) | Pass (Auto) | P1 |
| M | Uncertain compound command | "unclear", no false pass | Phase151 (Auto) | Pass (Auto) | P1 |
| N | Manual + auto screenshots | one per final; manual independent | Phase 14 suites (Mock) | Owner | P1 |
| O | Permission denied | Permission required + Open Settings + Check Again | Phase 14.1 (Mock) | Owner | P1 |
| P | Granted after restart | Restart required → works after reopen | Phase 14.1 (Mock) | Owner | P1 |
| Q | Minimized / other Space | link kept, "not available right now" | Phase152 (Mock) | Owner | P1 |
| R | Copy Response / with Context | verbatim; context with exit codes and caveats | tests (Auto), probe (Mac) | Pass (Auto), paste: Owner | P0 |
| S | Text + image handoff | both delivered by the receiving app | tests (Auto) | Owner | P2 |
| T | Close, quit, relaunch | history kept; links gone (ADR-028) | tests (Auto) | Owner | P1 |
| U | Several Debug/Release copies | Release yields the notch; About lists copies; one Quit | Code (`AppBuild.yields`), Mac (two copies observed) | Owner | P2 |
| V | Update and rollback | install-local dry run/backup/rollback | Phase 11 (Auto dry run) | Owner (consent) | P1 |
| W | History deletion | preview, confirmation, active-session protection | Python (Auto) | Pass (Auto) | P0 |
| X | Missing / corrupted storage | read errors shown, hook exit 0 | Python + probe (Auto/Mac) | Pass (Auto) | P1 |
| Y | Screen sizes / accessibility | 268–568 pt layouts; labels | Phase 14/14.2 (Auto); VoiceOver live: — | Owner | P2 |
| Z | Uninstall without data loss | app removal keeps `Application Support/PromptRelay`; plugin uninstall keeps history (no state in plugin root, CLAUDE.md #10) | Code + docs | Owner | P0 |

## 6. Defect register (Phase 15.2)
| ID | Sev. | Confirmed? | Problem | Root cause | Fix |
|---|---|---|---|---|---|
| S1 (R1) | P1 | **Confirmed** (code + Mock) | a failed capture of a still-existing window removed its link | three call sites treated any non-permission error as "window gone" | `presence(of:)` + `afterCaptureFailure`; new status `windowNotCapturable` |
| S2 | P2 | **Confirmed** (code) | no route to Screen Recording settings from "Window not linked" / closed / failed | button only in `permissionRequired` | `offersSettingsShortcut`, button in all no-screenshot states |
| S3 | P2 | **Confirmed** (UI text) | "Window not linked" did not say how linking works or that links end at quit; Link vs Capture Now unexplained | terse text | new sentence (≤140 chars rule kept) + tooltips |
| S4 | P2 | **Likely**, Owner to confirm | ad-hoc Debug rebuild may need its Screen Recording switch toggled | ad-hoc signing ties TCC to the binary | Debug hint text; owner guide |
| S5 | P2 | **Confirmed** (UI) | Plugin 0.4.1 vs app 0.6.0 unexplained | no compatibility note | `AppBuild.pluginNote` in About |
| S6 | P1 (for acceptance) | **Confirmed** | owner cannot switch to the latest Debug build alone | no tooling; two copies, same Debug bundle id | `scripts/run-latest-debug.sh` (dry run default, normal Quit only) |
| S7 | P3 | Confirmed | header tooltip "Choose a project and an agent session" read like an empty-state message | wording | "Switch project or conversation" |
| S8 | P3 | Suspected | two copies adding attachments at the same instant: last index write wins | no cross-process lock on `attachments.json` (writes are atomic, no corruption) | documented: run one copy; not fixed |
| S9 | P2 | Not a bug | "checks left / observed / unclear / likely not an error" | terms defined in Evidence & Review | glossary in owner guide |

## 7. Lifecycle (code + read-only observation)
Menu-bar item with "Quit Prompt Relay" in both builds (Debug shows a hammer
icon). Closing the island is not quitting. Display/sleep/wake/lock observers
in `NotchController`. Release steps aside at the notch while a Debug copy
runs; within one bundle id the newest launch keeps the notch. Quitting the
app never affects Claude Code (hooks run the plugin's own Core). History and
settings persist; in-memory screenshots and window links do not (by design).
No live sleep/wake/display test was done — Owner.

## 8. Security and privacy (delta)
No change to storage, permissions or network. New window-presence check reads
only the window list entry for the one linked window number (no pixels, no
titles, works without Screen Recording). The switch script never deletes,
force-quits, installs, or touches history, plugin or System Settings.
Residual: history unencrypted at rest; ad-hoc signing; two copies may race
on attachment index writes.

## 9. Performance (measured read-only, this Mac)
| Measure | Result |
|---|---|
| Idle CPU, both running copies (`ps`, `top` 3 s) | 0.0–0.1 % |
| Memory: Debug (9 h up) / Release (2 days up) | RSS 113 MB / 70 MB; footprint 54 MB / 42 MB |
| Core on real history (36 MB, 17 sessions): `projects` / `results` / `doctor --json` | 0.10 s / 0.11 s / 0.06 s |
| Hook latency (synthetic, isolated) | median 39.8 ms, p95 40.8 ms |
| Debug build via script | 29 s wall |
Not measured: startup time of a fresh launch (would start a third copy),
memory growth over days, sleep/wake behaviour.
