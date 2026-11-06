# Phase 14 — Product polish, automatic final screenshots, stable notch UX

Start: `3f2fcab` on `claude/loving-mccarthy-ossw3q` (0.5.0 committed, not
installed; installed app 0.4.1 and the Xcode Debug copy were running, both
left untouched). Nothing installed, no plugin update, nothing pushed.

## 1. What was wrong (reproduced before fixing)

| Defect | Root cause | Reproduced by |
|---|---|---|
| Copy with Context: "Commands" half visible under "Request & answer" | The card's rows sit in a `BoundedScroll(minHeight: 34)`. Details' `PairedRows` caps the top row at max(Task, 32 % of the budget), so on a 14" MacBook (341 pt) the scroll got 35–39 pt: one 22 pt row, 5 pt spacing, and 8–12 pt of "Commands". | `Phase14LayoutTests.testCopyWithContextRowsAreWholeOrHidden` — failed at 330/341/448 pt (`Commands (126…148)` cut by a viewport ending at 134.1 / 137.6) |
| Answer: last line half visible | Same component: the Answer's `BoundedScroll` takes any height the row leaves; nothing aligned that height with text lines. | `testAnswerNeverEndsInAHalfLine` — failed at 330/360/388/410/448/500 pt (e.g. line 265.5…281.5 cut at 274) |
| Island closes when a view needs less height | `applyResize` shrinks the window 0.2 s after the island's own animation. A pointer that had just clicked in the lower part is then outside the window; the tracking area reports *exited*; `NotchInteraction` closes after its 80 ms delay. Not a timer problem: the exit is caused by Prompt Relay's own geometry. | `Phase14HoverTests` (real controller + NSPanel, injected pointer, AppKit tracking emulated) — the island went to `.compact` after the shrink |
| Auto-capture "does not work" | The Phase 9.4 trigger ran only for the single newest *unseen* answer: with the island open (answer acknowledged at once), with two agents finishing, or after any capture failure (the one window was forgotten) nothing happened; the window choice was also lost at every restart. | Code path (`loadReadyAnswer` → `autoCaptureIfEnabled` only inside `if isNewer…unseenAnswers.contains`) |
| Wrong window possible | The Phase 9.4 binding was project + provider + host: two local profiles of Claude, or two Claude Desktop conversations in one project, matched the same window. | Code inspection; covered now by `twoProfilesOfOneProviderNeverShareAWindow`, `twoConversationsInOneAppNeedAnExplicitLink` |

## 2. Fixes

