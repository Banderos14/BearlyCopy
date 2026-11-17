import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// Phase 14, P0: the island closed by itself when a view inside it needed
/// less height. The window shrank under a pointer that had just clicked in
/// its lower part; the tracking area reported "exited" and the 80 ms
/// hover-close ran, although the user never left.
///
/// Phase 14.1: the first fix kept the larger window until the pointer moved
/// onto the island; its transparent part could take clicks meant for the app
/// below. Now the window shrinks at once and the vacated strip is a
/// "corridor": resting or moving there keeps the island open, reaching it
/// ends the corridor, leaving it or clicking in it closes the island.
///
/// The real controller and NSPanel with a manual clock, an injected pointer
/// and corridor monitor; `syncTracking` stands in for AppKit's tracking area
/// (exit when the window no longer contains the pointer, entry when it does).
@MainActor
final class Phase14HoverTests: XCTestCase {
    final class FakeCorridor: CorridorEvents {
        var move: ((CGPoint) -> Void)?
        var press: ((CGPoint) -> Void)?
        var starts = 0
        var isRunning: Bool { move != nil }
        func start(move: @escaping @MainActor (CGPoint) -> Void, press: @escaping @MainActor (CGPoint) -> Void) {
            starts += 1; self.move = move; self.press = press
        }
        func stop() { move = nil; press = nil }
    }

    var suite: String!
    var defaults: MemorySettingsStore!
    var settings: NotchSettings!
    var clock: ManualScheduler!
    var pasteboard: NSPasteboard!
    var model: AppModel!
    var corridor = FakeCorridor()
    var mouse = CGPoint(x: -1000, y: -1000)
    var inside = false

