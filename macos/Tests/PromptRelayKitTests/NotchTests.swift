import AppKit
import XCTest
@testable import PromptRelayKit

/// A clock the tests advance by hand.
@MainActor
final class ManualScheduler: NotchScheduling {
    final class Item: NotchTimer {
        let due: TimeInterval
        let action: @MainActor () -> Void
        var cancelled = false
        init(due: TimeInterval, action: @escaping @MainActor () -> Void) { self.due = due; self.action = action }
        func cancel() { cancelled = true }
    }

    private(set) var now: TimeInterval = 0
    private var items: [Item] = []

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> NotchTimer {
        let item = Item(due: now + delay, action: action)
        items.append(item)
        return item
    }

    func advance(_ seconds: TimeInterval) {
        now += seconds
        let due = items.filter { !$0.cancelled && $0.due <= now }
        items.removeAll { $0.cancelled || $0.due <= now }
        for item in due { item.action() }
    }

    var liveTimers: Int { items.filter { !$0.cancelled }.count }
}

@MainActor
final class NotchInteractionTests: XCTestCase {
    var clock: ManualScheduler!
    var notch: NotchInteraction!

    override func setUp() async throws {
        clock = ManualScheduler()
        notch = NotchInteraction(scheduler: clock)
        notch.setAvailable(true)
    }

    func testHoverOpensAfterDwellAndClosesAfterGrace() {
        XCTAssertEqual(notch.phase, .compact)
        notch.pointerEntered()
        clock.advance(0.1)
        XCTAssertEqual(notch.phase, .compact, "a pass across the top edge must not open it")
        clock.advance(0.1)
        XCTAssertEqual(notch.phase, .expanded(focused: false), "hover never takes keyboard focus")
        notch.pointerExited()
        clock.advance(0.2)
        XCTAssertEqual(notch.phase, .expanded(focused: false))
        clock.advance(0.2)
        XCTAssertEqual(notch.phase, .compact)
    }

    func testQuickPassDoesNotOpenAndReturningCancelsClose() {
        notch.pointerEntered(); clock.advance(0.05); notch.pointerExited(); clock.advance(1)
        XCTAssertEqual(notch.phase, .compact)

        notch.pointerEntered(); clock.advance(0.2)
        notch.pointerExited(); clock.advance(0.2)
        notch.pointerEntered(); clock.advance(1)
        XCTAssertEqual(notch.phase, .expanded(focused: false), "coming back within the grace period keeps it open")
    }

    func testRapidRepeatedHoverKeepsAtMostOneTimer() {
        for _ in 0..<50 {
            notch.pointerEntered(); notch.pointerExited()
            XCTAssertLessThanOrEqual(clock.liveTimers, 1)
        }
        notch.pointerEntered()
        clock.advance(0.2)
        for _ in 0..<50 {
            notch.pointerExited(); notch.pointerEntered()
            XCTAssertLessThanOrEqual(notch.pendingTimerCount, 1)
        }
        clock.advance(5)
        XCTAssertEqual(notch.phase, .expanded(focused: false))
        XCTAssertEqual(clock.liveTimers, 0)
    }

    func testClickOrShortcutOpensFocusedAndOnlyEscapeOrFocusLossCloses() {
        notch.toggle()
        XCTAssertEqual(notch.phase, .expanded(focused: true))
        notch.pointerExited(); clock.advance(2)
        XCTAssertEqual(notch.phase, .expanded(focused: true), "keyboard users are not closed by the pointer")
        notch.focusLost()
        XCTAssertEqual(notch.phase, .expanded(focused: false))
        clock.advance(0.4)
        XCTAssertEqual(notch.phase, .compact, "after focus loss with the pointer away it closes")
        notch.toggle(); notch.close()
        XCTAssertEqual(notch.phase, .compact)
        notch.toggle(); notch.toggle()
        XCTAssertEqual(notch.phase, .compact)
    }

    func testPinnedPanelStaysOpenUntilUnpinned() {
        notch.pointerEntered(); clock.advance(0.2)
        notch.isPinned = true           // e.g. the "possible secrets" alert
        notch.pointerExited(); clock.advance(2)
        XCTAssertTrue(notch.phase.isExpanded)
        notch.isPinned = false
        clock.advance(0.4)
        XCTAssertEqual(notch.phase, .compact)
    }

