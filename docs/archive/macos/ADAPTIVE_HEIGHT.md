# Adaptive island height — 2026-11-05

## Cause and implementation

The original root HeightBudget clamped its reported size to the ordinary
content budget, even when the Clipboard notice and fixed controls needed more
space. NotchLayout applied the same ordinary ceiling to NSPanel. The notice
could therefore push the footer past the visible outline.

The ordinary budget and Warm Cocoa metrics remain unchanged. Visible additions
publish their intrinsic, width-dependent height via `islandExtraHeight`:
Clipboard notice plus its stack gap; copy warning plus its gap; Persistent
Handoff minus the existing normal action row it replaces. Unique IDs avoid
double counting, and removing a block removes its contribution.

The proposed body budget is now:

`min(ordinaryBudget + measuredAdditions, visibleScreenBudget - tooltipHeight)`

The window follows the height actually used, including tooltip space; it does
not allocate the whole budget to short content. The visible screen budget uses
NSScreen.visibleFrame's bottom (including the Dock). If fixed content cannot
fit, a stable outer ScrollView makes all rows reachable; existing Answer/Task
scroll views remain functional. The view hierarchy is retained across resizes.

Measurement uses intrinsic vertical sizes, a stable width and a proposal
independent of the animated window. Reports are rounded and deduplicated.
AppKit frame changes remain deferred/coalesced outside the SwiftUI layout pass.
The top edge, horizontal center and width remain fixed. Growth reserves window
space before animating the visible outline; shrink releases it after the same
180 ms animation. Reduce Motion applies the frame immediately without a
delayed shrink. The initial viewport does not request maximum height before
its first measurement. Pointer-exit and pinning logic are unchanged.

## Files in this change

- `Sources/PromptRelayKit/Notch/AdaptiveIslandHeight.swift`: reusable measurement and bounded viewport.
- `DetailsViews.swift`: notice, copy-warning and handoff contributions; Reduce Motion for handoff.
- `IslandViews.swift`: overflow-aware HeightBudget and Peek handoff animation.
- `NotchViews.swift`: integrates the viewport and visible additions.
- `NotchController.swift`: adaptive budget and NSPanel size coordination.
- `NotchGeometry.swift`: screen/Dock limit and measured extra-height allowance.
- `Tests/PromptRelayKitTests/AdaptiveIslandHeightTests.swift`: offscreen regression matrix.
- `Tests/PromptRelayKitTests/IslandLayoutTests.swift`: nested scroll discovery, host limits and updated handoff-height contract.

## Rendered results

Actual NSHostingView/NSWindow offscreen PNGs, ordinary long-answer fixture:

| Body budget | Ordinary panel | Clipboard banner | After OK | After Turn Off | Width |
| --- | --- | --- | --- | --- | --- |
| 268 pt | 300 pt | 372 pt | 300 pt | 300 pt | 640 pt |
| 341 pt | 373 pt | 451 pt | 373 pt | 373 pt | 640 pt |
| 448 pt | 480 pt | 558 pt | 480 pt | 480 pt | 640 pt |

The 32 pt band is included. The 72/78 pt increments are measurements, not fixed
allowances. Quick Peek's current fixture is 167 pt and is compared directly
with the pre-change HeightBudget layout. An older acceptance artifact used
175 pt with a different bottom inset; it is not the current layout baseline.

Renders and logs: `acceptance/adaptive-height/`. Includes ordinary Details,
banner, both dismissal handlers, both Reduce Motion states, Quick Peek,
stacked notice/warning/handoff, constrained-screen views before/after scrolling,
and reachable Copy buttons at 268/341/448 pt.

## Verification and boundaries

The new tests verify intrinsic-height increments, unchanged Answer height,
footer containment, non-overlap, dismissal restoration, stable firstResponder,
deduplicated resize requests, fixed top/center, Dock limits and no maximum-height
flash on initial Peek. Existing geometry, pointer lifecycle, tooltip and handoff
regressions are also exercised. OK/Turn Off are invoked through the same model
handlers as the buttons; these are offscreen tests, not physical mouse clicks.

Final full `swift test` exited 0: 269 XCTest cases, 16 skipped, zero failures
(253 passed), plus all 22 Swift Testing tests in 8 suites passed. The dedicated
offscreen render run passed all 3 adaptive-height tests. Xcode BuildProject
succeeded, and `git diff --check` passed.
An initial full run exposed a legacy assertion forbidding any temporary handoff
growth. It now checks the measured replacement-row increment and restoration
on dismissal. No visual design padding was changed to satisfy that assertion.

Remaining live-screen checks: subjective animation smoothness during rapid
banner toggles, trackpad/keyboard scrolling at the screen cap, and pointer exit
while the native panel is resizing. The app was built, not installed or launched
by this task, to avoid touching live clipboard-history settings or user data.

## Preservation

Starting dirty/untracked files (193 paths) were backed up to
`/tmp/prompt-relay-before-adaptive-height.zip`, with starting status and a binary
tracked diff alongside it. Hash comparison confirmed those existing files were
unchanged by this task. Earlier Phase 9.2 work remains in the working tree.
No capture, hook, agent configuration, session history or system clipboard
changes were made by this implementation. Tests use temporary stores, isolated
UserDefaults suites and named pasteboards. No commit, push, merge, reset or clean.
