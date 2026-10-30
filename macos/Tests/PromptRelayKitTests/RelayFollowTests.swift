import AppKit
import XCTest
@testable import PromptRelayKit

/// Stands in for the global and local mouse monitors.
@MainActor
final class FakePointerEvents: PointerEvents {
    private(set) var handler: (@MainActor (CGPoint) -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0
    var isMonitoring: Bool { handler != nil }

    func start(_ handler: @escaping @MainActor (CGPoint) -> Void) { starts += 1; self.handler = handler }
    func stop() { if handler != nil { stops += 1 }; handler = nil }
    func move(to point: CGPoint) { handler?(point) }
}

@MainActor
final class PointerFollowerTests: XCTestCase {
    func testMovementIsThrottledAndEndsWhereThePointerStopped() {
        let events = FakePointerEvents()
        let clock = ManualScheduler()
        let follower = PointerFollower(events: events, scheduler: clock, clock: { clock.now })
        var seen: [CGPoint] = []
        follower.onMove = { seen.append($0) }
        follower.start()
        XCTAssertTrue(events.isMonitoring)
        // 1 s of a 240 Hz trackpad.
        for i in 0..<240 {
            events.move(to: CGPoint(x: i, y: 0))
            clock.advance(1.0 / 240)
        }
        clock.advance(0.1)
        XCTAssertLessThanOrEqual(seen.count, Int(PointerFollower.maxRate) + 2, "at most ~30 updates a second")
        XCTAssertGreaterThan(seen.count, 20, "but smooth")
        XCTAssertEqual(seen.last, CGPoint(x: 239, y: 0), "the gaze ends where the pointer stopped")
    }

    func testRestsWhenThePointerIsStillAndStopsCleanly() {
        let events = FakePointerEvents()
        let clock = ManualScheduler()
        let follower = PointerFollower(events: events, scheduler: clock, clock: { clock.now })
        var rested = 0
        follower.onRest = { rested += 1 }
        follower.start()
        events.move(to: .zero)
        clock.advance(PointerFollower.restAfter - 1)
        XCTAssertEqual(rested, 0)
        events.move(to: CGPoint(x: 5, y: 5))             // moving again postpones the rest
        clock.advance(PointerFollower.restAfter - 1)
        XCTAssertEqual(rested, 0)
        clock.advance(2)
        XCTAssertEqual(rested, 1, "after a long stillness Relay looks ahead again")
        follower.stop()
        XCTAssertFalse(events.isMonitoring, "monitors removed")
        XCTAssertEqual(clock.liveTimers, 0, "no timer left behind")
        let delivered = follower.deliveries
        events.move(to: .zero)
        XCTAssertEqual(follower.deliveries, delivered, "nothing is delivered after stop")
    }
}

/// Opt-in (PROMPT_RELAY_PERF=1): CPU of this process with the real panel and
/// Relay on screen, the pointer still and then moving at 120 Hz.
@MainActor
final class RelayPerformanceTests: XCTestCase {
    func testCPUWhileThePointerIsStillAndMoving() async throws {
        guard ProcessInfo.processInfo.environment["PROMPT_RELAY_PERF"] == "1" else {
            throw XCTSkip("set PROMPT_RELAY_PERF=1 to measure Relay's CPU use")
        }
        _ = NSApplication.shared
        let suite = "PromptRelayPerf.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NotchSettings(defaults: defaults)
        settings.mascotEnabled = true
        settings.animation = .full
        let board = NSPasteboard(name: NSPasteboard.Name("PromptRelayPerf-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let model = AppModel(core: FakeCore(projects: []), clipboard: ClipboardService(pasteboard: board), dataDirectory: nil)
        let events = FakePointerEvents()
        let screen = try XCTUnwrap(NSScreen.screens.map(ScreenDescriptor.init).first(where: \.hasNotch) ?? builtInScreen() as ScreenDescriptor?)
        let controller = NotchController(model: model, settings: settings, actions: SurfaceActions(quit: {}),
                                         screens: FakeScreens([screen]), makeHotKey: { nil }, neighbors: FakeNeighbors(),
                                         pointerEvents: events)
        controller.start()
        await model.refreshNow()
        XCTAssertTrue(controller.isFollowingPointer)
        func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        func measure(seconds: Double, moving: Bool) async -> Double {
            let start = cpu(), began = Date()
            var t = 0.0
            while Date().timeIntervalSince(began) < seconds {
                if moving {
                    t += 1.0 / 120
                    let frame = controller.panelFrame ?? .zero
                    events.move(to: CGPoint(x: frame.midX + 600 * sin(t * 1.3), y: frame.minY - 300 - 250 * cos(t * 0.9)))
                }
                try? await Task.sleep(nanoseconds: 8_333_333)
            }
            return (cpu() - start) / Date().timeIntervalSince(began) * 100
        }
        _ = await measure(seconds: 1, moving: false)
        let still = await measure(seconds: 5, moving: false)
        let deliveriesBefore = controller.follower.deliveries
        let moving = await measure(seconds: 10, moving: true)
        let rate = Double(controller.follower.deliveries - deliveriesBefore) / 10
        print(String(format: "RELAY-PERF still %.1f%% CPU, moving %.1f%% CPU, %.0f gaze updates/s (events 120/s), RSS %d MB",
                     still, moving, rate, Self.residentMB()))
        XCTAssertLessThanOrEqual(rate, PointerFollower.maxRate + 1)
        // The same loop with Relay off: what the test itself costs.
        settings.mascotEnabled = false
        controller.relayout()
        let loopOnly = await measure(seconds: 5, moving: true)
        print(String(format: "RELAY-PERF loop alone (Relay off) %.1f%% CPU", loopOnly))
        controller.stop()
    }

    static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }
}