    func testUnavailableHidesAndCancelsEverything() {
        notch.pointerEntered()
        notch.setAvailable(false)
        XCTAssertEqual(notch.phase, .hidden)
        XCTAssertEqual(notch.pendingTimerCount, 0)
        notch.pointerEntered(); notch.toggle(); clock.advance(1)
        XCTAssertEqual(notch.phase, .hidden, "no events are accepted while hidden")
        notch.setAvailable(true)
        XCTAssertEqual(notch.phase, .compact)
    }

    func testTransitionsAreReported() {
        var seen: [NotchInteraction.Phase] = []
        notch.onChange = { phase, _ in seen.append(phase) }
        notch.toggle(); notch.close(); notch.setAvailable(false)
        XCTAssertEqual(seen, [.expanded(focused: true), .compact, .hidden])
    }
}

// MARK: - Geometry and displays

func builtInScreen(id: UInt32 = 1, origin: CGPoint = .zero) -> ScreenDescriptor {
    // 14" MacBook Pro at "default": 1512 × 982 points, notch ≈ 185 × 32.
    let frame = CGRect(origin: origin, size: CGSize(width: 1512, height: 982))
    return ScreenDescriptor(displayID: id, name: "Built-in Retina Display", isBuiltIn: true, frame: frame, safeAreaTop: 32,
                            auxiliaryTopLeft: CGRect(x: origin.x, y: origin.y + 950, width: 663.5, height: 32),
                            auxiliaryTopRight: CGRect(x: origin.x + 848.5, y: origin.y + 950, width: 663.5, height: 32))
}

