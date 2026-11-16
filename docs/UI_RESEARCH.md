# macOS UI — research notes

Status: desk research from the cloud (2026-10-29), followed by the Phase 3B
decision on the Mac (below). The notch UI is implemented with a custom
NSPanel + SwiftUI (ADR-010, `docs/MACOS_APP.md` §2B).

## Phase 3B decision (2026-10-29, on the Mac)
| Criterion | OpenNook | Custom NSPanel + SwiftUI (chosen) |
|---|---|---|
| Integration | owns the app entry point (`NookApp.main`), would replace our App/MenuBarExtra lifecycle | a controller next to the existing app; reuses AppModel, CoreClient, ClipboardService, StoreWatcher |
| API stability | pre-1.0, no stability policy, empty Releases page | our own small API, covered by tests |
| Minimum macOS | 15 | 14 (our target) |
| License | Apache-2.0 + MIT (NookSurface) — fine, but a dependency | none |
| Hover / animation | built in | NSTrackingArea + SwiftUI shape morph; no polling |
| Multi-display / no notch | notch-fused or floating capsule; display choice | one island on the chosen notched display; menu-bar item elsewhere |
| Reuse of existing UI | its own view tree | the same model and components |

Reference studied: **Coucou** (`Louis-CFM/coucou`, the app installed as
NotchBuddy), code under the MIT license; its name, character, icons and
sounds are all rights reserved (LICENSE-ASSETS) and none were used. No Coucou
code was copied. Techniques compared: Coucou keeps a fixed 720 × 560
transparent NSPanel at `mainMenu + 3`, polls the pointer at 8/20/60 Hz and
toggles `ignoresMouseEvents`; Prompt Relay instead resizes its panel to the
island for each phase and uses a tracking area, so it costs nothing while
idle. Both override `constrainFrameRect` so AppKit keeps the panel in the
menu-bar band. Coucou's compact state adds 80 pt ears; Prompt Relay uses
26 pt.

## Planned interface
Notch / Dynamic-Island-style panel that opens on hover: compact Claude status,
a completion indicator, project and session pickers, a full-response preview,
**Copy Response**, **Copy Context**, history and settings. A menu-bar item
serves as the fallback on displays without a notch.

## Candidate foundations
| Project | License | Notes from public sources | Fit |
|---|---|---|---|
| **OpenNook** (`athledev-labs/opennook`, formerly `twinkling-reality/opennook`) | Apache-2.0. The `NookSurface` component is MIT (separate `LICENSE-MIT-NOOKSURFACE`) | A framework, not an app. Provides the notch window, hover expand/collapse, backdrop, settings shell, global hotkey (⌥⌘;) and a compact pill. Layout is notch-fused on notched panels and a floating capsule elsewhere, which covers the no-notch fallback. Swift 5.9+, **macOS 15+**. README: "a base layer plus a working demo — not a finished product". Release notes: public API **not frozen** (v0.4.0 latest seen) | Best candidate. Apache-2.0 is compatible with a closed or open product if the NOTICE and license texts are kept. Risk: API churn, and the macOS 15 minimum |
| boring.notch (`TheBoredTeam/boring.notch`) | GPL-3.0 | A full app (media, calendar, shelf, HUD replacement). macOS 14.2+ | Copying code would force GPL on Prompt Relay. Reference only |
| MewNotch, DynamicNotch | GPL-3.0 | Apps | Reference only |
| NotchDrop (`Lakr233/NotchDrop`) | MIT | A file-drop shelf app | Permissive; a small reference for notch window geometry |
| DynamicNotchKit (`MrKai77/DynamicNotchKit`) | check its LICENSE before use | A SwiftUI package for notch-style popovers | Alternative to OpenNook; evaluate in Phase 4 |

## Evaluation checklist for Phase 4 (on the Mac)
- Supported macOS versions vs our minimum (decide macOS 14 vs 15).
- Dependencies (should be zero or Apple-only).
- License texts and NOTICE handling; no GPL code copied.
- Idle CPU (target ≈0 % when collapsed), memory footprint (target < 50 MB
  RSS), wake-ups.
- Multi-monitor: notch display vs external displays, display arrangement
  changes, fullscreen apps, Stage Manager.
- Fallback without a physical notch (external display, older MacBooks).
- Accessibility: VoiceOver labels, keyboard access, Reduce Motion.

## macOS APIs likely needed
- `NSPanel` (non-activating, `.statusBar`/`.mainMenu + 1` level) for the notch
  window. `NSScreen.safeAreaInsets` and `auxiliaryTopLeftArea` /
  `auxiliaryTopRightArea` (macOS 12+) for notch geometry.
- `NSTrackingArea` for hover; SwiftUI for content; `NSStatusItem` for the
  menu-bar fallback.
- `NSPasteboard.general.clearContents()` + `setString(_:forType: .string)`
  for copying. The app should also mark copies as transient for clipboard
  managers (`org.nspasteboard.TransientType` /
  `org.nspasteboard.ConcealedType` conventions) when the user opts in.
- File watching of the data dir (`DispatchSource.makeFileSystemObjectSource`
  or FSEvents) to show "response ready" without polling.
