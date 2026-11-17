import AppKit
import CoreGraphics

/// What the notch layout needs to know about one display. A value type, so
/// layouts can be computed and tested without real screens.
public struct ScreenDescriptor: Equatable, Sendable {
    public let displayID: UInt32
    public let name: String
    public let isBuiltIn: Bool
    /// Global AppKit coordinates (origin bottom-left of the primary display).
    public let frame: CGRect
    /// Work area excludes a visible Dock. Used only for the growth ceiling.
    public let visibleFrame: CGRect
    /// Height of the top safe area: > 0 only on displays with a camera housing.
    public let safeAreaTop: CGFloat
    /// Menu-bar areas left and right of the notch (`NSScreen.auxiliaryTop…Area`), global coordinates.
    public let auxiliaryTopLeft: CGRect?
    public let auxiliaryTopRight: CGRect?
    /// Height of the menu bar on this display (where the floating island hangs).
    public let menuBarHeight: CGFloat

    public init(displayID: UInt32, name: String, isBuiltIn: Bool, frame: CGRect, safeAreaTop: CGFloat,
                auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?, menuBarHeight: CGFloat = 24, visibleFrame: CGRect? = nil) {
        self.displayID = displayID
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
        self.menuBarHeight = menuBarHeight
    }

    /// The camera housing, in global coordinates, or nil on displays without one.
    public var notchRect: CGRect? {
        guard safeAreaTop > 0, let left = auxiliaryTopLeft, let right = auxiliaryTopRight,
              right.minX > left.maxX else { return nil }
        return CGRect(x: left.maxX, y: frame.maxY - safeAreaTop, width: right.minX - left.maxX, height: safeAreaTop)
    }

    public var hasNotch: Bool { notchRect != nil }

    /// The same display with a camera housing of the given size at the top
    /// center. Used when the built-in display reports no safe area (a
    /// transient or menu-bar-less state) although its notch was seen before.
    public func withNotch(width: CGFloat, height: CGFloat) -> ScreenDescriptor {
        let left = CGRect(x: frame.minX, y: frame.maxY - height, width: (frame.width - width) / 2, height: height)
        let right = CGRect(x: left.maxX + width, y: left.minY, width: left.width, height: height)
        return ScreenDescriptor(displayID: displayID, name: name, isBuiltIn: isBuiltIn, frame: frame, safeAreaTop: height,
                                auxiliaryTopLeft: left, auxiliaryTopRight: right, menuBarHeight: menuBarHeight,
                                visibleFrame: visibleFrame)
    }
}

extension ScreenDescriptor {
    /// Reads a live `NSScreen`. `auxiliaryTop…Area` are in the screen's own
    /// coordinates on some releases and global on others; both cases are
    /// normalized to global coordinates here.
    @MainActor
    public init(_ screen: NSScreen) {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let frame = screen.frame
        func global(_ rect: CGRect?) -> CGRect? {
            guard let rect, !rect.isEmpty else { return nil }
            if frame.contains(CGPoint(x: rect.midX, y: rect.midY)) { return rect }
            return rect.offsetBy(dx: frame.minX, dy: frame.minY)
        }
        self.init(displayID: id, name: screen.localizedName, isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                  frame: frame, safeAreaTop: screen.safeAreaInsets.top,
                  auxiliaryTopLeft: global(screen.auxiliaryTopLeftArea),
                  auxiliaryTopRight: global(screen.auxiliaryTopRightArea),
                  menuBarHeight: max(0, frame.maxY - screen.visibleFrame.maxY), visibleFrame: screen.visibleFrame)
    }
}

/// Which display the notch surface uses.
public enum DisplayChoice: Hashable, Sendable {
    /// The first display with a notch (the built-in one first).
    case automatic
    /// A specific display: at its notch, or floating below its menu bar when
    /// it has none; while it is disconnected, Automatic is used.
    case display(UInt32)

    public static func pick(_ choice: DisplayChoice, from screens: [ScreenDescriptor]) -> ScreenDescriptor? {
        switch choice {
        case .automatic:
            let notched = screens.filter(\.hasNotch)
            // The built-in display is the notch's home even when it is not the
            // "main" display (an external monitor with the menu bar) and even
            // while macOS momentarily reports no safe area for it: never fall
            // through to whichever display happens to be first.
            return notched.first(where: \.isBuiltIn) ?? screens.first(where: \.isBuiltIn) ?? notched.first
        case .display(let id):
            // Phase 7.2: a chosen display without a notch gets the floating
            // island there (it used to return nil, and the island then
            // appeared on the first screen instead of the chosen one).
            if let screen = screens.first(where: { $0.displayID == id }) { return screen }
            // The chosen display is disconnected: fall back to automatic, so
            // unplugging an external display never leaves the user without the notch.
            if !screens.contains(where: { $0.displayID == id }) { return pick(.automatic, from: screens) }
            return nil
        }
    }
}

/// Window frames for each phase, in global coordinates. Pure: computed only
/// from a `ScreenDescriptor`.
///
/// The window always matches the island it shows, so the transparent area
/// that could swallow clicks is never larger than the island itself.
public struct NotchLayout: Equatable, Sendable {
    /// The camera housing; for the floating island, a zero-width band below
    /// the menu bar where the island hangs.
    public let notch: CGRect
    /// Resting state with an indicator: the notch plus two small ears.
    public let compact: CGRect
    /// The widest and tallest expanded island (x, width, top edge).
    public let expanded: CGRect
    /// No camera housing on this display: the island floats below the menu
    /// bar, rounded on every side, and has no resting hover target.
    public let isFloating: Bool
    /// Tallest content below the band on this display; longer content scrolls.
    public let maxVisibleContentHeight: CGFloat
    public let maxContentHeight: CGFloat
    /// Quick Peek's width on this display.
    public let peekWidth: CGFloat
    let screenTop: CGFloat

