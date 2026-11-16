import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// Phase 19: the Quick Tour.
@MainActor
final class Phase19TourTests: XCTestCase {
    var suite: String!
    var defaults: MemorySettingsStore!
    var board: NSPasteboard!

    override func setUp() async throws {
        _ = NSApplication.shared
        suite = "PromptRelayTests.p19.\(UUID().uuidString)"
        defaults = TestDefaults.named(suite)
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP19-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        removeTestDefaults(suite)
    }

    func model(defaults: MemorySettingsStore? = nil) async -> AppModel {
        let core = FakeCore(projects: [project("/a", sessions: 0, last: nil)])
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults ?? self.defaults)
        await m.refreshNow()
        return m
    }

    func testNinePagesInOrderWithPlainEnglish() {
        let pages = AppModel.tourPages
        XCTAssertEqual(pages.count, 9)
        XCTAssertEqual(pages.map(\.id), Array(0..<9))
        XCTAssertTrue(pages.allSatisfy { !$0.title.isEmpty && $0.text.count >= 40 && $0.text.count <= 200 }, "short, readable")
        XCTAssertEqual(Set(pages.map(\.title)).count, 9, "no repeated page")
    }

    func testBackAndNextStayInsideTheTour() async {
        let m = await model()
        m.startTour()
        XCTAssertEqual(m.route, .tour)
        XCTAssertEqual(m.tourPage, 0)
        m.tourBack()
        XCTAssertEqual(m.tourPage, 0, "Back on the first page does nothing")
        for _ in 0..<20 { m.tourNext() }
        XCTAssertEqual(m.tourPage, 8, "Next stops on the last page")
        XCTAssertTrue(m.tourIsLastPage)
        m.tourBack()
        XCTAssertEqual(m.tourPage, 7)
    }

    func testFirstLaunchShowsItOnceAndSkipIsRemembered() async {
        let m = await model()
        XCTAssertTrue(m.shouldAutoShowTour, "a fresh install shows it")
        m.startTour()
        m.tourNext()
        m.finishTour()
        XCTAssertTrue(m.tourSeen)
        XCTAssertFalse(m.shouldAutoShowTour)
        XCTAssertEqual(m.route, .home)
        XCTAssertEqual(m.tourPage, 0)
        let again = await model()
        XCTAssertFalse(again.shouldAutoShowTour, "a new run of the app does not show it again")
    }

    func testLeavingWithTheIslandsOwnBackStillCountsAsSeen() async {
        let m = await model()
        m.markTourSeen()   // what the page does when it appears
        XCTAssertFalse(m.shouldAutoShowTour)
        let again = await model()
        XCTAssertFalse(again.shouldAutoShowTour)
    }

    func testItCanBeReopenedAfterwardsAndDoneCanLeadToSetUp() async {
        let m = await model()
        m.finishTour()
        m.startTour()
        XCTAssertEqual(m.route, .tour)
        XCTAssertEqual(m.tourPage, 0)
        m.finishTour(openSetup: true)
        XCTAssertEqual(m.route, .setup)
    }

    func testNothingElseChangesAndTestsWithoutStorageNeverAutoOpen() async {
        let core = FakeCore(projects: [project("/a", sessions: 0, last: nil)])
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil)
        XCTAssertFalse(m.shouldAutoShowTour, "no storage, no automatic tour")
    }

    func testEveryPageFitsTheIslandAtTheSmallestAndLargestHeights() async throws {
        let m = await model()
        m.startTour()
        for height in [CGFloat(268), 400, 568] {
            for page in 0..<9 {
                m.tourPage = page
                let island = IslandHost(model: m, maxContentHeight: height)
                island.settle()
                let frames = island.presentation.layoutFrames
                XCTAssertTrue(island.height <= height + island.presentation.notchSize.height + 1, "page \(page) at \(height)")
                _ = frames
                island.close()
            }
        }
    }

    /// PROMPT_RELAY_README_SHOTS=<dir>: one render per page.
    func testWriteTourPages() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PROMPT_RELAY_TOUR_SHOTS"] else { throw XCTSkip("set PROMPT_RELAY_TOUR_SHOTS") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let m = await model()
        m.startTour()
        for page in 0..<9 {
            m.tourPage = page
            let island = IslandHost(model: m, maxContentHeight: 268)
            try island.png2x("\(dir)/tour-\(page + 1).png")
            island.close()
        }
    }
}
