import AppKit

/// Mouse-moved events from anywhere on screen, for Relay's gaze.
@MainActor
public protocol PointerEvents: AnyObject {
    /// Starts delivering the pointer position (global AppKit coordinates).
    func start(_ handler: @escaping @MainActor (CGPoint) -> Void)
    func stop()
}

/// A global monitor for mouse movement (other apps' windows) plus a local
/// one (Prompt Relay's own windows, which global monitors skip). Mouse
/// events need no Accessibility permission; key events are never monitored.
@MainActor
public final class LivePointerEvents: PointerEvents {
    private var monitors: [Any] = []
    private static let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

    public init() {}

    public func start(_ handler: @escaping @MainActor (CGPoint) -> Void) {
        stop()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: Self.mask, handler: { _ in
            MainActor.assumeIsolated { handler(NSEvent.mouseLocation) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: Self.mask, handler: { event in
            MainActor.assumeIsolated { handler(NSEvent.mouseLocation) }
            return event
        }) { monitors.append(local) }
    }

    public func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}

/// Turns pointer movement into at most `maxRate` updates per second, always
/// ending on the latest position, and reports when the pointer has been
/// still for `restAfter` seconds. Event-driven: nothing runs while the
/// pointer does not move. Only the latest position is kept, never a path.
@MainActor
public final class PointerFollower {
    public static let maxRate: Double = 30
    public static let restAfter: TimeInterval = 12

    private let events: PointerEvents
    private let scheduler: NotchScheduling
    private let clock: () -> TimeInterval
    private var lastDelivered: TimeInterval = -.infinity
    private var pending: CGPoint?
    private var flush: NotchTimer?
    private var rest: NotchTimer?
    public private(set) var isRunning = false
    /// Updates delivered since start (performance checks in tests).
    public private(set) var deliveries = 0

    var onMove: ((CGPoint) -> Void)?
    var onRest: (() -> Void)?

    public init(events: PointerEvents, scheduler: NotchScheduling,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.events = events
        self.scheduler = scheduler
        self.clock = clock
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        events.start { [weak self] point in self?.receive(point) }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        events.stop()
        flush?.cancel(); flush = nil
        rest?.cancel(); rest = nil
        pending = nil
    }

    func receive(_ point: CGPoint) {
        guard isRunning else { return }
        let interval = 1 / Self.maxRate
        let now = clock()
        rest?.cancel()
        rest = scheduler.schedule(after: Self.restAfter) { [weak self] in self?.onRest?() }
        if now - lastDelivered >= interval {
            deliver(point, at: now)
        } else {
            // Too soon: keep only the newest point and deliver it once the
            // interval is over, so the gaze ends where the pointer stopped.
            pending = point
            if flush == nil {
                flush = scheduler.schedule(after: interval - (now - lastDelivered)) { [weak self] in
                    guard let self else { return }
                    self.flush = nil
                    if let point = self.pending { self.pending = nil; self.deliver(point, at: self.clock()) }
                }
            }
        }
    }

    private func deliver(_ point: CGPoint, at time: TimeInterval) {
        lastDelivered = time
        deliveries += 1
        onMove?(point)
    }
}