func externalScreen(id: UInt32 = 2, origin: CGPoint = CGPoint(x: -1920, y: 0)) -> ScreenDescriptor {
    ScreenDescriptor(displayID: id, name: "DELL S3225QS", isBuiltIn: false,
                     frame: CGRect(origin: origin, size: CGSize(width: 1920, height: 1080)), safeAreaTop: 0,
                     auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
}

final class NotchGeometryTests: XCTestCase {
    func testNotchRectAndFrames() throws {
        let screen = builtInScreen()
        XCTAssertEqual(screen.notchRect, CGRect(x: 663.5, y: 950, width: 185, height: 32))
        let layout = try XCTUnwrap(NotchLayout(screen: screen))
        XCTAssertEqual(layout.compact, CGRect(x: 663.5 - 26, y: 950, width: 185 + 52, height: 32),
                       "collapsed, it covers only the notch and two small ears")
        XCTAssertEqual(layout.expanded.maxY, screen.frame.maxY, "hangs from the top edge")
        XCTAssertEqual(layout.expanded.midX, layout.notch.midX, accuracy: 0.5)
        XCTAssertTrue(screen.frame.contains(layout.expanded))
        XCTAssertEqual(layout.expandedIslandWidth, 460, "a compact card, not a window")
        XCTAssertEqual(layout.expanded.height, NotchLayout.maxIslandHeight + NotchLayout.shadowInset)
        XCTAssertEqual(layout.maxContentHeight, NotchLayout.maxIslandHeight - 32)
        XCTAssertFalse(layout.isFloating)
    }

    func testShortDisplaysCapTheIslandAndFloatingHangsBelowTheMenuBar() throws {
        let short = ScreenDescriptor(displayID: 3, name: "Short", isBuiltIn: true,
                                     frame: CGRect(x: 0, y: 0, width: 1512, height: 500), safeAreaTop: 32,
                                     auxiliaryTopLeft: CGRect(x: 0, y: 468, width: 663.5, height: 32),
                                     auxiliaryTopRight: CGRect(x: 848.5, y: 468, width: 663.5, height: 32))
        let small = try XCTUnwrap(NotchLayout(screen: short))
        XCTAssertEqual(small.expanded.height, 360, "at most 72 % of the display height")
        XCTAssertEqual(small.expandedFrame(contentHeight: 2000).height, 360, "longer content scrolls inside")

        let external = externalScreen(origin: .zero)
        XCTAssertNil(NotchLayout(screen: external))
        let floating = NotchLayout(floatingOn: external)
        XCTAssertTrue(floating.isFloating)
        let frame = floating.expandedFrame(contentHeight: 200)
        XCTAssertEqual(frame.maxY, 1080 - 24 - NotchLayout.floatingGap)
        XCTAssertEqual(frame.midX, 960, accuracy: 0.5)
        XCTAssertEqual(frame.height, 232)
        XCTAssertTrue(external.frame.contains(frame))
    }

    func testExpandedFrameFollowsContentAndStaysAnchored() throws {
        let layout = try XCTUnwrap(NotchLayout(screen: builtInScreen()))
        let short = layout.expandedFrame(contentHeight: 40)
        let tall = layout.expandedFrame(contentHeight: 2000)
        XCTAssertEqual(short.height, 32 + NotchLayout.minContentHeight + NotchLayout.shadowInset)
        XCTAssertEqual(tall.height, 32 + layout.maxContentHeight + NotchLayout.shadowInset)
        XCTAssertEqual(short.maxY, 982, "always hangs from the top edge")
        XCTAssertEqual(tall.maxY, 982)
        XCTAssertEqual(short.minX, tall.minX)
    }

    func testDisplayWithoutNotchHasNoLayout() {
        XCTAssertNil(externalScreen().notchRect)
        XCTAssertNil(NotchLayout(screen: externalScreen()))
    }

    func testLayoutFollowsTheDisplayWhereverItIsArranged() throws {
        // The built-in display to the right of and above a main external display.
        let screen = builtInScreen(origin: CGPoint(x: 1920, y: 300))
        let layout = try XCTUnwrap(NotchLayout(screen: screen))
        XCTAssertTrue(screen.frame.contains(layout.expanded))
        XCTAssertEqual(layout.notch.minY, 300 + 950)
    }

    func testSmallOrScaledDisplayKeepsThePanelOnScreen() throws {
        let small = ScreenDescriptor(displayID: 9, name: "Scaled", isBuiltIn: true,
                                     frame: CGRect(x: 0, y: 0, width: 500, height: 400), safeAreaTop: 24,
                                     auxiliaryTopLeft: CGRect(x: 0, y: 376, width: 10, height: 24),
                                     auxiliaryTopRight: CGRect(x: 150, y: 376, width: 350, height: 24))
        let layout = try XCTUnwrap(NotchLayout(screen: small))
        XCTAssertGreaterThanOrEqual(layout.expanded.minX, small.frame.minX)
        XCTAssertLessThanOrEqual(layout.expanded.maxX, small.frame.maxX)
        XCTAssertLessThanOrEqual(layout.expanded.height, small.frame.height)
    }

    func testDisplayChoice() {
        let builtIn = builtInScreen(), external = externalScreen()
        XCTAssertEqual(DisplayChoice.pick(.automatic, from: [external, builtIn]), builtIn, "never one panel per display")
        XCTAssertNil(DisplayChoice.pick(.automatic, from: [external]), "external only: menu-bar fallback")
        XCTAssertNil(DisplayChoice.pick(.automatic, from: []))
        XCTAssertEqual(DisplayChoice.pick(.display(1), from: [external, builtIn]), builtIn)
        XCTAssertNil(DisplayChoice.pick(.display(2), from: [external, builtIn]), "a chosen display without a notch shows nothing")
        XCTAssertEqual(DisplayChoice.pick(.display(77), from: [external, builtIn]), builtIn, "a disconnected choice falls back to automatic")
    }
}

// MARK: - Settings

@MainActor
final class NotchSettingsTests: XCTestCase {
    func testDefaultsAndPersistence() throws {
        let suite = "PromptRelayTests.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = NotchSettings(defaults: defaults)
        XCTAssertTrue(first.notchEnabled, "the island opens on hover by default (Phase 3D: it is the interface)")
        XCTAssertFalse(first.notifyWhenReady)
        XCTAssertEqual(first.animation, .system)
        XCTAssertEqual(first.display, .automatic)

        first.notchEnabled = false
        first.notifyWhenReady = true
        first.animation = .reduced
        first.display = .display(42)

        let second = NotchSettings(defaults: defaults)
        XCTAssertFalse(second.notchEnabled, "an explicit choice is kept")
        XCTAssertTrue(second.notifyWhenReady)
        XCTAssertEqual(second.animation, .reduced)
        XCTAssertEqual(second.display, .display(42))
        second.display = .automatic
        XCTAssertEqual(NotchSettings(defaults: defaults).display, .automatic)
    }

    func testReduceMotion() throws {
        let suite = "PromptRelayTests.motion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = NotchSettings(defaults: defaults)
        XCTAssertTrue(s.reducesMotion(systemReduceMotion: true))
        XCTAssertFalse(s.reducesMotion(systemReduceMotion: false))
        s.animation = .full
        XCTAssertFalse(s.reducesMotion(systemReduceMotion: true))
        s.animation = .reduced
        XCTAssertTrue(s.reducesMotion(systemReduceMotion: false))
    }
}
