import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

@MainActor
final class FakeNeighbors: NotchNeighbors {
    var running: [String] = []
}

@MainActor
final class FakeScreens: ScreenProviding {
    var screens: [ScreenDescriptor]
    init(_ screens: [ScreenDescriptor]) { self.screens = screens }
}

/// The real controller and a real NSPanel, with mock displays, a manual
/// clock, private notification centers and no global hotkey.
@MainActor
final class NotchControllerTests: XCTestCase {
    var suite: String!
    var defaults: UserDefaults!
    var settings: NotchSettings!
    var screens: FakeScreens!
    var clock: ManualScheduler!
    var center: NotificationCenter!
    var workspace: NotificationCenter!
    var pasteboard: NSPasteboard!
    var core: FakeCore!
    var model: AppModel!

    override func setUp() async throws {
        _ = NSApplication.shared
        suite = "PromptRelayTests.controller.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        settings = NotchSettings(defaults: defaults)
        settings.animation = .reduced
        settings.mascotEnabled = false     // geometry tests: no ears unless a test turns the mascot on
        screens = FakeScreens([externalScreen(), builtInScreen()])
        clock = ManualScheduler()
        center = NotificationCenter()
        workspace = NotificationCenter()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("PromptRelayNotch-\(UUID().uuidString)"))
        core = FakeCore(projects: [project("/p", sessions: 1, last: "2026-10-29T16:13:51.000000Z")])
        core.sessionsByProject["/p"] = [sessionSummary("s", project: "/p", last: "2026-10-29T16:13:51.000000Z")]
        core.turnsBySession["s"] = [turn(1, preview: "Привет из плагина 🚀", chars: 19)]
        core.showResult = { [core] key, i in
            .success(CoreResult(data: ShowData(session: try! core!.session(key), turn: turn(i, chars: 19, text: "Привет из плагина 🚀")), warnings: []))
        }
        model = AppModel(core: core, clipboard: ClipboardService(pasteboard: pasteboard), dataDirectory: nil)
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
    }

    var neighbors = FakeNeighbors()

    func makeController() -> NotchController {
        NotchController(model: model, settings: settings, actions: SurfaceActions(openWindow: {}, openStatus: {}, quit: {}),
                        screens: screens, scheduler: clock, center: center, workspaceCenter: workspace, makeHotKey: { nil },
                        neighbors: neighbors)
    }

    func testStepsAsideWhileAnotherNotchAppRuns() async {
        neighbors.running = ["Coucou"]
        let controller = makeController()
        controller.start()
        XCTAssertTrue(controller.isYielding)
        XCTAssertEqual(controller.interaction.phase, .compact)
        XCTAssertEqual(notchPanels().count, 0, "no hover target competes with Coucou's island")
        controller.toggleFromKeyboard()                       // ⌃⌥⌘P still opens it
        XCTAssertTrue(controller.panelIsVisible)
        controller.interaction.close()
        await settle(0.2)
        XCTAssertEqual(notchPanels().count, 0)

        neighbors.running = []                                // Coucou quits
        workspace.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        await settle()
        XCTAssertFalse(controller.isYielding)
        XCTAssertEqual(notchPanels().count, 1)

        settings.yieldToOtherNotchApps = false                // the user prefers to share the notch
        neighbors.running = ["Coucou"]
        controller.relayout()
        XCTAssertFalse(controller.isYielding)
        XCTAssertEqual(notchPanels().count, 1)
        controller.stop()
    }

    func testArrowStepsThroughAnswersWithoutLists() async {
        core.sessionsByProject["/p"] = [sessionSummary("s", project: "/p", last: "2026-10-29T16:20:00.000000Z", lastTurn: 3)]
        core.turnsBySession["s"] = [turn(1, preview: "one", chars: 3), turn(2, status: "awaiting_response", preview: nil),
                                    turn(3, preview: "three", chars: 5)]
        await model.refreshNow()
        XCTAssertEqual(model.selectedTurnIndex, 3)
        XCTAssertEqual(NotchRootView.answerTurns(model), [3, 1], "a pending prompt has nothing to show")
        NotchRootView.step(model, by: 1)
        XCTAssertEqual(model.selectedTurnIndex, 1)
        NotchRootView.step(model, by: 1)
        XCTAssertEqual(model.selectedTurnIndex, 1, "stops at the oldest")
        NotchRootView.step(model, by: -1)
        XCTAssertEqual(model.selectedTurnIndex, 3)
    }

    func testExcerptIsDisplayOnly() {
        let text = "a\n\n\n\n\nb   \n"
        XCTAssertEqual(NotchRootView.excerpt(text), "a\n\nb")
        XCTAssertEqual(NotchRootView.excerpt(String(repeating: "x", count: 5000)).count, 800)
    }

    func notchPanels() -> [NSWindow] { NSApp.windows.filter { $0 is NotchPanel && $0.isVisible } }

    /// Window frames are rounded to the backing pixel grid (1x in tests).
    func assertFrame(_ frame: CGRect?, _ expected: CGRect?, _ message: String = "", line: UInt = #line) {
        guard let frame, let expected else { return XCTFail("missing frame \(message)", line: line) }
        for (a, b) in [(frame.minX, expected.minX), (frame.minY, expected.minY), (frame.width, expected.width), (frame.height, expected.height)] {
            XCTAssertEqual(a, b, accuracy: 1, message, line: line)
        }
    }

    /// Lets main-queue work (delayed collapse, observation callbacks) run.
    func settle(_ seconds: Double = 0.05) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    func testStartsCompactOnTheNotchedDisplayOnly() throws {
        let controller = makeController()
        controller.start()
        XCTAssertEqual(controller.interaction.phase, .compact)
        XCTAssertEqual(controller.activeScreen?.displayID, 1, "the built-in display, not the main external one")
        let layout = try XCTUnwrap(controller.layout)
        assertFrame(controller.panelFrame, layout.notch, "no indicator: exactly the notch, nothing else covered")
        XCTAssertEqual(notchPanels().count, 1)
        XCTAssertEqual(controller.observerCount, 8, "screens, wake ×2, space, app launch/quit, menu begin/end")
        controller.stop()
    }

    func testDisplayChangesFallBackAndRecover() {
        let controller = makeController()
        controller.start()
        screens.screens = [externalScreen()]            // lid closed / built-in display off
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(controller.layout?.isFloating ?? false, "no notch: the island floats, opened from the menu bar")
        XCTAssertEqual(notchPanels().count, 0, "no resting panel without a notch")

        screens.screens = [externalScreen(), builtInScreen(origin: CGPoint(x: 1920, y: 0))]   // re-arranged
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(controller.interaction.phase, .compact)
        XCTAssertEqual(controller.panelFrame?.minX ?? 0, 1920 + 663.5, accuracy: 0.5, "follows the new arrangement")
        controller.stop()
    }

    func testHoverExpandsPanelAndCollapsesBack() async throws {
        let controller = makeController()
        controller.start()
        await model.refreshNow()
        controller.interaction.pointerEntered()
        clock.advance(0.2)
        XCTAssertEqual(controller.interaction.phase, .expanded(focused: false))
        assertFrame(controller.panelFrame, controller.layout?.expandedFrame(contentHeight: controller.presentation.contentHeight))
        XCTAssertTrue(controller.presentation.isExpanded)
        // The real view measures its content; the window follows it exactly,
        // still hanging from the top edge (no empty transparent area below).
        await settle(0.2)
        let measured = controller.presentation.contentHeight
        XCTAssertGreaterThanOrEqual(measured, NotchLayout.minContentHeight)
        XCTAssertLessThanOrEqual(measured, controller.layout?.maxContentHeight ?? 0)
        assertFrame(controller.panelFrame, controller.layout?.expandedFrame(contentHeight: measured))
        XCTAssertEqual(controller.panelFrame?.maxY ?? 0, 982, accuracy: 1)
        controller.interaction.pointerExited()
        clock.advance(0.4)
        XCTAssertEqual(controller.interaction.phase, .compact)
        XCTAssertFalse(controller.presentation.isExpanded)
        await settle(0.3)  // the window shrinks after the content
        assertFrame(controller.panelFrame, controller.layout?.notch)
        controller.stop()
    }

    func testHoverOpensQuickPeekAndAClickOpensTheIslandOnHome() async throws {
        let controller = makeController()
        controller.start()
        await model.refreshNow()
        let layout = try XCTUnwrap(controller.layout)

        controller.interaction.pointerEntered()
        clock.advance(0.2)
        XCTAssertEqual(controller.presentation.surface, .peek, "hover shows the quick peek")
        XCTAssertEqual(controller.interaction.phase, .expanded(focused: false))
        await settle(0.4)
        let peekHeight = try XCTUnwrap(controller.panelFrame?.height)

        controller.interaction.focus()                      // the peek's expand button
        XCTAssertEqual(controller.presentation.surface, .expanded)
        XCTAssertEqual(controller.interaction.phase, .expanded(focused: true))
        await settle(0.4)
        // Sized to its content: the window is exactly the island, no empty area.
        assertFrame(controller.panelFrame, layout.expandedFrame(contentHeight: controller.presentation.contentHeight))
        XCTAssertGreaterThan(controller.panelFrame?.height ?? 0, peekHeight, "Home adds the footer to the peek")
        XCTAssertLessThanOrEqual(controller.panelFrame?.height ?? .infinity, NotchLayout.maxIslandHeight)

        // Views open inside the island; Esc goes back, then closes.
        model.navigate(to: .settings)
        await settle(0.4)
        assertFrame(controller.panelFrame, layout.expandedFrame(contentHeight: controller.presentation.contentHeight))
        controller.cancel()
        XCTAssertEqual(model.route, .home)
        XCTAssertTrue(controller.interaction.phase.isExpanded)

        // Leaving with the pointer does not close the focused island.
        controller.interaction.pointerExited()
        clock.advance(1)
        XCTAssertTrue(controller.interaction.phase.isExpanded)

        controller.cancel()                                 // Esc on Home
        XCTAssertEqual(controller.interaction.phase, .compact)
        await settle(0.4)
        assertFrame(controller.panelFrame, layout.notch)

        // A click on the notch opens the island directly, on Home.
        model.navigate(to: .projects)
        controller.interaction.toggle()
        XCTAssertEqual(controller.presentation.surface, .expanded)
        XCTAssertEqual(model.route, .home)
        controller.stop()
    }

    func testMenuBarOpensTheIslandOnAView() async throws {
        let controller = makeController()
        controller.start()
        await model.refreshNow()
        controller.present(.settings)
        XCTAssertEqual(controller.interaction.phase, .expanded(focused: true))
        XCTAssertEqual(model.route, .settings)
        controller.present(.history)                       // already open: switches view
        XCTAssertEqual(model.route, .history)
        controller.stop()
    }

    func testWithoutANotchTheIslandFloatsAndOpensOnlyOnRequest() async throws {
        screens.screens = [externalScreen(origin: .zero)]
        let controller = makeController()
        controller.start()
        let layout = try XCTUnwrap(controller.layout)
        XCTAssertTrue(layout.isFloating)
        XCTAssertFalse(controller.hasRestingTarget)
        XCTAssertEqual(notchPanels().count, 0, "nothing at the top edge of a display without a notch")
        controller.present(.home)
        XCTAssertTrue(controller.panelIsVisible)
        XCTAssertTrue(controller.presentation.isFloating)
        XCTAssertEqual(controller.panelFrame?.maxY ?? 0, 1080 - 24 - NotchLayout.floatingGap, accuracy: 1, "below the menu bar")
        XCTAssertEqual(controller.panelFrame?.midX ?? 0, 960, accuracy: 1)
        controller.cancel()
        await settle(0.4)
        XCTAssertEqual(notchPanels().count, 0)
        controller.stop()
    }

    func testTheFolderPickerKeepsTheIslandOpen() async throws {
        let controller = makeController()
        controller.start()
        controller.interaction.pointerEntered()
        clock.advance(0.2)
        model.isPresentingSystemDialog = true
        await settle()
        XCTAssertTrue(controller.interaction.isPinned)
        controller.interaction.pointerExited()
        controller.interaction.focusLost()                 // the picker takes the keyboard
        clock.advance(1)
        XCTAssertTrue(controller.interaction.phase.isExpanded)
        model.isPresentingSystemDialog = false
        await settle()
        XCTAssertFalse(controller.interaction.isPinned)
        XCTAssertEqual(controller.interaction.phase, .expanded(focused: true), "the island takes the keyboard back")
        controller.stop()
    }

    func testMascotSitsInTheLeftEarBlinksOnlyWhileVisibleAndReactsToFacts() async throws {
        settings.mascotEnabled = true
        settings.animation = .full
        let controller = makeController()
        controller.start()
        await model.refreshNow()
        assertFrame(controller.panelFrame, controller.layout?.compact, "the bear needs the ears")
        XCTAssertTrue(controller.presentation.showsMascot)
        XCTAssertTrue(controller.isBlinkLoopRunning, "blinks while the resting island is on screen")

        controller.look(at: CGPoint(x: 200, y: 16))       // pointer far right of the left ear
        XCTAssertGreaterThan(controller.presentation.mascot.gaze.x, 0.5)
        controller.pointerLeft()
        XCTAssertEqual(controller.presentation.mascot.gaze, .zero, "no pointer outside the island is followed")

        controller.react(newAnswer: false, copy: .copied(.response, characters: 3), coreDown: false)
        XCTAssertEqual(controller.presentation.mascot.mood, .pleased)
        controller.react(newAnswer: false, copy: .failed("x"), coreDown: false)
        XCTAssertEqual(controller.presentation.mascot.mood, .concerned)
        controller.react(newAnswer: true, copy: .idle, coreDown: false)
        XCTAssertEqual(controller.presentation.mascot.mood, .curious, "a captured answer, not a claim of success")

        settings.notchEnabled = false                      // hidden at rest: no animation work at all
        controller.relayout()
        XCTAssertFalse(controller.isBlinkLoopRunning)
        settings.notchEnabled = true
        settings.animation = .reduced                      // Reduce Motion: no blinking, no eye movement
        controller.relayout()
        XCTAssertFalse(controller.isBlinkLoopRunning)
        controller.look(at: CGPoint(x: 200, y: 16))
        XCTAssertEqual(controller.presentation.mascot.gaze, .zero)
        settings.mascotEnabled = false
        controller.relayout()
        await settle(0.3)
        assertFrame(controller.panelFrame, controller.layout?.notch, "mascot off: back inside the camera housing")
        controller.stop()
        XCTAssertFalse(controller.isBlinkLoopRunning)
    }

    func testAnOpenMenuKeepsTheIslandOpen() async throws {
        let controller = makeController()
        controller.start()
        controller.interaction.pointerEntered()
        clock.advance(0.2)
        center.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        XCTAssertTrue(controller.interaction.isPinned)
        controller.interaction.pointerExited()              // the pointer moves into the menu
        clock.advance(1)
        XCTAssertTrue(controller.interaction.phase.isExpanded, "the ⋯ menu does not fold the island")
        center.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        XCTAssertFalse(controller.interaction.isPinned)
        clock.advance(0.4)
        XCTAssertEqual(controller.interaction.phase, .compact, "closes once the menu is gone and the pointer is outside")
        controller.stop()
    }

    func testArrowKeysStepAnswersOnlyOnHome() async throws {
        core.sessionsByProject["/p"] = [sessionSummary("s", project: "/p", last: "2026-10-29T16:20:00.000000Z", lastTurn: 2)]
        core.turnsBySession["s"] = [turn(1, preview: "one", chars: 3), turn(2, preview: "two", chars: 3)]
        let controller = makeController()
        controller.start()
        await model.refreshNow()
        controller.interaction.toggle()
        XCTAssertEqual(model.selectedTurnIndex, 2)
        model.navigate(to: .history)
        XCTAssertFalse(controller.handleKeyForTesting(.older), "lists keep their own arrow keys")
        XCTAssertEqual(model.selectedTurnIndex, 2)
        model.goBack()
        XCTAssertTrue(controller.handleKeyForTesting(.older))
        XCTAssertEqual(model.selectedTurnIndex, 1)
        controller.stop()
    }

    func testCopyResponseFromTheNotchCopiesTheFullText() async throws {
        let controller = makeController()
        controller.start()
        await model.refreshNow()
        controller.interaction.toggle()
        await model.copySelectedResponse()
        XCTAssertEqual(pasteboard.string(forType: .string), "Привет из плагина 🚀")
        controller.stop()
    }

    func testStartStopCyclesLeakNothing() {
        let controller = makeController()
        for _ in 0..<25 {
            controller.start()
            controller.interaction.pointerEntered()
            controller.start()                     // idempotent
            controller.stop()
            controller.stop()
        }
        XCTAssertEqual(controller.observerCount, 0)
        XCTAssertFalse(controller.hasPanel)
        XCTAssertEqual(controller.interaction.pendingTimerCount, 0)
        XCTAssertEqual(notchPanels().count, 0)
        // Posting after stop must not resurrect anything.
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(controller.hasPanel)
    }

    func testTrackingAreaIsReplacedNotAccumulated() throws {
        let view = TrackingView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        for _ in 0..<10 { view.updateTrackingAreas() }
        XCTAssertEqual(view.trackingAreaCount, 1)
        view.removeTracking()
        XCTAssertEqual(view.trackingAreaCount, 0)
    }

    func testIndicatorWidensTheHoverTargetOnlyWhenAnAnswerIsNew() async throws {
        model.tracksReadyAnswers = true
        await model.refreshNow()                           // first run: existing answers count as seen
        let controller = makeController()
        controller.start()
        await settle()
        XCTAssertFalse(controller.presentation.showsIndicator)
        assertFrame(controller.panelFrame, controller.layout?.notch)

        core.sessionsByProject["/p"] = [sessionSummary("s", project: "/p", last: "2026-10-29T17:00:00.000000Z", lastTurn: 2)]
        core.turnsBySession["s"] = [turn(1), turn(2, preview: "new", chars: 3)]
        await model.refreshNow()
        await settle()
        XCTAssertTrue(controller.presentation.showsIndicator)
        assertFrame(controller.panelFrame, controller.layout?.compact)

        controller.interaction.toggle()                    // opening reveals and acknowledges it
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.hasUnseenAnswer)
        XCTAssertEqual(model.selectedTurnIndex, 2)
        controller.stop()
    }

    func testCoordinatorFollowsSettings() async {
        settings.notchEnabled = false
        let coordinator = NotchCoordinator(model: model, settings: settings, notifier: ReadyNotifier()) { self.makeController() }
        XCTAssertEqual(coordinator.controller?.isRunning, true, "the island is the interface: it always runs")
        XCTAssertEqual(coordinator.controller?.hasRestingTarget, false, "hover off: nothing at the notch")
        XCTAssertEqual(notchPanels().count, 0)
        XCTAssertTrue(model.tracksReadyAnswers)
        settings.notchEnabled = true
        await settle()
        XCTAssertEqual(coordinator.controller?.hasRestingTarget, true)
        XCTAssertEqual(notchPanels().count, 1)
        settings.notchEnabled = false
        await settle()
        XCTAssertEqual(notchPanels().count, 0)
        coordinator.controller?.stop()
    }
}

