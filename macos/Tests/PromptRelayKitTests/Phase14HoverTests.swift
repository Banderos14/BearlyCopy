import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// Phase 14, P0: the island closed by itself when a view inside it needed
/// less height. The window shrank under a pointer that had just clicked in
/// its lower part; the tracking area reported "exited" and the 80 ms
/// hover-close ran, although the user never left. These tests drive the real
/// controller and NSPanel with a manual clock and an injected pointer, and
/// stand in for AppKit's tracking area (`syncTracking`): it reports an exit
/// when the window no longer contains the pointer, an entry when it does.
@MainActor
final class Phase14HoverTests: XCTestCase {
    var suite: String!
    var defaults: MemorySettingsStore!
    var settings: NotchSettings!
    var clock: ManualScheduler!
    var pasteboard: NSPasteboard!
    var model: AppModel!
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
                               pointerEvents: FakePointerEvents(), mouseLocation: { [unowned self] in self.mouse })
    }

    func settle(_ seconds: Double = 0.05) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    /// AppKit's tracking area for the panel's window, as of its frame now.
    func syncTracking(_ c: NotchController) {
        let now = c.panelFrame?.contains(mouse) ?? false
        guard now != inside else { return }
        inside = now
        c.panelPointer(inside: now)
    }

    func move(_ c: NotchController, to point: CGPoint) {
        mouse = point
        if c.panelFrame?.contains(point) == true { c.panelPointerMoved(global: point) }
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
        syncTracking(c)
        clock.advance(1.0)
        XCTAssertTrue(c.interaction.phase.isExpanded, "the island stays open: the user did not leave")
        XCTAssertEqual(c.presentation.contentHeight, 160, accuracy: 1, "the island itself takes its new height")
        XCTAssertTrue(try XCTUnwrap(c.panelFrame).contains(mouse), "the window keeps the pointer until it reaches the island")
        XCTAssertEqual(try XCTUnwrap(c.panelFrame).height, tall.height, accuracy: 1)
        // Moving up into the smaller island: the window takes its frame.
        let target = CGPoint(x: tall.midX, y: tall.maxY - 60)
        move(c, to: target)
        XCTAssertLessThan(try XCTUnwrap(c.panelFrame).height, tall.height - 100, "the window follows once the pointer is on the island")
        XCTAssertTrue(c.interaction.phase.isExpanded)
        // Leaving for real still closes it.
        move(c, to: CGPoint(x: tall.midX, y: tall.minY - 300))
        clock.advance(0.2)
        XCTAssertEqual(c.interaction.phase, .compact, "a real exit closes the island")
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
        c.stop()
    }

    func testLeavingTheOldAreaWhileWaitingClosesTheIsland() async throws {
        let c = makeController()
        let tall = try await openTall(c)
        c.presentation.reportContentHeight(160)
        await settle()
        syncTracking(c)
        move(c, to: CGPoint(x: tall.maxX + 200, y: tall.minY + 30))   // sideways out of the old area
        clock.advance(0.2)
        XCTAssertEqual(c.interaction.phase, .compact)
        await settle(0.3)
        let compact = try XCTUnwrap(c.panelFrame)
        XCTAssertLessThan(compact.height, 80, "closing drops the waiting frame: no tall window is left behind")
        c.stop()
    }

    func testGrowingAgainWhileWaitingTakesTheNewFrame() async throws {
        let c = makeController()
        let tall = try await openTall(c)
        c.presentation.reportContentHeight(160)
        await settle()
        c.presentation.reportContentHeight(420)              // back to the taller view
        await settle()
        XCTAssertEqual(try XCTUnwrap(c.panelFrame).height, tall.height, accuracy: 1)
        XCTAssertNil(c.waitingFrame)
        move(c, to: CGPoint(x: tall.midX, y: tall.maxY - 60))
        XCTAssertEqual(try XCTUnwrap(c.panelFrame).height, tall.height, accuracy: 1, "no stale smaller frame applied later")
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
        c.stop()
    }

    func testRapidSwitchingNeverClosesOrLeavesTimers() async throws {
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
        c.stop()
    }
}
