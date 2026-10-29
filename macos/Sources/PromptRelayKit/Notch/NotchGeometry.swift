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
    /// Height of the top safe area: > 0 only on displays with a camera housing.
    public let safeAreaTop: CGFloat
    /// Menu-bar areas left and right of the notch (`NSScreen.auxiliaryTop…Area`), global coordinates.
    public let auxiliaryTopLeft: CGRect?
    public let auxiliaryTopRight: CGRect?
    /// Height of the menu bar on this display (where the floating island hangs).
    public let menuBarHeight: CGFloat

    public init(displayID: UInt32, name: String, isBuiltIn: Bool, frame: CGRect, safeAreaTop: CGFloat,
                auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?, menuBarHeight: CGFloat = 24) {
        self.displayID = displayID
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.frame = frame
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
                  menuBarHeight: max(0, frame.maxY - screen.visibleFrame.maxY))
    }
}

/// Which display the notch surface uses.
public enum DisplayChoice: Hashable, Sendable {
    /// The first display with a notch (the built-in one first).
    case automatic
    /// A specific display; if it is gone or has no notch, nothing is shown
    /// there and the menu-bar item remains the way in.
    case display(UInt32)

    public static func pick(_ choice: DisplayChoice, from screens: [ScreenDescriptor]) -> ScreenDescriptor? {
        switch choice {
        case .automatic:
            let notched = screens.filter(\.hasNotch)
            return notched.first(where: \.isBuiltIn) ?? notched.first
        case .display(let id):
            if let screen = screens.first(where: { $0.displayID == id }), screen.hasNotch { return screen }
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
    public let maxContentHeight: CGFloat
    let screenTop: CGFloat

    /// Width of each ear beside the camera housing in the compact state.
    public static let earWidth: CGFloat = 26
    /// The open island: a compact card, not a window.
    public static let expandedWidth: CGFloat = 460
    public static let minContentHeight: CGFloat = 56
    /// The open island is never taller than this (band included)…
    public static let maxIslandHeight: CGFloat = 600
    /// …nor than this share of the display height below it.
    public static let maxScreenShare: CGFloat = 0.72
    /// Gap between the menu bar and the floating island.
    public static let floatingGap: CGFloat = 6
    /// Margin around the island inside the window. Zero: the island has no
    /// shadow (like the hardware notch), so the window is exactly the island
    /// and nothing semi-transparent or grey surrounds it.
    public static let shadowInset: CGFloat = 0

    public init?(screen: ScreenDescriptor) {
        guard let notch = screen.notchRect else { return nil }
        self.init(notch: notch, top: screen.frame.maxY, screen: screen.frame, floating: false)
    }

    /// The fallback on a display without a notch: the same island, centered
    /// below the menu bar.
    public init(floatingOn screen: ScreenDescriptor) {
        let top = screen.frame.maxY - screen.menuBarHeight - Self.floatingGap
        let band = CGRect(x: screen.frame.midX, y: top - 32, width: 0, height: 32)
        self.init(notch: band, top: top, screen: screen.frame, floating: true)
    }

    private init(notch: CGRect, top: CGFloat, screen: CGRect, floating: Bool) {
        self.notch = notch
        screenTop = top
        isFloating = floating
        compact = notch.insetBy(dx: -Self.earWidth, dy: 0)
        let islandWidth = min(max(Self.expandedWidth, notch.width + 2 * Self.earWidth + 40), screen.width - 40)
        let width = islandWidth + Self.shadowInset * 2
        let available = ((top - screen.minY) * Self.maxScreenShare).rounded()
        let height = max(notch.height + Self.minContentHeight, min(Self.maxIslandHeight, available))
        maxContentHeight = height - notch.height
        var x = notch.midX - width / 2
        x = max(screen.minX, min(x, screen.maxX - width))  // stay on this display
        expanded = CGRect(x: x, y: top - height - Self.shadowInset, width: width, height: height + Self.shadowInset)
    }

    /// Size of the expanded island itself (without the shadow margin).
    public var expandedIslandWidth: CGFloat { expanded.width - Self.shadowInset * 2 }

    /// Expanded window for a measured content height: as tall as the island,
    /// so no empty transparent area hangs below it.
    public func expandedFrame(contentHeight: CGFloat) -> CGRect {
        let content = min(max(contentHeight, Self.minContentHeight), maxContentHeight)
        let height = notch.height + content + Self.shadowInset
        return CGRect(x: expanded.minX, y: screenTop - height, width: expanded.width, height: height)
    }
}
