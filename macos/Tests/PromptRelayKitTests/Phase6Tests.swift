import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// Phase 6: the island's height after a re-measure, Details without
/// overlaps, the hand-off bound to one report and one set of files,
/// chronological answer numbers, and the Clipboard workspace.
@MainActor
final class Phase6Tests: XCTestCase {
    var suite: String!
    var defaults: MemorySettingsStore!
    var board: NSPasteboard!
    var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        suite = "PromptRelayTests.p6.\(UUID().uuidString)"
        defaults = TestDefaults.named(suite)
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP6-\(UUID().uuidString)"))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-p6-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        removeTestDefaults(suite)
        try? FileManager.default.removeItem(at: root)
    }

    func makeModel(_ core: FakeCore? = nil) async -> AppModel {
        let core = core ?? {
            let c = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-30T10:00:00.000000Z")])
            c.sessionsByProject["/a"] = [sessionSummary("sa", project: "/a", last: "2026-10-30T10:00:00.000000Z")]
            c.turnsBySession["sa"] = [turn(1, preview: "Ответ", chars: 5, request: "Задача")]
            return c
        }()
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults,
                         reportStore: ReportStore(root: root))
        await m.refreshNow()
        return m
    }

    @discardableResult
    func importReport(_ m: AppModel, _ text: String, files: [String]) throws -> ReportRef {
        _ = m.importReport(text: text, task: "Задача для \(text.prefix(12))", projectPath: "/a", sessionLabel: nil)
        let ref = try XCTUnwrap(m.currentRef)
        let dir = root.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, name) in files.enumerated() {
            let url = dir.appendingPathComponent(name)
            let data = name.hasSuffix(".png") ? Self.png(seed: i + text.count) : Data("# \(name)\nfile of \(text.prefix(12))\n".utf8)
            try data.write(to: url)
            try XCTUnwrap(m.reportStore).addFile(from: url, to: ref, source: .you, displayPath: name)
        }
        m.attachmentsVersion += 1
        XCTAssertEqual(m.attachments(for: ref).count, files.count, "fixture files attached")
        return ref
    }

    // MARK: Height reports (the Full Report defect)

    /// Two reports in one layout pass: the second equalled the old, not yet
    /// replaced height and was dropped; the first (93 pt) then won.
    func testASecondHeightReportBeforeTheFirstIsAppliedIsNotLost() {
        let p = NotchPresentation()
        p.maxContentHeight = 448
        p.contentHeight = 319
        var requested: [CGFloat] = []
        p.onContentHeight = { requested.append($0) }   // applied later, like the controller
        p.reportContentHeight(93)
        p.reportContentHeight(319)
        XCTAssertEqual(requested, [93, 319], "the last request is the one that counts")
        p.reportContentHeight(319)
        XCTAssertEqual(requested.count, 2, "an unchanged request is not repeated")
    }

    // MARK: Hand-off state

    func testHandoffBelongsToOneReportAndEndsWhenAnotherIsShown() async throws {
        let m = await makeModel()
        let a = try importReport(m, "Report A", files: ["a1.md", "a2.png"])
        let b = try importReport(m, "Report B", files: ["b1.md"])
        let c = try importReport(m, "Report C", files: [])
        m.open(a)
        await m.copySelectedContext()
        let step = try XCTUnwrap(m.activeHandoff, "files chosen: step 2 opens")
        XCTAssertEqual(step.ref, a)
        XCTAssertEqual(step.fileCount, 2)

        m.open(b)
        XCTAssertNil(m.handoffStep, "switching the report ends A's step 2 at once")
        XCTAssertNil(m.activeHandoff)
        XCTAssertTrue(m.handoffFileURLs().isEmpty, "A's files are never offered for B")
        await m.copySelectedContext()
        XCTAssertEqual(m.activeHandoff?.ref, b)
        XCTAssertEqual(m.activeHandoff?.fileCount, 1, "B's own files")
        let bFiles = m.handoffFileURLs().map(\.lastPathComponent)
        XCTAssertEqual(bFiles, ["b1.md"])

        // Fast A → B → C: no state crosses over.
        m.open(a); m.open(b); m.open(c)
        XCTAssertNil(m.handoffStep)
        await m.copySelectedContext()
        XCTAssertNil(m.handoffStep, "no files: the text copy has no step 2")
        XCTAssertNotNil(board.string(forType: .string), "the text is on the clipboard")
    }

    func testSwitchingToASessionEndsTheHandoffAndDoneKeepsTheClipboard() async throws {
        let m = await makeModel()
        let a = try importReport(m, "Report A", files: ["a1.md"])
        m.open(a)
        await m.copySelectedContext()
        let copied = board.string(forType: .string)
        XCTAssertNotNil(m.activeHandoff)
        m.endHandoff()
        XCTAssertNil(m.handoffStep)
        XCTAssertEqual(board.string(forType: .string), copied, "Done does not clear the clipboard")

        await m.copySelectedContext()
        XCTAssertNotNil(m.activeHandoff)
        let session = try XCTUnwrap(m.allSessions.first)
        m.focusSession(session)
        XCTAssertNil(m.handoffStep, "another session: the old step 2 is gone")
        XCTAssertEqual(m.attachments(for: a).count, 1, "the attachments themselves stay")
    }

    func testChangedSelectionAfterTheCopyIsNotHandedOverSilently() async throws {
        let m = await makeModel()
        let a = try importReport(m, "Report A", files: ["one.md", "two.md"])
        m.open(a)
        await m.copySelectedContext()
        XCTAssertFalse(m.handoffSelectionChanged)
        XCTAssertEqual(m.handoffFileURLs().count, 2)
        let first = try XCTUnwrap(m.attachments(for: a).first)
        m.setSelected(first, false)
        XCTAssertTrue(m.handoffSelectionChanged, "the step knows the choice changed")
        XCTAssertTrue(m.handoffFileURLs().isEmpty, "neither the old nor the new set is handed over")
        board.clearContents()
        m.copyHandoffFiles()
        XCTAssertTrue(((board.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []).isEmpty, "nothing copied")
        if case .failed = m.copyFeedback {} else { XCTFail("the user is told to copy again") }
        await m.copySelectedContext()
        XCTAssertFalse(m.handoffSelectionChanged)
        XCTAssertEqual(m.activeHandoff?.fileCount, 1, "a new copy takes the new choice")
    }

    /// Phase 7.1 changed this contract: closing keeps step 2 (Continue
    /// Transfer); only Done ends it.
    func testClosingTheIslandKeepsStepTwoUntilDone() async throws {
        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-30T10:00:00.000000Z")])
        core.sessionsByProject["/a"] = [sessionSummary("sa", project: "/a", last: "2026-10-30T10:00:00.000000Z")]
        core.turnsBySession["sa"] = [turn(1)]
        let m = await makeModel(core)
        let a = try importReport(m, "Report A", files: ["a1.md"])
        let settings = NotchSettings(defaults: defaults)
        settings.animation = .reduced
        settings.mascotEnabled = false
        let controller = NotchController(model: m, settings: settings, actions: SurfaceActions(openWindow: {}, openStatus: {}, quit: {}),
                                         screens: FakeScreens([builtInScreen()]), scheduler: ManualScheduler(),
                                         center: NotificationCenter(), workspaceCenter: NotificationCenter(), makeHotKey: { nil },
                                         neighbors: FakeNeighbors(), pointerEvents: FakePointerEvents())
        controller.start()
        controller.present(.home)
        m.open(a)
        await m.copySelectedContext()
        XCTAssertNotNil(m.activeHandoff)
        controller.interaction.close()
        XCTAssertEqual(m.handoffStep?.resumed, true, "closed: it waits as Continue Transfer")
        XCTAssertEqual(m.attachments(for: a).count, 1)
        m.endHandoff()
        XCTAssertNil(m.handoffStep, "Done ends it")
        controller.stop()
    }

    // MARK: Answer order

    func testAnswersAreNumberedInTheOrderTheyCame() async throws {
        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-30T10:00:00.000000Z")])
        core.sessionsByProject["/a"] = [sessionSummary("sa", project: "/a", last: "2026-10-30T10:00:00.000000Z", lastTurn: 4)]
        core.turnsBySession["sa"] = [turn(1), turn(2), turn(3, status: "awaiting_response", preview: nil), turn(4)]
        let m = await makeModel(core)
        XCTAssertEqual(m.selectedTurnIndex, 4, "the newest answer is shown")
        XCTAssertEqual(AnswerStepper.position(m, turn: 4)?.position, 3, "the newest is N/N")
        XCTAssertEqual(AnswerStepper.position(m, turn: 4)?.count, 3, "a turn without an answer is not counted")
        XCTAssertEqual(AnswerStepper.position(m, turn: 1)?.position, 1, "the first is 1/N")
        NotchRootView.step(m, by: 1)   // ← previous
        XCTAssertEqual(m.selectedTurnIndex, 2)
        XCTAssertEqual(AnswerStepper.position(m, turn: 2)?.position, 2)
    }

    // MARK: Layout

    /// Answers with different task lengths, answer lengths and attachments:
    /// no block ever overlaps another and the footer stays below the content.
    func testDetailsNeverOverlapsAcrossDifferentAnswers() async throws {
        let m = await makeModel()
        let long = try importReport(m, ReportFixture.report(sections: 12), files: ["a.md", "b.md", "c.md", "d.md", "e.md", "f.md"])
        let short = try importReport(m, "Коротко: готово.", files: [])
        for maxContent: CGFloat in [448, 341, 300] {
            let island = IslandHost(model: m, maxContentHeight: maxContent)
            // Below 330 pt Details shows one column at a time (Answer / For Review).
            let ids = maxContent >= 330 ? ["details.header", "card.task", "card.response", "card.handoff", "card.attachments", "details.footer"]
                                        : ["details.header", "card.task", "card.response", "details.footer"]
            for ref in [long, short, long] {
                m.open(ref)
                island.assertNoOverlap(ids)
                XCTAssertLessThanOrEqual(island.height, 32 + maxContent)
            }
            await m.copySelectedContext()
            // Phase 7.1: one column with step 2 moves the Task card to For Review.
            island.assertNoOverlap(maxContent >= 330 ? ["details.header", "card.task", "card.response", "card.attachments", "details.footer"]
                                                     : ["details.header", "card.response", "details.footer"])
            let handoff = try XCTUnwrap(island.presentation.layoutFrames["details.handoff"], "step 2 is the footer")
            XCTAssertEqual(handoff.minY, try XCTUnwrap(island.presentation.layoutFrames["details.footer"]).minY, accuracy: 0.5)
            m.endHandoff()
            island.close()
        }
    }

    func testShortAnswersLeaveNoEmptySpace() async throws {
        let m = await makeModel()
        try importReport(m, "Коротко: готово.", files: [])
        let island = IslandHost(model: m, maxContentHeight: 448)
        let response = try XCTUnwrap(island.presentation.layoutFrames["response.scroll"])
        XCTAssertLessThan(response.height, 40, "the answer's area is as tall as the answer")
        XCTAssertLessThan(island.height, 32 + 448 - 60, "the island is not padded out to its maximum")
        island.close()
    }

    func testALongTaskScrollsInsideItsCardAtABoundedHeight() async throws {
        let m = await makeModel()
        let task = (1...80).map { "Строка задачи \($0): сделай так, чтобы всё работало." }.joined(separator: "\n")
        _ = m.importReport(text: "Ответ", task: task, projectPath: "/a", sessionLabel: nil)
        var frames: [String: CGRect] = [:]
        let view = VStack(spacing: 0) {
            TaskCard(facts: ReportFacts(model: m), expanded: .constant(true))
        }
        .frame(width: 400)
        .coordinateSpace(name: NotchRootView.space)
        .environment(\.islandFrameSink, { id, rect in frames[id] = rect })
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        let scroll = try XCTUnwrap(frames["task.body"], "the expanded task scrolls")
        XCTAssertLessThanOrEqual(scroll.height, TaskCard.expandedHeight + 0.5, "80 lines never grow the card past its limit")
        XCTAssertGreaterThan(scroll.height, 60)
    }

    // MARK: Clipboard

    func testClipboardImagesExportUnderReadableNamesAndCopyAsFiles() throws {
        let folder = root.appendingPathComponent("clip")
        let source = NSPasteboard(name: NSPasteboard.Name("PromptRelayP6src-\(UUID().uuidString)"))
        defer { source.releaseGlobally() }
        let history = ClipboardImageHistory(folder: folder, pasteboard: source)
        history.setEnabled(true)
        defer { history.setEnabled(false) }
        // Screenshots in a row, one more than kept (⌃⇧⌘4 puts PNG data on the clipboard).
        for i in 0..<(ClipboardImageHistory.limit + 1) {
            source.clearContents()
            source.setData(Self.png(seed: i), forType: .png)
            history.poll()
        }
        XCTAssertEqual(history.items.count, ClipboardImageHistory.limit, "only the latest ten are kept")
        let chosen = Array(history.items.prefix(3))
        let urls = history.exportFiles(chosen)
        XCTAssertEqual(urls.count, 3)
        XCTAssertTrue(urls.allSatisfy { $0.lastPathComponent.hasPrefix("Screenshot ") && $0.pathExtension == "png" })
        XCTAssertEqual(Set(urls.map(\.lastPathComponent)).count, 3, "names never collide")
        for (url, item) in zip(urls, chosen) {
            XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: history.url(for: item)), "byte-identical copies")
        }

        let m = AppModel(core: FakeCore(projects: []), clipboard: ClipboardService(pasteboard: board), dataDirectory: nil)
        m.clipboardImages = history
        m.copyClipboardImages(chosen)
        let onBoard = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        XCTAssertEqual(onBoard.map(\.lastPathComponent), urls.map(\.lastPathComponent), "the three files, in the chosen order")
        XCTAssertNotNil(board.data(forType: ClipboardImageHistory.ownType), "marked as Prompt Relay's own: never taken back in")
        history.clearAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("share").path), "Clear All removes exported copies")
    }

    func testTheImageHistoryStartsOnlyOnceItsNoticeWasShown() throws {
        let history = ClipboardImageHistory(folder: root.appendingPathComponent("clip2"),
                                            pasteboard: NSPasteboard(name: NSPasteboard.Name("PromptRelayP6n-\(UUID().uuidString)")))
        let m = AppModel(core: FakeCore(projects: []), clipboard: ClipboardService(pasteboard: board), dataDirectory: nil,
                         stateDefaults: defaults)
        m.clipboardImages = history
        m.clipboardNoticeVisible = true
        XCTAssertFalse(m.clipboardHistoryEnabled, "nothing is kept before the notice is seen")
        m.clipboardNoticeAppeared()
        XCTAssertTrue(m.clipboardHistoryEnabled, "on by default once the user has been told")
        m.answerClipboardNotice(keepOn: false)
        XCTAssertFalse(m.clipboardHistoryEnabled, "Turn Off stops it")
        XCTAssertFalse(m.clipboardNoticeVisible)
        XCTAssertEqual(defaults.object(forKey: "clipboard.imagesEnabled") as? Bool, false, "the choice persists")
        history.setEnabled(false)
    }

    func testRecentCopiesAreTheClipboardsTextTab() async throws {
        let m = await makeModel()
        try importReport(m, "Report A", files: [])
        await m.copySelectedResponse()
        XCTAssertEqual(m.copyHistory.count, 1)
        m.navigate(to: .copies)
        XCTAssertEqual(m.route, .clipboard)
        XCTAssertEqual(m.clipboardTab, .text)
        m.removeCopyRecord(try XCTUnwrap(m.copyHistory.first))
        XCTAssertTrue(m.copyHistory.isEmpty)
    }

    /// PROMPT_RELAY_VISUALS=<dir>: PNGs of the Phase 6 states (real SwiftUI renders).
    func testWritePhase6Visuals() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PROMPT_RELAY_VISUALS"] else {
            throw XCTSkip("set PROMPT_RELAY_VISUALS=<dir> to write visual examples")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let m = await makeModel()
        let long = try importReport(m, ReportFixture.report(sections: 12), files: ["PHASE6_REPORT.md", "island.png", "settings.png"])
        let short = try importReport(m, "Коротко: всё готово, тесты прошли.", files: [])
        for (name, ref, maxContent) in [("details-long", long, CGFloat(448)), ("details-long-14in", long, 341), ("details-short", short, 448)] {
            m.open(ref)
            let island = IslandHost(model: m, maxContentHeight: maxContent)
            try island.png("\(dir)/\(name).png")
            island.close()
        }
        m.open(long)
        await m.copySelectedContext()
        var island = IslandHost(model: m, maxContentHeight: 341)
        try island.png("\(dir)/details-step2.png")
        island.close()
        island = IslandHost(model: m, surface: .peek)
        try island.png("\(dir)/peek-step2.png")
        island.close()
        m.endHandoff()
        island = IslandHost(model: m, surface: .peek)
        try island.png("\(dir)/peek.png")
        island.close()
        m.open(short)
        island = IslandHost(model: m, surface: .peek)
        try island.png("\(dir)/peek-short.png")
        island.close()
        m.open(long)
        await m.copySelectedResponse()
        m.navigate(to: .clipboard)
        island = IslandHost(model: m, maxContentHeight: 341)
        try island.png("\(dir)/clipboard-text.png")
        island.close()
        let history = ClipboardImageHistory(folder: root.appendingPathComponent("clipv"),
                                            pasteboard: NSPasteboard(name: NSPasteboard.Name("PromptRelayP6v-\(UUID().uuidString)")))
        m.clipboardImages = history
        history.setEnabled(true)
        for i in 0..<5 { history.keep(Self.png(seed: i * 3), name: nil) }
        m.clipboardTab = .images
        island = IslandHost(model: m, maxContentHeight: 341)
        try island.png("\(dir)/clipboard-images.png")
        island.close()
        history.setEnabled(false)
        for route in [AppModel.IslandRoute.history, .settings, .reader] {
            m.navigate(to: route)
            island = IslandHost(model: m, maxContentHeight: 341)
            try island.png("\(dir)/route-\(route.rawValue).png")
            island.close()
        }
    }

    /// PROMPT_RELAY_REAL_RENDER=<dir>: the real captured history (read-only,
    /// private pasteboard, nothing persisted) rendered in Phase 6's views:
    /// the newest answer, then each earlier one of its session.
    func testRenderRealHistory() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["PROMPT_RELAY_REAL_RENDER"] else { throw XCTSkip("set PROMPT_RELAY_REAL_RENDER=<dir>") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var processEnv = env
        processEnv["PROMPT_RELAY_CLI"] = env["PROMPT_RELAY_CLI"] ?? Repo.cli
        let locator = CoreLocator(processEnvironment: processEnv, bundleResourceURL: nil, defaults: { _ in nil })
        let m = AppModel(core: CoreClient.live(locator: locator), clipboard: ClipboardService(pasteboard: board), dataDirectory: nil)
        await m.refreshNow()
        let deadline = Date().addingTimeInterval(20)
        while m.selectedResponseText == nil, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        var lines: [String] = []
        for (i, index) in NotchRootView.answerTurns(m).prefix(4).enumerated() {
            m.selectTurn(index)
            while m.selectedResponseText == nil, Date() < deadline.addingTimeInterval(20) { try await Task.sleep(nanoseconds: 50_000_000) }
            for maxContent: CGFloat in [341, 448] {
                let island = IslandHost(model: m, maxContentHeight: maxContent)
                island.assertNoOverlap(["details.header", "card.task", "card.response", "card.handoff", "card.attachments", "details.footer"])
                try island.png("\(dir)/real-details-\(i)-\(Int(maxContent)).png")
                island.close()
            }
            let pos = AnswerStepper.position(m, turn: index)
            lines.append("turn \(index): \(pos.map { "\($0.position)/\($0.count)" } ?? "-") origin \(m.selectedTurn?.requestOrigin.map { "\($0)" } ?? "-")")
        }
        let peek = IslandHost(model: m, surface: .peek)
        try peek.png("\(dir)/real-peek.png")
        peek.close()
        try lines.joined(separator: "\n").write(toFile: "\(dir)/order.txt", atomically: true, encoding: .utf8)
    }

    static func png(seed: Int) -> Data {
        let image = NSImage(size: NSSize(width: 40 + seed, height: 30), flipped: false) { rect in
            NSColor(calibratedHue: CGFloat(seed) / 7, saturation: 0.8, brightness: 0.9, alpha: 1).setFill(); rect.fill()
            return true
        }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
}