@MainActor
final class ReadyAnswerTests: XCTestCase {
    func testNewAnswerIsAnnouncedOnceAndRememberedAcrossRestarts() async throws {
        let suite = "PromptRelayTests.ready.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let board = NSPasteboard(name: NSPasteboard.Name("PromptRelayReady-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }

        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-29T10:00:00.000000Z"),
                                       project("/b", sessions: 1, last: "2026-10-29T09:00:00.000000Z")])
        core.sessionsByProject["/a"] = [sessionSummary("a1", project: "/a", last: "2026-10-29T10:00:00.000000Z")]
        core.sessionsByProject["/b"] = [sessionSummary("b1", project: "/b", last: "2026-10-29T09:00:00.000000Z")]
        // Answer times consistent with the sessions' last events.
        core.turnsBySession["a1"] = [turn(1, at: "2026-10-29T10:00:00.000000Z"), turn(2, status: "awaiting_response", preview: nil)]
        core.turnsBySession["b1"] = [turn(1, at: "2026-10-29T09:00:00.000000Z"), turn(2, at: "2026-10-29T11:00:00.000000Z")]

        let model = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults)
        var announced: [String] = []
        model.onNewAnswer = { announced.append($0.sessionKey) }
        model.tracksReadyAnswers = true
        await model.refreshNow()
        XCTAssertEqual(model.readyAnswer?.sessionKey, "a1")
        XCTAssertFalse(model.hasUnseenAnswer, "answers that existed at first launch are not 'new'")

        // A Stop arrives in project b; a's new prompt (still waiting) does not
        // count as an answer, and a's previous answer (10:00) is older.
        core.sessionsByProject["/b"] = [sessionSummary("b1", project: "/b", last: "2026-10-29T11:00:00.000000Z", lastTurn: 2)]
        core.sessionsByProject["/a"] = [sessionSummary("a1", project: "/a", last: "2026-10-29T12:00:00.000000Z", lastTurn: 2,
                                                       status: "awaiting_response")]
        await model.refreshNow()
        await model.refreshNow()
        XCTAssertTrue(model.hasUnseenAnswer)
        XCTAssertEqual(model.readyAnswer?.sessionKey, "b1")
        XCTAssertEqual(announced, ["b1"], "announced once, not on every refresh")

        await model.revealReadyAnswer()
        XCTAssertEqual(model.selectedProjectPath, "/b")
        XCTAssertEqual(model.selectedSessionKey, "b1")
        XCTAssertEqual(model.selectedTurnIndex, 2)
        XCTAssertFalse(model.hasUnseenAnswer)

        // Restart: the acknowledged answer is not new again.
        let restarted = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults)
        restarted.tracksReadyAnswers = true
        await restarted.refreshNow()
        XCTAssertFalse(restarted.hasUnseenAnswer)
    }

    func testTrackingCostsExactlyOneExtraSessionsCall() async {
        let board = NSPasteboard(name: NSPasteboard.Name("PromptRelayReady-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-29T10:00:00.000000Z")])
        core.sessionsByProject["/a"] = [sessionSummary("a1", project: "/a", last: "2026-10-29T10:00:00.000000Z")]
        core.turnsBySession["a1"] = [turn(1)]
        let model = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil)
        XCTAssertTrue(model.tracksReadyAnswers, "on by default: the app opens on the newest answer")
        await model.refreshNow()
        XCTAssertEqual(core.sessionsCalls, 2, "all sessions once, plus the selected project's")
        model.tracksReadyAnswers = false
        await model.refreshNow()
        XCTAssertEqual(core.sessionsCalls, 3)
    }
}

