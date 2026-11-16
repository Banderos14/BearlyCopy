# Phase 10 — product audit, in-memory window snapshots, minimal notch status

2026-11-05. Starting HEAD `6c004a2` on `claude/loving-mccarthy-ossw3q`.
Backup before editing: staged patch, `git status` and a tarball of every
untracked file (the `acceptance/` material) in the session scratchpad
(`backup-phase10-start/`). Nothing staged or untracked was changed, moved or
committed. The running app (`~/Applications/Prompt Relay.app`, PID 87735)
was not replaced, restarted or reconfigured; no hook, plugin, trust record or
Claude Code/Codex setting was touched.

How to read this report: **Verified with mocks** = automated tests on this Mac
with fake Core/pickers; **Measured live** = read-only observation of the
installed app; **Requires the owner at the Mac** = picker, consent, real
paste into another app, pointer and animation feel. Nothing in the last group
is claimed as checked.

---

## What changed in code (Phase 10)

### 1. Window snapshots live in memory only (P0)

Before: Capture Final Window and Auto-capture wrote PNGs into
`<data dir>/app/attachments/` and the attachment index, and every copy/drag
made another copy in `app/handoff/`. Phase 10:

| Step | Now |
|---|---|
| Capture | `SCScreenshotManager` still image of the picked window, longest side capped at 3200 px (`WindowCapture.pixelSize`) |
| Storage | `ReportStore.addEphemeralImage` → process memory: record + bytes. Never in `attachments.json`, never in `attachments/`, never in `handoff/` (tests scan the whole data dir) |
| Limits | 12 snapshots, 96 MB total, 4 h age; oldest dropped first (`EphemeralLimits`) |
| Listing | Same Attachments list, selected by default, "· in memory", thumbnail from memory; Preview note says it is not saved and that a receiving app may keep its own copy |
| Uncheck / Remove | As for any attachment; Remove frees the bytes |
| Copy Image | PNG + TIFF data on the pasteboard, **no file URL** (read back: exact bytes) |
| Copy with Context → hand-off step 2 (Copy Files) | Persistent files as file URLs **plus** each snapshot as an image item in the same write; verified: exact file list and item count |
| Drag (row, Preview, hand-off Drag N) | Image data (`NSPasteboardItem`), no temporary file |
| Copy Answer + images | Text item first, then image items; text read back verbatim |
| Show in Finder / Open in Default App | Not offered for a snapshot (there is no file); a clear message instead |
| Export folder (explicit user action) | The snapshot is written **only** into the folder the user chose |
| Restart | Gone. A saved hand-off that referenced a snapshot is dropped at launch (its IDs are not present), never half-restored |
| Duplicate announcements | One auto-capture per final answer per run (`autoCapturedRefs`), plus same-bytes dedupe per report |

Binding rules from Phase 9.4 are unchanged: auto-capture is off by default,
the window is chosen in macOS's own picker, it is bound to project + agent +
host of the conversation open when chosen, conversations without a recorded
host can never be bound, a gone window drops the choice and never falls back
to another window or the screen.

**Honest limits of "no persistent file".** Prompt Relay itself writes no
file for a snapshot. It cannot promise more than that:
- The general pasteboard is managed by `pasteboardd`; with Handoff enabled,
  Universal Clipboard may send a copied image to the user's other devices.
- The receiving app decides what to do with a paste or drop (browsers
  typically upload the image; Finder writes a file on drop).
- Memory can be swapped to the encrypted swap file by the OS like any app
  memory.
- Receivers that accept *only* file URLs (Finder windows on paste, some
  upload dialogs) get nothing from a pure-data item; for them the user can
  Export, which is an explicit file write.

### 2. The notch's right ear (P0)

Investigation (code, not guessed): the number next to the green dot was the
count of **distinct conversations** that had at least one *final* answer
newer than the first-launch baseline that the user had not opened
individually (`unseenAnswers` → `.ready(sessions:)`). Intermediate Stops were
already excluded in 9.4 (`completion.isFinal`), so "7" was not technical
noise — it was seven conversations (e.g. parallel sessions in other projects)
that the user had never opened one by one. Opening the island cleared only
the conversation shown, so the dot and number lingered indefinitely.

Now:
- Working: three white dots; waiting for background work: three dots in the
  waiting tone (unchanged 9.4 Core Animation keyframes; still with Reduce
  Motion).