extension NotchControllerTests {
    /// Phase 6 regression, real panel: Full Report, Formatted → Plain Text →
    /// Formatted (and fast switching). The island kept 93 pt of 319 and cut
    /// the report off; now its height never changes and the text stays whole.
    func testFullReportFormatSwitchKeepsTheIslandAndTheText() async throws {
        let long = ReportFixture.report(sections: 10)
        core.showResult = { [core] key, i in
            .success(CoreResult(data: ShowData(session: try! core!.session(key), turn: turn(i, chars: long.unicodeScalars.count, text: long)),
                                warnings: []))
        }
        core.turnsBySession["s"] = [turn(1, preview: "Первый", chars: long.unicodeScalars.count)]
        let controller = makeController()
        controller.start()
        await model.refreshNow()
        controller.present(.reader)
        let panel = try XCTUnwrap(notchPanels().first)
        let content = try XCTUnwrap(panel.contentView)
        func segmented(_ v: NSView) -> NSSegmentedControl? { (v as? NSSegmentedControl) ?? v.subviews.lazy.compactMap(segmented).first }
        for _ in 0..<20 { await settle(0.1); content.layoutSubtreeIfNeeded() }
        let height = panel.frame.height
        XCTAssertGreaterThan(height, 250, "the reader has room")
        let control = try XCTUnwrap(segmented(content))
        for (i, segment) in [1, 0, 1, 0, 1, 0, 0].enumerated() {
            control.selectedSegment = segment
            _ = control.sendAction(control.action, to: control.target)
            for _ in 0..<(i < 2 ? 8 : 1) { await settle(0.05); content.layoutSubtreeIfNeeded() }
        }
        for _ in 0..<10 { await settle(0.05); content.layoutSubtreeIfNeeded() }
        XCTAssertEqual(panel.frame.height, height, "Formatted again: the island keeps its height")
        XCTAssertEqual(controller.presentation.contentHeight + controller.presentation.notchSize.height, height, accuracy: 1)
        let body = try XCTUnwrap(controller.presentation.layoutFrames["reader.body"])
        let actions = try XCTUnwrap(controller.presentation.layoutFrames["reader.actions"])
        XCTAssertLessThan(body.maxY, actions.minY, "the copy buttons stay below the text")
        XCTAssertLessThanOrEqual(actions.maxY, height - 12, "and inside the island")
        let scroll = try XCTUnwrap(Self.answerScrollView(in: content), "the formatted report scrolls")
        XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, scroll.contentView.bounds.height * 3, "the whole report is there")
        await model.copySelectedResponse()
        XCTAssertEqual(pasteboard.string(forType: .string), long, "Copy Response is unchanged by the view mode")
        controller.stop()
    }
}
