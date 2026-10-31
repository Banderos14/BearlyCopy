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
        // Phase 8: PROMPT_RELAY_PERF_MOTION=expressive measures Expressive.
        if ProcessInfo.processInfo.environment["PROMPT_RELAY_PERF_MOTION"] == "expressive" { settings.relayMotion = .expressive }
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
        // WindowServer composites the panel; Core Animation (breathing) costs
        // there, not in this process. Its CPU time comes from `ps` (0.01 s).
        let windowServer = Self.pid(of: "WindowServer")
        func measure(seconds: Double, moving: Bool) async -> (app: Double, server: Double) {
            let start = cpu(), serverStart = windowServer.flatMap(Self.cpuTime), began = Date()
            var t = 0.0
            while Date().timeIntervalSince(began) < seconds {
                if moving {
                    t += 1.0 / 120
                    let frame = controller.panelFrame ?? .zero
                    events.move(to: CGPoint(x: frame.midX + 600 * sin(t * 1.3), y: frame.minY - 300 - 250 * cos(t * 0.9)))
                }
                try? await Task.sleep(nanoseconds: 8_333_333)
            }
            let elapsed = Date().timeIntervalSince(began)
            let server = Self.percent(from: serverStart, to: windowServer.flatMap(Self.cpuTime), over: elapsed)
            return ((cpu() - start) / elapsed * 100, server)
        }
        func idle(seconds: Double) async -> (app: Double, server: Double) {
            // The pointer still and no loop: what Relay at rest costs.
            let start = cpu(), serverStart = windowServer.flatMap(Self.cpuTime), began = Date()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            let elapsed = Date().timeIntervalSince(began)
            let server = Self.percent(from: serverStart, to: windowServer.flatMap(Self.cpuTime), over: elapsed)
            return ((cpu() - start) / elapsed * 100, server)
        }
        _ = await measure(seconds: 1, moving: false)
        let rest = await idle(seconds: 8)
        let still = await measure(seconds: 5, moving: false)
        let deliveriesBefore = controller.follower.deliveries
        let mascot = controller.presentation.mascot
        let framesBefore = mascot.framesDrawn
        let rootBefore = NotchRootView.bodyCount
        mascot.motion.resetIntervals()
        let moving = await measure(seconds: 10, moving: true)
        let rate = Double(controller.follower.deliveries - deliveriesBefore) / 10
        let gaps = mascot.motion.intervals.sorted()
        func pct(_ q: Double) -> Double { gaps.isEmpty ? -1 : gaps[min(gaps.count - 1, Int(Double(gaps.count) * q))] * 1000 }
        let mean = gaps.isEmpty ? -1 : gaps.reduce(0, +) / Double(gaps.count) * 1000
        let drops = gaps.filter { $0 > 1.5 / 60 }.count
        print("RELAY-ROOT \(NotchRootView.bodyCount - rootBefore) island body updates in 10 s of movement")
        print(String(format: "RELAY-FRAMES %.1f frames/s drawn while moving; interval mean %.2f ms, p50 %.2f, p95 %.2f, p99 %.2f, max %.2f ms; %d of %d intervals > 25 ms; display max %d Hz",
                     Double(mascot.framesDrawn - framesBefore) / 10, mean, pct(0.5), pct(0.95), pct(0.99), pct(1.0), drops, gaps.count,
                     NSScreen.main?.maximumFramesPerSecond ?? 0))
        // Settles: after the pointer stops, the timeline pauses (no frames at rest).
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let restFrames = mascot.framesDrawn
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        print("RELAY-FRAMES at rest after moving: \(mascot.framesDrawn - restFrames) frames in 2 s, animating=\(mascot.animating)")
        print(String(format: "RELAY-PERF rest %.2f%% app, %.2f%% WindowServer; still %.1f%% CPU, moving %.1f%% CPU (WindowServer %.1f%%), %.0f gaze updates/s (events 120/s), RSS %d MB",
                     rest.app, rest.server, still.app, moving.app, moving.server, rate, Self.residentMB()))
        XCTAssertLessThanOrEqual(rate, Double(PointerFollower.maxRate) * 1.1)
        // The same with Relay off: what the test itself and the panel cost.
        settings.mascotEnabled = false
        controller.relayout()
        try? await Task.sleep(nanoseconds: 500_000_000)
        let restOff = await idle(seconds: 8)
        let loopOnly = await measure(seconds: 5, moving: true)
        print(String(format: "RELAY-PERF Relay off: rest %.2f%% app, %.2f%% WindowServer; loop alone %.1f%% CPU (WindowServer %.1f%%)",
                     restOff.app, restOff.server, loopOnly.app, loopOnly.server))
        controller.stop()
    }

    static func percent(from start: Double?, to end: Double?, over seconds: Double) -> Double {
        guard let start, let end else { return -1 }
        return (end - start) / seconds * 100
    }

    static func pid(of name: String) -> pid_t? {
        let out = run("/usr/bin/pgrep", ["-x", name])
        return out.split(separator: "\n").first.flatMap { pid_t($0) }
    }

    /// CPU seconds of another process, from `ps -o time` ("[[dd-]hh:]mm:ss.ss").
    static func cpuTime(_ pid: pid_t) -> Double? {
        let text = run("/bin/ps", ["-o", "time=", "-p", String(pid)]).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.replacingOccurrences(of: "-", with: ":").split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
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