/// Regression (design review 2026-10-29): a drop shadow drew a grey,
/// semi-transparent halo around the island on light desktops.
@MainActor
final class NotchAppearanceTests: XCTestCase {
    func render(expanded: Bool, indicator: Bool, full: Bool = false) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let model = PreviewFixtures.model()
        let p = NotchPresentation()
        p.notchSize = CGSize(width: 185, height: 32)
        p.isExpanded = expanded
        p.showsIndicator = indicator
        p.contentHeight = 150
        p.surface = full ? .expanded : .peek
        let height: CGFloat = 32 + 150
        let size = expanded ? NSSize(width: NotchLayout.expandedWidth, height: height) : NSSize(width: 185 + 52, height: 32)
        let host = NSHostingView(rootView: NotchRootView(model: model, presentation: p,
                                                         interaction: NotchInteraction(scheduler: MainQueueScheduler()),
                                                         actions: PreviewFixtures.actions)
            .frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.close()
        return rep
    }

    /// Pixels that are neither fully transparent nor fully opaque, i.e. a
    /// halo; anti-aliased outline pixels are allowed (≈ the perimeter).
    func semiTransparentCount(_ rep: NSBitmapImageRep) -> Int {
        var n = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            let a = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
            if a > 0.02 && a < 0.98 { n += 1 }
        } }
        return n
    }

    func testNoHaloAroundTheIsland() throws {
        XCTAssertEqual(NotchLayout.shadowInset, 0)
        for (expanded, indicator, full) in [(true, false, false), (true, false, true), (false, true, false), (false, false, false)] {
            let rep = try render(expanded: expanded, indicator: indicator, full: full)
            let perimeter = 2 * (rep.pixelsWide + rep.pixelsHigh)
            XCTAssertLessThan(semiTransparentCount(rep), perimeter * 2,
                              "only anti-aliased edges, no shadow (expanded \(expanded), indicator \(indicator))")
            // Corners outside the island are fully transparent.
            XCTAssertLessThan(rep.colorAt(x: 0, y: rep.pixelsHigh - 1)?.alphaComponent ?? 1, 0.02)
        }
    }

    func testRestingIslandStaysInsideTheCameraHousing() throws {
        let rep = try render(expanded: false, indicator: false)
        // Window is 237 px wide here; the resting island (183 px) is centered:
        // the ear areas and the notch's outermost columns stay transparent.
        let scale = CGFloat(rep.pixelsWide) / (185 + 52)
        for x in [0, Int(26 * scale) - 1, rep.pixelsWide - Int(26 * scale)] {
            XCTAssertLessThan(rep.colorAt(x: x, y: rep.pixelsHigh / 2)?.alphaComponent ?? 1, 0.02, "column \(x)")
        }
    }
}
