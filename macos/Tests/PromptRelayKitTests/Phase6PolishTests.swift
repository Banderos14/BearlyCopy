import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// Phase 6 polish: History disclosure, one copy confirmation everywhere,
/// island tooltips, plain-language facts, one-step answer transitions and
/// the themes' contrast.
@MainActor
final class Phase6PolishTests: XCTestCase {
    var suite: String!
    var defaults: MemorySettingsStore!
    var board: NSPasteboard!
    var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        suite = "PromptRelayTests.p6p.\(UUID().uuidString)"
        defaults = TestDefaults.named(suite)
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP6p-\(UUID().uuidString)"))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-p6p-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        removeTestDefaults(suite)
        try? FileManager.default.removeItem(at: root)
        Island.palette = IslandTheme.warmCocoa.palette
    }

    /// Two sessions in one project, each with answers.
    func twoSessions() -> FakeCore {
        let core = FakeCore(projects: [project("/a", sessions: 2, last: "2026-10-31T10:00:00.000000Z")])
        core.sessionsByProject["/a"] = [sessionSummary("sb", project: "/a", last: "2026-10-31T10:00:00.000000Z", lastTurn: 2),
                                        sessionSummary("sa", project: "/a", last: "2026-10-31T09:00:00.000000Z", lastTurn: 1)]
        core.turnsBySession["sa"] = [turn(1, text: "A1")]
        core.turnsBySession["sb"] = [turn(1, text: "B1"), turn(2, text: "B2")]
        core.showResult = { [core] key, i in
            .success(CoreResult(data: ShowData(session: try! core.session(key),
                                               turn: turn(i, chars: 2, text: "\(key)-\(i)")), warnings: []))
        }
        return core
    }

    func makeModel(_ core: FakeCore) async -> AppModel {
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults,
                         reportStore: ReportStore(root: root))
        await m.refreshNow()
        return m
    }

    func settle() async { try? await Task.sleep(nanoseconds: 150_000_000) }

    // MARK: History

    func testHistorySessionOpensClosesAndSwitchesByKey() async throws {
        let m = await makeModel(twoSessions())
        m.navigate(to: .history)
        let open = try XCTUnwrap(m.historyExpandedKey, "History opens with the session being read expanded")
        let a = try XCTUnwrap(m.allSessions.first { $0.sessionKey == "sa" })
        let b = try XCTUnwrap(m.allSessions.first { $0.sessionKey == "sb" })
        let current = open == "sa" ? a : b
        m.toggleHistorySession(current)
        XCTAssertNil(m.historyExpandedKey, "a second click on the open session closes it (the Phase 6 defect)")
        m.toggleHistorySession(current)
        XCTAssertEqual(m.historyExpandedKey, current.sessionKey, "and a third opens it again")

        let other = current.sessionKey == "sa" ? b : a
        m.toggleHistorySession(other)
        XCTAssertEqual(m.historyExpandedKey, other.sessionKey, "opening B closes A")
        await settle()
        XCTAssertEqual(m.selectedSessionKey, other.sessionKey, "and shows B's answers")

        // A refresh of the list neither opens nor closes anything.
        await m.refreshNow()
        XCTAssertEqual(m.historyExpandedKey, other.sessionKey)
        m.toggleHistorySession(other)
        await m.refreshNow()
        XCTAssertNil(m.historyExpandedKey, "closed stays closed after a refresh")
        m.historyQuery = "B"
        XCTAssertNil(m.historyExpandedKey, "searching does not open anything")
    }

    // MARK: Copy confirmations

    func testEachCopyConfirmsOnlyItselfAndOnlyAfterTheClipboardHasIt() async throws {
        let m = await makeModel(twoSessions())
        let ref = try XCTUnwrap(m.currentRef)
        XCTAssertFalse(m.isCopied(AppModel.answerToken(ref)))
        await m.copySelectedResponse()
        XCTAssertTrue(m.isCopied(AppModel.answerToken(ref)), "Copy Answer confirms itself")
        XCTAssertFalse(m.isCopied(AppModel.reviewToken(ref)), "and not Copy with Context")
        if case .copied(_, let n) = m.copyFeedback {
            XCTAssertEqual(n, board.string(forType: .string)?.unicodeScalars.count, "the count is what is on the clipboard")
        } else { XCTFail("copied") }

        // A failure is never a success.
        let failing = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-31T10:00:00.000000Z")])
        failing.sessionsByProject["/a"] = [sessionSummary("s", project: "/a", last: "2026-10-31T10:00:00.000000Z")]
        failing.turnsBySession["s"] = [turn(1)]
        let f = await makeModel(failing)
        await f.copySelectedContext()   // the fake Core has no context: the copy fails
        XCTAssertNil(f.copiedToken)
        if case .failed = f.copyFeedback {} else { XCTFail("the failure is reported") }

        // Another answer's button does not show "Copied!".
        NotchRootView.step(m, by: 1)
        XCTAssertFalse(m.isCopied(AppModel.answerToken(m.currentRef)) && m.currentRef != ref)
    }

    func testFilesAreConfirmedByReadingTheClipboardBack() throws {
        let dir = root.appendingPathComponent("f")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls = try (1...2).map { i -> URL in
            let u = dir.appendingPathComponent("f\(i).txt"); try Data("x".utf8).write(to: u); return u
        }
        let service = ClipboardService(pasteboard: board)
        XCTAssertNoThrow(try service.copyFiles(urls))
        let back = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        XCTAssertEqual(back.map(\.lastPathComponent), ["f1.txt", "f2.txt"])
    }

    // MARK: Tooltips

    func testTooltipsAppearAfterTheDelaySwitchAtOnceAndNeverLinger() async throws {
        let tips = IslandTooltips()
        let a = UUID(), b = UUID()
        tips.enter(a, text: "History", anchor: CGRect(x: 10, y: 10, width: 20, height: 20))
        XCTAssertNil(tips.tip, "not at once")
        try await Task.sleep(nanoseconds: 260_000_000)
        XCTAssertEqual(tips.tip?.text, "History", "after about 180 ms")
        tips.leave(a)
        tips.enter(b, text: "Settings", anchor: .zero)
        XCTAssertEqual(tips.tip?.text, "Settings", "crossing the gap switches without hiding")
        try await Task.sleep(nanoseconds: 260_000_000)
        tips.enter(a, text: "History", anchor: .zero)
        XCTAssertEqual(tips.tip?.text, "History", "moving straight to a neighbour switches without a new delay")
        tips.enter(b, text: "Settings", anchor: .zero)
        tips.leave(a)
        XCTAssertEqual(tips.tip?.text, "Settings", "leaving the old one does not hide the new one")
        tips.hideAll()
        XCTAssertNil(tips.tip, "closing the island removes it")
        tips.enter(a, text: "History", anchor: .zero)
        tips.leave(a)
        try await Task.sleep(nanoseconds: 260_000_000)
        XCTAssertNil(tips.tip, "a quick pass over a button shows nothing")
    }

    // MARK: Quick Peek wording

    func testQuickPeekFactsArePlainAndOnlyWhatExists() throws {
        let observed = try JSONDecoder().decode(ObservedCounts.self, from: Data("""
        {"tool_events":9,"runs_exit_zero":3,"runs_nonzero":0,"runs_unknown":0,"files_changed":2,"background_started":0,"commands_nonzero":1}
        """.utf8))
        var summary = AppModel.MaterialSummary()
        summary.documents = 1
        let texts = PeekContent.facts(observed: observed, summary: summary).map(\.text)
        XCTAssertEqual(texts, ["1 failed command", "3 commands completed", "2 files changed", "1 document"])
        XCTAssertFalse(texts.joined().contains("exit"), "no exit codes in Quick Peek")
        XCTAssertFalse(texts.joined().lowercased().contains("passed"), "exit 0 is never called a passed test")
        XCTAssertTrue(PeekContent.facts(observed: nil, summary: AppModel.MaterialSummary()).isEmpty,
                      "nothing to say: no row at all (no 'none')")
        XCTAssertEqual(HandoffContentsCard.commands(nil, captureOn: true), "not recorded")
        XCTAssertEqual(HandoffContentsCard.commands(nil, captureOn: false), "capture off")
    }

    // MARK: Motion

    /// Switching answers: the Answer card goes from the old height to the new
    /// one once; it never drops to the short preview while the full text loads.
    func testSwitchingAnswersChangesTheCardOnceWithoutAPreviewDip() async throws {
        let long = ReportFixture.report(sections: 8)
        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-31T10:00:00.000000Z")])
        core.sessionsByProject["/a"] = [sessionSummary("s", project: "/a", last: "2026-10-31T10:00:00.000000Z", lastTurn: 2)]
        core.turnsBySession["s"] = [turn(1, preview: "Short preview", chars: long.unicodeScalars.count),
                                    turn(2, preview: "Short preview", chars: long.unicodeScalars.count)]
        core.showResult = { [core] key, i in
            .success(CoreResult(data: ShowData(session: try! core.session(key), turn: turn(i, chars: long.unicodeScalars.count, text: long)),
                                warnings: []))
        }
        let m = await makeModel(core)
        let island = IslandHost(model: m, maxContentHeight: 448)
        for _ in 0..<5 { island.settle() }
        let before = try XCTUnwrap(island.presentation.layoutFrames["response.scroll"]).height
        XCTAssertGreaterThan(before, 100, "the long answer fills the card")
        var heights: [CGFloat] = []
        NotchRootView.step(m, by: 1)
        for _ in 0..<12 {
            island.host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            heights.append(island.presentation.layoutFrames["response.scroll"]?.height ?? 0)
        }
        XCTAssertGreaterThan(heights.min() ?? 0, before * 0.8, "no dip to the preview's height: \(heights)")
        island.assertNoOverlap(["details.header", "card.task", "card.response", "details.footer"])
        island.close()
    }

    // MARK: Themes

    func testEveryThemeKeepsTextAndStatesReadable() {
        for theme in IslandTheme.allCases {
            let p = theme.palette
            for surface in [p.card, p.cardRaised] {
                XCTAssertGreaterThanOrEqual(RGB.contrast(p.primary, surface), 7, "\(theme): primary text")
                XCTAssertGreaterThanOrEqual(RGB.contrast(p.secondary, surface), 4.5, "\(theme): secondary text")
                XCTAssertGreaterThanOrEqual(RGB.contrast(p.tertiary, surface), 4.5, "\(theme): tertiary text")
                for (name, state) in [("accent", p.accent), ("success", p.success), ("warning", p.warning),
                                      ("error", p.error), ("review", p.review)] {
                    XCTAssertGreaterThanOrEqual(RGB.contrast(state, surface), 4.5, "\(theme): \(name) as text")
                }
            }
            XCTAssertGreaterThanOrEqual(RGB.contrast(p.onProminent, p.prominent), 4.5, "\(theme): main button label")
        }
    }

    func testThemeChoicePersistsAndClassicStaysAvailable() {
        let settings = NotchSettings(defaults: defaults)
        XCTAssertEqual(settings.theme, .warmCocoa, "the default for new installs")
        settings.theme = .classic
        XCTAssertEqual(Island.palette, IslandTheme.classic.palette)
        XCTAssertEqual(NotchSettings(defaults: defaults).theme, .classic, "kept across launches")
    }

    /// PROMPT_RELAY_VISUALS=<dir>: Quick Peek and Details in each theme, same content (real SwiftUI renders).
    func testWriteThemeComparison() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PROMPT_RELAY_VISUALS"] else {
            throw XCTSkip("set PROMPT_RELAY_VISUALS=<dir>")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let m = await makeModel(FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-31T10:00:00.000000Z")]))
        _ = m.importReport(text: ReportFixture.report(sections: 6), task: "Сделай подробный отчёт о проделанной работе", projectPath: "/a",
                           sessionLabel: nil)
        let ref = try XCTUnwrap(m.currentRef)
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for (i, name) in ["PHASE6.md", "island.png"].enumerated() {
            let url = src.appendingPathComponent(name)
            try (name.hasSuffix(".png") ? Phase6Tests.png(seed: i) : Data("# Report\n".utf8)).write(to: url)
            try XCTUnwrap(m.reportStore).addFile(from: url, to: ref, source: .you, displayPath: name)
        }
        m.attachmentsVersion += 1
        await m.copySelectedResponse()
        for theme in IslandTheme.allCases {
            var island = IslandHost(model: m, surface: .peek, theme: theme)
            try island.png("\(dir)/theme-\(theme.rawValue)-peek.png")
            island.close()
            island = IslandHost(model: m, maxContentHeight: 341, theme: theme)
            try island.png("\(dir)/theme-\(theme.rawValue)-details.png")
            island.close()
        }
    }
}