- New final answer: one 6-pt green dot, **no number**.
- Opening the island (hover Quick Peek, click, hot key) is looking at Latest:
  the notch dot goes (`notchAcknowledgedAt`, persisted across restart). Only
  a newer final answer lights it again.
- Unread answers of other conversations stay where they belong: Project and
  Session counts and conversation rows (unchanged), and the accessibility
  label still says how many conversations have new answers.
- Capture error: the `!` ring (unchanged).

### 3. Defects fixed in passing

- **Test runs pollute `~/Library/Preferences` — reduced, not solved.**
  10,874 empty `PromptRelayTests.*` / `PromptRelayLayout-*` /
  `PromptRelay9x*` plists (42 MB) had accumulated, because
  `removePersistentDomain` leaves the file. New `removeTestDefaults(_:)`
  removes the domain, synchronizes and deletes the file (only names starting
  with `PromptRelay`/`pr-`); all 38 cleanup sites use it. Measured after one
  full run: **213 new files still appeared** — `cfprefsd` flushes
  asynchronously after the delete, and `PromptRelayLayout-*` suites (layout
  harness) have no cleanup call at all. Proper fix (P1): give `AppModel` /
  `NotchSettings` an injectable in-memory key-value store for tests instead
  of real `UserDefaults` suites. The existing files were not deleted
  (outside the repo; the owner's call) — command at the end of this file.
- Settings text claimed images are stored on disk; now says window snapshots
  stay in memory. Auto-capture's help says so too.
- Two Swift 6 isolation warnings (`backgroundWaitLimit`, new
  `maxPixelSide`) removed.

### Tests added (Swift Testing, `Phase10Tests.swift`)

- `aSnapshotIsListedSelectedAndNeverWritten` — listed, selected, bytes from
  memory, no file URL, same bytes kept once, index without it, no PNG
  anywhere under the data dir, no hand-off copy, gone in a new store
  (restart), removal.
- `limitsDropTheOldestByCountBytesAndAge` — count, age (injected clock),
  byte limit, non-image rejected.
- `pixelSizeIsCappedKeepingTheAspect`.
- `copyImageAndCopyWithImagesUseDataNotFiles` — Copy Image (no file URL),
  text + image in one write (text verbatim), files + snapshot in one write.
- `autoSnapshotReachesTheHandoffWithoutDetailsOrFiles` — final answer →
  one capture despite repeated refreshes → selected → in the hand-off set →
  drag payload is data → uncheck excludes → remove.
- `copyAttachmentOfAnExpiredSnapshotFailsHonestly` — the user's clipboard is
  left alone when the snapshot is gone.
- `openingTheIslandClearsTheNotchButNotPerProjectUnread` — three
  conversations finish; opening clears the notch dot; two remain unread in
  Project and Session; restart keeps it clear; a newer answer lights it.
- Updated: `captureFinalWindowAddsOnlyWhatTheUserPicked` now expects a
  `windowSnapshot` held in memory.

---

## A. Product assessment

**The 30-second test.** The README and the island explain *what* (the final
answer of your coding agent, verbatim, one click to copy with its context)
but a newcomer still has to learn three things before it is useful: that
capture is opt-in per project, that Claude Code needs a plugin and Codex a
hook profile, and that "Copy with Context" is the main action. The notch
itself says nothing until the first capture arrives — an empty island with
"No answers yet" is the first impression for most users.

**The real advantage over Copy/Paste** (measured against the code, not
marketing):
1. The text is the agent's last message *verbatim*, captured by a hook — no
   selecting in a terminal or chat pane, no lost Markdown, no truncation.
2. Copy with Context adds the request, project, agent · host, completion
   state and observed files with provenance labels (*Reported by Claude* vs
   *Confirmed locally*). That is the part a human would not type.
3. Background-work awareness: an answer is not "ready" while tests it started
   are still running (9.4). No comparable tool in this space does this.
4. Attachments the agent verifiably wrote are pre-selected; window snapshots
   now ride along without becoming files.

**Workflow cost** (AI-agent → final answer → Prompt Relay → other AI):
hover notch (≈0.3 s) → Copy with Context (1 click) → paste in the other AI
(⌘V) → for files/snapshots: hand-off step 2 (1 click) → paste/drag again.
Text-only: 2 actions. With images: 4. The error-prone part is the second
paste: most web AIs accept pasted images but not file URLs, and none accept
text + images reliably in one paste. That is why the two-step hand-off
exists; it is the honest design, not a workaround to remove.

**What is redundant or under-used** (from the inventory below): Review
Checklist + Evidence Check + Artifact Completeness overlap (three surfaces
for "what can the receiver trust"); Recent Copies duplicates History for most
users; Mockup States is a niche flow; four "Copy" variants (Answer, Answer +
images, with Context, Export) are more than most people need.

**Missing for a developer who switches agents daily:** a first-run setup
that ends in a real capture; a per-conversation "unread" list reachable in
one click from the notch; a keyboard flow (hot key → Copy with Context →
dismiss) advertised in the UI; a clear "connected agents" status.

**At hundreds of users:** setup failures (Python path, plugin not updated,
Codex profile not trusted) will dominate support; logical-project detection
will meet monorepos and worktrees; history growth needs retention defaults;
host detection varies by IDE; unsigned builds will not open.

## Feature inventory

| Area | Implemented | Automated tests | Live-verified | Risk / note |
|---|---|---|---|---|
| Notch / collapsed | yes | many (NotchController, Island*) | owner, earlier phases | multi-display edge cases |
| Living Relay bear | yes (display link, CA layers) | RelayMotion, Phase72 | owner, earlier | keep; see §D |
| Quick Peek | yes | yes | owner | — |
| Details (+remembered) | yes | yes incl. reopen geometry | 9.4 fix not re-run live | §D owner check |
| Task / Full Task | yes | yes | owner | — |
| Answer carousel (final-only) | yes | Phase94 | partly | — |
| Project and Session, conversations | yes | Phase93/94 | partly | large histories untested live |
| History / search | yes | yes | owner | perf with 1000s of turns not measured |
| Observed Work / Commands | yes | yes | owner | — |
| Failure Inspector | yes | yes | — | overlaps Evidence |
| Evidence / Completeness / Checklist | yes | yes | — | consolidate (P1) |
| Copy Answer / with Context | yes | yes | owner (Desktop) | — |
| Preview / Markdown Source | yes | yes | owner | — |
| Attachments (MD/PDF/PNG) | yes | yes | partly | — |
| Window snapshot (manual, auto) | yes, now in memory | yes (mocks) | **no** | picker/consent/stored-filter lifetime |
| Clipboard image history | yes, opt-in | yes | owner | — |
| Persistent Handoff | yes | yes | partly | snapshots not restored (by design) |
| Settings / Integrations | yes | partly | owner | structure §11 |
| Claude Code adapter | yes (plugin) | Python | yes | host needs plugin update |
| Codex adapter | yes (hook profile) | Python | stored events, no full final Stop | §G |
| Follow Latest / pinned | yes | yes | owner | — |
| Background completion | yes | Python + Swift | observed contract | 2 h expiry heuristic |
| Unread indicators | yes, simplified | yes | no | owner check |
| External / notchless displays | yes (floating island) | NotchGeometry tests | owner earlier | — |
| Import AI Result | yes | yes | — | niche |

## B. Technical assessment

- **Architecture**: hook → Python Core (stdlib, JSONL, file locks) → JSON
  API v1 → Swift app (`AppModel` observes FSEvents). Clean separation and
  invariants enforced by tests. `AppModel.swift` (2.2 k lines) and
  `IslandViews.swift` (2 k) are the maintainability hot spots; splitting
  them is P1, not a rewrite.
- **Adapters**: `plugin/prompt_relay/adapters.py` normalizes provider
  payloads into one event shape (`provider`, `environment` = host). Adding a
  provider is one function plus tests; the Core's turn/completion logic is
  provider-neutral except Claude's `background_tasks` contract, which is
  expressed as `completion` and degrades to "unknown" elsewhere. Good enough
  for the next provider; no rewrite before release.
- **Hook cost** (measured, `check.sh`): median 39 ms, p95 47 ms direct;
  56/62 ms via the plugin launcher. Never blocks the agent beyond that.
- **Idle cost of the installed app** (measured live, `top`, 6 × 2 s):
  0.0–0.7 % CPU, 46 MB footprint, 6 threads, 124 MB RSS. No timer spin.
- **Storage**: Core history in the app data dir; app data in `app/`
  (0700/0600). Snapshots now never touch it.
- **Background work**: 2 h expiry for "waiting" is a heuristic; correct for
  test runs, wrong for long builds (then shown as "Completion unknown", never
  as ready — the safe side).

## C. Screenshot assessment

- **Works (mocks)**: everything in the table in §1.
- **Where the image lives**: Prompt Relay's process memory until removed,
  expired (4 h), evicted (12 / 96 MB) or the app quits.
- **System limits**: see "Honest limits" above. `SCContentSharingPicker`
  (macOS 14+) shows the system picker; the selection is the user's consent.
  Whether a filter from a finished picker session stays valid for later
  auto-captures across a long session, after the window moves Spaces, or
  after macOS revokes access, is **not verified** — Phase 9.4 already drops
  the choice on any failure, so the failure mode is "no snapshot", never a
  wrong one.
- **ChatGPT / Claude / Gemini**: browser chat UIs generally take a pasted
  image from the paste event's image data; this is **not verified here** for
  any of them, and neither is a mixed text+image paste in one ⌘V. Hence: text first,
  images second (or drag). **Not tested live in Phase 10.**
- **Ambiguity**: two windows of the same app in one project cannot be told
  apart; the user's chosen window is used, and other agents/hosts are never
  captured. When no binding exists, nothing is captured and the manual
  Capture Final Window remains.

## D. UX/UI assessment

Read from code and earlier owner screenshots; no new live pointer session in
Phase 10.

- **Hierarchy**: Answer text is primary; status lines are long. Source line
  "Claude Code · Claude Desktop · This Mac" + time + completion chip compete
  in one row in Quick Peek; P1: drop "This Mac" in compact contexts (it is
  the only possible value today).
- **Cards/radii**: `Island.cardRadius` and pill styles are consistent;
  several ad-hoc 5/7-pt radii in rows (DetailsViews) — unify in Phase 11.
- **Type**: 10–12.5 pt sizes; 10 pt secondary lines are below comfortable
  reading on non-Retina external displays. P1: 11 pt minimum.
- **Hit targets**: Settings and row menus use 24–30 pt rows; the
  attachment `ellipsis` menu is ~16 pt wide — P1: 24 pt.
- **Help text**: Settings descriptions are long paragraphs (Relay, Display,
  Auto-capture). P1: one sentence + "More" disclosure.
- **Indicator**: now minimal (§2).
- **Details → leave → collapse → enter → Details**: fixed in 9.4 with a
  regression test across five opening paths (first frame included).
  Owner check still listed below.
- **Motion**: spring `response 0.35, damping 0.62` for the indicator is
  slightly bouncy for a status dot; recommend `0.3 / 0.85` (critically
  damped feel) — not changed without a live comparison. Island open/close
  values are measured in earlier phases; no new measurements in Phase 10,
  so no changes proposed with numbers here.
- **Relay**: keep the character. It renders on a display link only while
  something moves (Phase 7.2); idle CPU above confirms no constant render.

## E. Security & privacy

- Hooks: unchanged invariants (no stdout, exit 0, no network, no
  transcripts). Prompt Relay never writes Claude/Codex settings.
- Snapshots: user-initiated window choice only, system picker, bound to
  agent+host+project, memory-only, bounded, never in logs or the repo.
- Clipboard: writes are read back; a failed copy leaves the user's clipboard
  as it was (tested for snapshots); the clipboard image history ignores
  Prompt Relay's own writes.
- Data dir permissions 0700/0600; captured text never in the repo
  (`test_s17`).
- Found, reduced, not yet solved: test-suite preference pollution (not user
  data, but 42 MB of empty plists in the developer's Library).

## F. Release readiness

**A. GitHub Release (recommended first)** — Developer ID Application
certificate; Hardened Runtime; notarization (`notarytool`) and stapling;
a signed DMG or zip; the bundled Core needs a Python ≥3.9 at runtime (CLT
`/usr/bin/python3` triggers the CLT install prompt on a clean Mac — P0 for
release: detect and explain, or bundle a relocatable interpreter after an
ADR); plugin installed by the user via `claude plugin` (ADR-008); Codex
profile via the existing configure script with consent; updates: start with
GitHub release notes + manual download, Sparkle later (EdDSA-signed feed);
privacy statement (no network) in README; LICENSE; crash reporting: none
(no network) — rely on user-submitted diagnostics export; support: issue
templates.

**B. Mac App Store** — conflicts with the current architecture:
App Sandbox forbids reading `~/.claude`/`~/.codex` and the Core's data dir
outside the container, launching an external Python, and installing hook
helpers. A Store build would need the hook to write into an App Group
container and a Swift-native Core, plus `com.apple.security.files.user-
selected` for project folders. ScreenCaptureKit picker and NSPasteboard are
Store-compatible. Acceptance is not predictable; treat as a later, separate
product variant ("Later"), not a release blocker.

## G. Checks

All run on this Mac (macOS 27.0, arm64). Logs in `macos/acceptance/phase10/`
(not committed).

| Check | Result | Exit |
|---|---|---|
| `scripts/check.sh` (Python 3.14) | 200 + 15 tests OK, 1 skipped (no-Python launcher path, Linux-only) | 0 |
| `scripts/check.sh` with `/usr/bin/python3` 3.9.6 and 3.11.14 | 200 + 15 OK each, 1 skipped | 0 |
| Hook latency (50 synthetic Stops) | median 39.1 ms, p95 46.7 ms; plugin launcher median 56.5, p95 61.8 | — |
| `swift test`, first full run | Swift Testing 54/54 passed; XCTest 271, **1 failure**: `testEveryFillImageHasAContentShape` expected 3 `.fill` sites, found 4 — the new snapshot thumbnail (it has the content shape). Guard updated to 4 | 1 |
| `swift test`, second full run | XCTest 271, 16 skipped, 0 failures; Swift Testing 54/54 | 0 |
| Skipped XCTests (16) | all env-gated by design: `PROMPT_RELAY_VISUALS` ×6, `_SNAPSHOT_DIR` ×3, `_AUDIT_DIR`, `_AUDIT_SESSION`, `_E2E`, `_PASTE_TEST`, `_PERF`, `_REAL_DIALOG`, `_REAL_RENDER` — so the perf and real-render probes did **not** run | — |
| `xcodebuild` Debug / Release (isolated DerivedData) | BUILD SUCCEEDED | 0 / 0 |
| `git diff --check` | clean | 0 |
| Idle CPU/memory of installed app (live, read-only) | 0.0–0.7 % CPU, 46 MB | — |

Every snapshot, clipboard and indicator check above is **mocked or
offscreen** (fake Core, fake capturer, private named pasteboards — the
system clipboard was never written by tests). Not measured: CPU during
Relay animation, 120 Hz frame pacing, memory with 12 large snapshots.

Live acceptance not done in Phase 10 (needs the owner): real picker and
consent; snapshot paste into ChatGPT/Claude/Gemini; drag of a snapshot into
a browser; notch dot clearing on hover; Reduce Motion; external display;
real Codex final Stop; background-test chain against this build.

## H. Git

See "Git" at the end.

## I. Roadmap

| Priority | Problem or improvement | User value | Effort | Phase |
|---|---|---|---|---|
| P0 | Owner live acceptance of snapshots (picker, consent, stored filter lifetime, paste/drag into 3 web AIs) | the P0 feature is unproven live | S | 10 acceptance |
| P0 | Signed + notarized build, Hardened Runtime | anyone else can open it | M | 11 |
| P0 | Python availability on a clean Mac (CLT prompt) | first run works | M (ADR) | 11 |
| P0 | Setup check that ends in a real capture ("Send a test prompt") | users reach value without docs | M | 11 |
| P1 | Setup Wizard: agents found → plugin/profile status → enable project → first capture → optional window binding | removes "Action required" guessing | L | 11 |
| P1 | Settings restructure (below) + one-sentence help | comprehension | M | 11 |
| P1 | Merge Evidence / Completeness / Checklist into one "What the receiver can trust" | less UI | M | 11 |
| P1 | Unread list one click from the notch (Project and Session filtered to unread) | multi-agent days | S | 11 |
| P1 | 11-pt minimum text, 24-pt hit targets, unified radii | accessibility | S | 11 |
| P1 | Split `AppModel`/`IslandViews` | maintainability | M | 11 |
| P1 | In-memory defaults for tests (stop plist leaks) | contributor hygiene | S | 11 |
| P1 | "Keep snapshot" (explicit save into the report) | users who want history | S | 11 |
| P2 | Retention defaults for history (size/age) | long-term use | S | 12 |
| P2 | Another provider adapter (Gemini CLI) using the existing normalize() | broader audience | M | 12 |
| P2 | Sparkle updates | convenience | M | 12 |
| Later | Mac App Store variant (App Group + Swift Core) | distribution | XL | later |
| Later | Per-conversation window binding | precise snapshots | M | later |
| Do not build | Automatic screen capture without a user-chosen window | privacy risk, wrong-window risk | — | — |
| Do not build | Cloud sync / accounts | breaks "nothing leaves this Mac" | — | — |
| Do not build | Faking a single text+image paste for apps that do not support it | dishonest success | — | — |

### Settings structure proposal (for Phase 11)

Current: Display · Appearance · Notifications · Behavior · Privacy ·
Advanced · About. Proposed: **General** (open on hover, display, other notch
apps, notifications) · **Appearance & Motion** (theme, Relay, motion) ·
**Agents & Projects** (Claude Code / Codex status, projects, capture switch —
today split between Advanced and Capture) · **Handoff** (Follow Latest vs
stay, auto-select result files, auto-capture window, clipboard history) ·
**Privacy** · **Diagnostics** (Core, Python, doctor) · **About**. "Idle
moments" and "Follow the pointer" can move under a Relay disclosure.

## Phase 11 proposal

Goal: a signed `.app` someone else can install and use in five minutes.
1. Packaging: Developer ID signing, Hardened Runtime, notarization, DMG,
   version/commit in About, a clean-Mac first run (Python decision via ADR).
2. Setup Wizard (spec: detect agents read-only → show the exact `claude
   plugin` / Codex profile step with Copy buttons → verify with doctor →
   enable a project → "send any prompt" → first capture celebrated →
   optional window binding). Never edits other tools' config itself.
3. Settings restructure and copy pass (above).
4. Visual consistency: radii, type floor, hit targets, compact source line.
5. Motion pass with measurements on 60/120 Hz (open/close, indicator spring).
6. Consolidate trust surfaces; trim Copy variants.
7. README for strangers: one GIF, three steps, privacy statement.

Not started.

---

## Owner acceptance checklist (Phase 10 build, ~10 min)

1. Settings → Behavior → Auto-capture final window → On → Choose Window… →
   pick the Xcode/Claude window in the macOS picker. Does macOS ask for
   consent? Note what it shows.
2. Let that agent finish a task. Attachments shows "Final window … · in
   memory", checked. Quick Peek → Copy with Context → paste text in ChatGPT
   → hand-off Copy Files → paste: does the image arrive?
3. Drag the snapshot from Attachments into a browser chat. Arrives?
4. `ls ~/Library/Application\ Support/*/app/attachments` (or the data dir)
   shows no new PNG.
5. Quit and reopen Prompt Relay: the snapshot is gone, nothing else lost.
6. Finish answers in two conversations; the notch shows one green dot, no
   number; hover opens Quick Peek; the dot disappears; Project and Session
   still marks the other conversation.
7. Details → move away → back: full Details, no clipped footer.
8. Reduce Motion on: dots are still.

Optional cleanup of old test preference files (generated by earlier test
runs, names start with `PromptRelayTests.`, `PromptRelayLayout-`,
`PromptRelay9`; review the list first):

```bash
ls ~/Library/Preferences | grep -E '^(PromptRelayTests\.|PromptRelayLayout-|PromptRelay9[0-9a-z.]*\.|PromptRelay10[a-z]\.|PromptRelayPerf\.)' | wc -l
```

---

## Git

- Branch `claude/loving-mccarthy-ossw3q`; start `6c004a2`.
- `d8cc33f` — code and tests (17 source files, 21 test files incl. new
  `Phase10Tests.swift`).
- The docs commit that adds this file (`PHASE10.md`, `docs/STATUS.md`,
  `docs/DECISIONS.md` ADR-018) follows it; see `git log`.
- Not committed, left exactly as found: the staged
  `macos/acceptance/phase9.1/xcode-smoke/REPORT.md` and every untracked
  `macos/acceptance/` item; the new logs in `macos/acceptance/phase10/`.
- No push, no merge, no install.
