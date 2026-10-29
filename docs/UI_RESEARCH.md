# Future macOS UI — research notes (no UI is implemented)

Status: desk research only, done in the cloud on 2026-10-29. Nothing here was
built or run. Every performance or compatibility statement below must be
re-checked on a Mac in Phase 3/4.

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