    /// Width of each ear beside the camera housing in the compact state.
    public static let earWidth: CGFloat = 38
    /// Height of the chin under the notch that holds the resting bear and
    /// indicator (the bear's pose budget is 32 pt tall).
    public static let chinHeight: CGFloat = 32
    /// Details on a MacBook (Phase 5): wider than Phase 4's 480, but low.
    public static let expandedWidth: CGFloat = 640
    /// Details on a large display (≥ 1700 pt wide).
    public static let wideExpandedWidth: CGFloat = 680
    /// Quick Peek: compact, two copy buttons and a few facts.
    public static let peekWidth: CGFloat = 520
    public static let widePeekWidth: CGFloat = 560
    /// Displays at least this wide get the wider widths.
    public static let wideDisplay: CGFloat = 1700
    public static let minContentHeight: CGFloat = 56
    /// Ordinary content is no taller than this (band included)…
    public static let maxIslandHeight: CGFloat = 480
    /// …nor than this share of the display height below it (Phase 5: ≤ 38 %).
    public static let maxScreenShare: CGFloat = 0.38
    /// Short displays still get room for the task, a few answer lines and the actions.
    public static let minIslandHeight: CGFloat = 300
    /// Gap between the menu bar and the floating island.
    public static let floatingGap: CGFloat = 6
    /// Margin around the island inside the window. Zero: the island has no
    /// shadow (like the hardware notch), so the window is exactly the island
    /// and nothing semi-transparent or grey surrounds it.
    public static let shadowInset: CGFloat = 0

    public init?(screen: ScreenDescriptor) {
        guard let notch = screen.notchRect else { return nil }
        self.init(notch: notch, top: screen.frame.maxY, screen: screen.frame, visibleBottom: screen.visibleFrame.minY, floating: false)
    }

    /// The fallback on a display without a notch: the same island, centered
    /// below the menu bar.
    public init(floatingOn screen: ScreenDescriptor) {
        let top = screen.frame.maxY - screen.menuBarHeight - Self.floatingGap
        let band = CGRect(x: screen.frame.midX, y: top - 32, width: 0, height: 32)
        self.init(notch: band, top: top, screen: screen.frame, visibleBottom: screen.visibleFrame.minY, floating: true)
    }

    private init(notch: CGRect, top: CGFloat, screen: CGRect, visibleBottom: CGFloat, floating: Bool) {
        self.notch = notch
        screenTop = top
        isFloating = floating
        compact = notch.insetBy(dx: -Self.earWidth, dy: 0)
        let wide = screen.width >= Self.wideDisplay
        let preferred = wide ? Self.wideExpandedWidth : Self.expandedWidth
        let islandWidth = min(max(preferred, notch.width + 2 * Self.earWidth + 40), screen.width - 40)
        peekWidth = min(max(wide ? Self.widePeekWidth : Self.peekWidth, notch.width + 2 * Self.earWidth + 40), islandWidth)
        let width = islandWidth + Self.shadowInset * 2
        let available = ((top - screen.minY) * Self.maxScreenShare).rounded()
        let floor = min(Self.minIslandHeight, (top - screen.minY) * 0.6)
        let height = max(notch.height + Self.minContentHeight, min(Self.maxIslandHeight, max(available, floor)))
        maxContentHeight = height - notch.height
        maxVisibleContentHeight = max(0, top - max(screen.minY, visibleBottom) - notch.height - 12)
        var x = notch.midX - width / 2
        x = max(screen.minX, min(x, screen.maxX - width))  // stay on this display
        expanded = CGRect(x: x, y: top - height - Self.shadowInset, width: width, height: height + Self.shadowInset)
    }

    /// Size of the expanded island itself (without the shadow margin).
    public var expandedIslandWidth: CGFloat { expanded.width - Self.shadowInset * 2 }

    /// The resting island with something to show (the bear, an indicator):
    /// the notch's own width, extended downward by a "chin" that holds the
    /// bear and the indicator. Nothing is drawn beside the notch, so no
    /// menu-bar item (app menus, a manager's arrow, status icons) is ever
    /// covered; macOS offers no way to reserve menu-bar room, so the island
    /// stays below the bar instead. Without a notch (floating pill) the
    /// frame is the pill's.
    public func restingFrame(withChin: Bool) -> CGRect {
        guard withChin else { return notch }
        guard !isFloating else { return compact }
        return CGRect(x: notch.minX, y: notch.minY - Self.chinHeight, width: notch.width, height: notch.height + Self.chinHeight)
    }

    /// Extra height is measured visible content (banners, handoff and help),
    /// not a permanent allowance. The work area's bottom remains a hard cap.
    public func expandedFrame(contentHeight: CGFloat, peek: Bool = false, extraHeight: CGFloat = 0) -> CGRect {
        let content = min(max(contentHeight, Self.minContentHeight), min(maxContentHeight + extraHeight, maxVisibleContentHeight))
        let height = notch.height + content + Self.shadowInset
        let width = peek ? peekWidth + Self.shadowInset * 2 : expanded.width
        let x = expanded.midX - width / 2
        return CGRect(x: x, y: screenTop - height, width: width, height: height)
    }
}