    override func setUp() async throws {
        _ = NSApplication.shared
        suite = "PromptRelayTests.p14hover.\(UUID().uuidString)"
        defaults = TestDefaults.named(suite)
        settings = NotchSettings(defaults: defaults)
        settings.mascotEnabled = false
        clock = ManualScheduler()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("PromptRelayP14H-\(UUID().uuidString)"))
        let core = FakeCore(projects: [project("/p", sessions: 1, last: "2026-10-29T16:13:51.000000Z")])
        core.sessionsByProject["/p"] = [sessionSummary("s", project: "/p", last: "2026-10-29T16:13:51.000000Z")]
        core.turnsBySession["s"] = [turn(1, preview: "Привет", chars: 6)]
        model = AppModel(core: core, clipboard: ClipboardService(pasteboard: pasteboard), dataDirectory: nil)
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        removeTestDefaults(suite)
    }

    func makeController(reduced: Bool = true) -> NotchController {
        settings.animation = reduced ? .reduced : .full
        return NotchController(model: model, settings: settings, actions: SurfaceActions(openWindow: {}, openStatus: {}, quit: {}),
                               screens: FakeScreens([builtInScreen()]), scheduler: clock, center: NotificationCenter(),
                               workspaceCenter: NotificationCenter(), makeHotKey: { nil }, neighbors: FakeNeighbors(),
                               pointerEvents: FakePointerEvents(), mouseLocation: { [unowned self] in self.mouse },
                               corridorEvents: corridor, pressedMouseButtons: { 0 })
    }

    func settle(_ seconds: Double = 0.05) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    /// AppKit's tracking area for the panel's window, as of its frame now.
    func syncTracking(_ c: NotchController) {
        let now = c.panelFrame?.contains(mouse) ?? false
        guard now != inside else { return }
        inside = now
        c.panelPointer(inside: now)
    }

    /// The pointer moves: the panel sees it when inside, the corridor
    /// monitor (if running) sees it anywhere, then the tracking area updates.
    func move(_ c: NotchController, to point: CGPoint) {
        mouse = point
        if c.panelFrame?.contains(point) == true { c.panelPointerMoved(global: point) }
        corridor.move?(point)
        syncTracking(c)
    }

    /// Opens Quick Peek by hover with tall content; the pointer rests near
    /// its bottom edge (where a tab or Copy with Context was just clicked).
    func openTall(_ c: NotchController, height: CGFloat = 420) async throws -> CGRect {
        c.start()
        let compact = try XCTUnwrap(c.panelFrame)
        move(c, to: CGPoint(x: compact.midX, y: compact.midY))
        clock.advance(0.2)
        XCTAssertTrue(c.interaction.phase.isExpanded)
        await settle(NotchController.openSettleTime + 0.1)   // the view's own first measurement lands
        c.presentation.reportContentHeight(height)
        await settle()
        let tall = try XCTUnwrap(c.panelFrame)
        move(c, to: CGPoint(x: tall.midX, y: tall.minY + 30))
        return tall
    }

    func testShrinkingUnderThePointerDoesNotCloseTheIsland() async throws {
        let c = makeController()
        let tall = try await openTall(c)
        c.presentation.reportContentHeight(160)             // the new view is shorter
        await settle()
        syncTracking(c)                                      // AppKit: "exited" (our own edge moved)
        clock.advance(1.0)
        XCTAssertTrue(c.interaction.phase.isExpanded, "the island stays open: the user did not leave")
        XCTAssertLessThan(try XCTUnwrap(c.panelFrame).height, tall.height - 100, "the window shrinks at once: nothing transparent left")
        XCTAssertFalse(try XCTUnwrap(c.panelFrame).contains(mouse))
        XCTAssertNotNil(c.corridor)
        XCTAssertTrue(corridor.isRunning, "the monitor runs only during the corridor")
        // Still in the strip, moving a little: still open.
        move(c, to: CGPoint(x: tall.midX + 20, y: tall.minY + 40))
        clock.advance(1.0)
        XCTAssertTrue(c.interaction.phase.isExpanded)
        // Up onto the smaller island: the corridor ends, normal tracking again.
        move(c, to: CGPoint(x: tall.midX, y: tall.maxY - 60))
        XCTAssertNil(c.corridor)
        XCTAssertFalse(corridor.isRunning)
        XCTAssertTrue(c.interaction.phase.isExpanded)
        // Leaving for real still closes it.
        move(c, to: CGPoint(x: tall.midX, y: tall.minY - 300))
        clock.advance(0.2)
        XCTAssertEqual(c.interaction.phase, .compact, "a real exit closes the island")
        c.stop()
    }

    func testAClickInTheVacatedStripGoesToTheAppBelowAndCloses() async throws {
        let c = makeController()
        let tall = try await openTall(c)
        c.presentation.reportContentHeight(160)
        await settle()
        syncTracking(c)
        let click = CGPoint(x: tall.midX, y: tall.minY + 30)
        XCTAssertFalse(try XCTUnwrap(c.panelFrame).contains(click), "the panel does not cover the click: it reaches the app below")
        XCTAssertFalse(NSApp.windows.contains { $0 is NotchPanel && $0.isVisible && $0.frame.contains(click) },
                       "no BearlyCopy window under the pointer")
        corridor.press?(click)
        clock.advance(0.2)
        XCTAssertEqual(c.interaction.phase, .compact, "working in the app below is a departure")
        XCTAssertFalse(corridor.isRunning)
        c.stop()
    }

    func testAnimatedShrinkAlsoKeepsTheIslandOpen() async throws {
        let c = makeController(reduced: false)
        _ = try await openTall(c)
        c.presentation.reportContentHeight(160)
        await settle(NotchPresentation.resizeDuration + 0.2)  // past the delayed window shrink
        syncTracking(c)
        clock.advance(1.0)
        XCTAssertTrue(c.interaction.phase.isExpanded)
        XCTAssertFalse(try XCTUnwrap(c.panelFrame).contains(mouse))
        c.stop()
    }

    func testLeavingTheOldAreaClosesTheIsland() async throws {
        let c = makeController()
        let tall = try await openTall(c)
        c.presentation.reportContentHeight(160)
        await settle()
        syncTracking(c)
        move(c, to: CGPoint(x: tall.maxX + 200, y: tall.minY + 30))   // sideways out of the old area
        clock.advance(0.2)
        XCTAssertEqual(c.interaction.phase, .compact)
        XCTAssertNil(c.corridor)
        XCTAssertFalse(corridor.isRunning)
        c.stop()
    }

    func testGrowingAgainEndsTheCorridor() async throws {
        let c = makeController()
        let tall = try await openTall(c)
        c.presentation.reportContentHeight(160)
        await settle()
        c.presentation.reportContentHeight(420)              // back to the taller view
        await settle()
        XCTAssertEqual(try XCTUnwrap(c.panelFrame).height, tall.height, accuracy: 1)
        XCTAssertNil(c.corridor, "the pointer is on the island again")
        XCTAssertFalse(corridor.isRunning)
        XCTAssertTrue(c.interaction.phase.isExpanded)
        c.stop()
    }

    func testShrinkWithThePointerElsewhereAppliesAtOnce() async throws {
        let c = makeController()
        c.start()
        c.toggleFromKeyboard()                                // keyboard-opened, pointer far away
        await settle(NotchController.openSettleTime + 0.1)
        c.presentation.reportContentHeight(420)
        await settle()
        let tall = try XCTUnwrap(c.panelFrame)
        c.presentation.reportContentHeight(160)
        await settle()
        XCTAssertLessThan(try XCTUnwrap(c.panelFrame).height, tall.height - 100)
        XCTAssertTrue(c.interaction.phase.isExpanded)
        XCTAssertEqual(corridor.starts, 0, "no monitor without a pointer on the island")
        c.stop()
    }

    func testRapidSwitchingNeverClosesOrLeavesTimersOrMonitors() async throws {
        let c = makeController()
        let tall = try await openTall(c)
        for h: CGFloat in [160, 380, 120, 300, 140, 420, 150] {
            c.presentation.reportContentHeight(h)
            await settle(0.02)
            syncTracking(c)
            clock.advance(0.05)
        }
        clock.advance(2)
        XCTAssertTrue(c.interaction.phase.isExpanded)
        XCTAssertEqual(c.interaction.pendingTimerCount, 0)
        move(c, to: CGPoint(x: tall.midX, y: tall.maxY - 50))
        XCTAssertTrue(c.interaction.phase.isExpanded)
        XCTAssertFalse(corridor.isRunning)
        c.stop()
    }

    func testClosingOrStoppingStopsTheMonitor() async throws {
        let c = makeController()
        _ = try await openTall(c)
        c.presentation.reportContentHeight(160)
        await settle()
        XCTAssertTrue(corridor.isRunning)
        c.interaction.close()                                 // Esc / a copy that dismisses
        await settle()
        XCTAssertFalse(corridor.isRunning)
        c.stop()
        XCTAssertFalse(corridor.isRunning)
    }
}