### Layout (`IslandViews.swift`, `Markdown.swift`, `DetailsViews.swift`)
`BoundedScroll` now knows its content's rows and lines: rows report
themselves (`.scrollRow`), Markdown blocks report line geometry
(`ScrollSegment`, line pitch inferred from each block's measured height).
`SnappedHeight` takes the height the parent gives (so cards and the island
keep their size — the adaptive-height tests still hold) and places the
scroll view at the largest height that ends on a row or line boundary; the
few points left stay empty inside the card. Copy with Context shows
"+N more" when rows are below the edge. Attachments rows and the new status
line are rows too. Only presentation changes; copies still use the full text.

### Hover and resize (`NotchController.swift`)
Every frame change of the open island goes through `setExpandedFrame`. A
smaller frame that would leave the pointer outside **waits**: the island is
already drawn at its new size inside the old window; the window takes the
new frame when the pointer reaches the island (`mouseMoved` of the panel's
own tracking area); a real exit from the old area closes it exactly as
before (80 ms); growing, closing or a newer frame replace the wait. No
timer, no polling, close delay unchanged. Keyboard-opened panels (pointer
elsewhere) shrink at once. Applies to Quick Peek ↔ Details width changes too.

### Automatic final screenshots (ADR-028)
Extends the existing pipeline (`WindowCapture`, `SCContentSharingPicker`,
`SCScreenshotManager`, Phase 10 in-memory store). New: `AutoCapture.swift`
(pure rules), `AppModel+AutoCapture.swift` (flow), Settings and Attachments UI.

- **Links.** Settings → Clipboard & Handoff → Automatic final screenshots →
  *Link Window for Open Conversation…*: macOS's picker; the window is linked
  to agent · local profile · host · project of the open conversation. From
  an answer's Attachments: *Link Window…* links one conversation. Several
  links coexist, each removable; memory only. Prompt Relay's own windows are
  excluded from the picker; windows are never listed by Prompt Relay.
- **Trigger.** Every refresh, each final answer (not intermediate, not a
  background wait, not an API error, no pending question/plan/permission)
  that finished after the feature was armed and was not considered yet —
  whether the island is open or not, for every agent.
- **Binding.** Exactly one link must resolve (conversation link first, else
  the agent's link); another conversation active in the last 30 minutes that
  resolves to the same window makes it *Window association required*.
- **Timing.** 0.6 s, capture, 0.8 s, capture; equal pictures end it, else one
  more (max 3 stills, never a stream). A newer final answer for the same
  window cancels the older capture (*superseded*). Off the main thread's
  critical path (async; the hook is never involved).
- **Result.** "Auto screenshot <host> <time>.png", source *auto screenshot*,
  in memory, **unchecked** unless *Include auto screenshots in handoff* is on.
  Preview, Copy Image, Capture Window Again…, Remove. Statuses shown under
  Attachments only when the user can act: pending, permission required,
  window not linked, window unavailable, failed, association required,
  superseded. Expired snapshots show "No longer in memory" (Phase 10).
- **Lifecycle.** Phase 10 limits (12 images, 96 MB, 4 h, oldest first),
  *Clear Temporary Screenshots*, gone at quit. Turning the feature off drops
  links and pending captures; screenshots already taken stay until expiry or
  Clear.

### Context integration
Copy with Context, Context Packs and Drag take an auto screenshot only when
checked; it travels as image data, never a file, and is described as
"auto screenshot of the window the user linked to this agent… it may not
show the answer's last lines" — never as the agent's file. JSON API v1 and
Context Pack format v1 unchanged.

## 3. Verification

*Verified offscreen / with mocks* (this Mac, no live GUI interaction):

| Check | Result |
|---|---|
| Layout regression (rows / lines / attachments / status line) at 268–568 pt | pass (failed before the fix) |
| Hover/resize regression (6 scenarios, real panel) | pass (failed before the fix) |
| Auto-capture: 20 Swift Testing scenarios incl. planner mutation check | pass; disabling the ambiguity or needs-input rule makes 4 tests fail |
| Context Pack with checked / unchecked auto screenshot (real Core) | pass |
| Full XCTest / Swift Testing / Python ×2 / Xcode Debug+Release | see §5 |

*Requires macOS live checks by the owner* — see `ACCEPTANCE_PHASE14.md`:
real mouse movement across the shrinking island, Claude Desktop render
timing, the picker and permission prompts, external displays, minimized
windows, Drag into ChatGPT/Claude.

*Not implemented:* persistent links across restarts (window identity cannot
be verified), OCR or matching the picture to the answer, capture of a
specific tab inside one window.

## 4. Known limits
- A link identifies a **window**, not what it shows: if the user switches
  the conversation shown in a linked Claude Desktop window, the screenshot
  shows what is on screen. Only *other active conversations resolving to the
  same window* are detected.
- ~~While the island waits for the pointer after shrinking, the transparent
  part of its old window still takes clicks~~ — fixed in 14.1 (below). This
  limit was inferred from the code, never observed live.
- 0.6 + 0.8 s settle values come from the hook → Core → FSEvents path, not
  from a measurement inside Claude Desktop; the owner's live check decides
  whether they suffice.

## 5. Results
Final tree: XCTest 302/0 (16 opt-in skips), Swift Testing 122/122, Python 249+15 ×2 (3.14, 3.9), Xcode Debug/Release BUILD SUCCEEDED, `git diff --check` clean. Hook latency median 40.0 ms (plugin launcher 57.8 ms). Planner over 3,000 conversations < 50 ms per decision (test). Capture, PNG encoding and thumbnail run off the main thread. Not measured live: idle CPU, open/transition times and Stop → screenshot latency in the real app (requires an installed build). Version: proposal 0.6.0 for App, Core and plugin (new settings and changed default for auto screenshots); not applied.

## 6. Phase 14.1 (0.6.0)

**Hover-resize without a transparent click trap.** The first fix kept the
larger window until the pointer reached the island; its transparent part
could take clicks meant for the app below. Now the window takes its smaller
frame at once and the vacated strip becomes a *corridor*: the exit our own
edge causes is ignored while the pointer is in the strip; moving onto the
island ends the corridor; leaving the strip, or clicking in it (the click
reaches the app below, no Prompt Relay window covers it), closes the island
with the usual delay. A global + local mouse monitor (moves and presses, no
keys, no permission) runs only during a corridor and stops on enter, exit,
close, growth or app stop. `Phase14HoverTests` (8 tests) replace the first
fix's tests; the new click test cannot pass on the first fix by
construction (its panel still covered the click point).

**Auto screenshot.** One more scenario: two agents finishing in one refresh
each get their own window's screenshot (21 scenarios in total).

**Version 0.6.0** for App (Xcode), Core and plugin; JSON API v1 and Context
Pack format v1 unchanged (pinned by `tests/test_phase12.py`). Hooks are
unchanged since 0.4.1, so the installed 0.4.1 plugin keeps capturing; the
plugin update only aligns versions (owner's decision).
