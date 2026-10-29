import Foundation

/// Timers the interaction logic uses; injectable so tests run on a manual clock.
@MainActor
public protocol NotchScheduling: AnyObject {
    /// Runs `action` after `delay` unless cancelled. Returns a handle.
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> NotchTimer
}

@MainActor
public protocol NotchTimer: AnyObject {
    func cancel()
}

@MainActor
public final class MainQueueScheduler: NotchScheduling {
    public init() {}

    final class Item: NotchTimer {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    public func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> NotchTimer {
        let item = Item()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                if !item.cancelled { action() }
            }
        }
        return item
    }
}

/// The notch's three phases and how pointer, click and keyboard move between
/// them. No AppKit here: the controller feeds events in and applies `phase`.
///
/// - Hover opens after a short dwell, so moving the pointer across the top
///   edge does not pop the panel open.
/// - Leaving closes after a grace period; coming back cancels it. Rapid
///   in/out never queues more than one timer of each kind.
/// - A click or the keyboard shortcut opens at once and gives the panel
///   keyboard focus; hover never takes focus from the app you are typing in.
/// - While `isPinned` (an alert or menu is open in the panel) nothing closes it.
@MainActor
public final class NotchInteraction {
    public enum Phase: Equatable, Sendable {
        /// Disabled, or no notch on the chosen display: no window at all.
        case hidden
        /// The small hover target around the notch.
        case compact
        /// The panel is open. `focused`: it takes keyboard input.
        case expanded(focused: Bool)

        public var isExpanded: Bool {
            if case .expanded = self { return true }
            return false
        }
    }

    public static let openDelay: TimeInterval = 0.15
    public static let closeDelay: TimeInterval = 0.35

    public private(set) var phase: Phase = .hidden {
        didSet { if phase != oldValue { onChange?(phase, oldValue) } }
    }
    public private(set) var pointerInside = false
    public var isPinned = false {
        didSet { if !isPinned, !pointerInside, phase.isExpanded, !isFocused { scheduleClose() } }
    }
    public var onChange: ((Phase, Phase) -> Void)?

    private let scheduler: NotchScheduling
    private var openTimer: NotchTimer?
    private var closeTimer: NotchTimer?

    public init(scheduler: NotchScheduling) {
        self.scheduler = scheduler
    }

    private var isFocused: Bool {
        if case .expanded(true) = phase { return true }
        return false
    }

    // MARK: Events

    /// The notch can be shown (enabled, and the chosen display has a notch) or not.
    public func setAvailable(_ available: Bool) {
        cancelTimers()
        if !available {
            pointerInside = false
            phase = .hidden
        } else if phase == .hidden {
            phase = .compact
        }
    }

    public func pointerEntered() {
        guard phase != .hidden else { return }
        pointerInside = true
        closeTimer?.cancel(); closeTimer = nil
        guard phase == .compact, openTimer == nil else { return }
        openTimer = scheduler.schedule(after: Self.openDelay) { [weak self] in
            guard let self else { return }
            self.openTimer = nil
            if self.pointerInside, self.phase == .compact { self.phase = .expanded(focused: false) }
        }
    }

    public func pointerExited() {
        guard phase != .hidden else { return }
        pointerInside = false
        openTimer?.cancel(); openTimer = nil
        if phase.isExpanded, !isPinned, !isFocused { scheduleClose() }
    }

    /// A click on the compact notch, or the global shortcut.
    public func toggle() {
        cancelTimers()
        switch phase {
        case .hidden: return
        case .compact: phase = .expanded(focused: true)
        case .expanded: phase = .compact
        }
    }

    /// Escape, a copy that should dismiss, or the panel losing key status.
    public func close() {
        guard phase.isExpanded else { return }
        cancelTimers()
        phase = .compact
    }

    /// The panel lost keyboard focus (the user clicked another app): treat it
    /// like hover from then on, so leaving the area closes it.
    public func focusLost() {
        guard case .expanded(true) = phase else { return }
        phase = .expanded(focused: false)
        if !pointerInside, !isPinned { scheduleClose() }
    }

    private func scheduleClose() {
        guard closeTimer == nil else { return }
        closeTimer = scheduler.schedule(after: Self.closeDelay) { [weak self] in
            guard let self else { return }
            self.closeTimer = nil
            if !self.pointerInside, !self.isPinned, self.phase.isExpanded, !self.isFocused { self.phase = .compact }
        }
    }

    private func cancelTimers() {
        openTimer?.cancel(); openTimer = nil
        closeTimer?.cancel(); closeTimer = nil
    }

    /// Pending timers, for tests and leak checks.
    public var pendingTimerCount: Int { (openTimer == nil ? 0 : 1) + (closeTimer == nil ? 0 : 1) }
}
