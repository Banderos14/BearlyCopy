import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// Phase 6 visual pass: Warm Cocoa, paired card rows, Task motion, compact
/// tooltips kept inside the island, the package Preview and attachment preview.
@MainActor
final class Phase6VisualTests: XCTestCase {
    var suite: String!
    var defaults: MemorySettingsStore!
    var board: NSPasteboard!
    var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        suite = "PromptRelayTests.p6v.\(UUID().uuidString)"
        defaults = TestDefaults.named(suite)
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP6v-\(UUID().uuidString)"))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-p6v-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        removeTestDefaults(suite)
        try? FileManager.default.removeItem(at: root)
        Island.palette = IslandTheme.warmCocoa.palette
    }

    func makeModel() async -> AppModel {
        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-31T10:00:00.000000Z")])
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults,
                         reportStore: ReportStore(root: root))
        await m.refreshNow()
        return m
    }

    @discardableResult
    func importReport(_ m: AppModel, _ text: String, task: String = "Задача", files: [(String, Data)] = []) throws -> ReportRef {
        _ = m.importReport(text: text, task: task, projectPath: "/a", sessionLabel: nil)
        let ref = try XCTUnwrap(m.currentRef)
        let dir = root.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in files {
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            try XCTUnwrap(m.reportStore).addFile(from: url, to: ref, source: .you, displayPath: name)
        }
        m.attachmentsVersion += 1
        return ref
    }

    // MARK: Theme

    func testWarmCocoaIsTheDefaultAndAnExplicitChoiceIsKept() {
        XCTAssertEqual(NotchSettings(defaults: defaults).theme, .warmCocoa, "new installs")
        let chosen = NotchSettings(defaults: defaults)
        chosen.theme = .softSpectrum
        XCTAssertEqual(NotchSettings(defaults: defaults).theme, .softSpectrum, "an existing explicit choice is not overwritten")
        XCTAssertEqual(Set(IslandTheme.allCases), [.warmCocoa, .classic, .softSpectrum, .materialCalm], "old themes stay")
    }

    // MARK: Tooltips

    func testTooltipsStayInsideTheIslandOnEveryEdge() {
        let size = CGSize(width: 640, height: 373)
        let width: CGFloat = 200, height: CGFloat = 30
        for anchor in [CGRect(x: 600, y: 330, width: 26, height: 26),   // bottom right (Settings)
                       CGRect(x: 10, y: 330, width: 120, height: 28),   // bottom left (Copy Answer)
                       CGRect(x: 300, y: 40, width: 30, height: 20)] {  // top middle
            let tip = TipPlacement.frame(anchor: anchor, tip: CGSize(width: width, height: height), island: size, band: 32)
            XCTAssertGreaterThanOrEqual(tip.minX, 8); XCTAssertLessThanOrEqual(tip.maxX, size.width - 8, "\(anchor)")
            XCTAssertGreaterThanOrEqual(tip.minY, 0); XCTAssertLessThanOrEqual(tip.maxY, size.height, "\(anchor)")
            XCTAssertFalse(tip.intersects(anchor.insetBy(dx: 1, dy: 1)), "never over its own control \(anchor)")
        }
        XCTAssertLessThan(TipPlacement.frame(anchor: CGRect(x: 10, y: 330, width: 10, height: 28), tip: CGSize(width: width, height: 30),
                                             island: size, band: 32).minY, 330,
                          "no room below: above the control")
    }

    // MARK: Geometry

    func testCardsOfARowEndOnTheSameLineAndNothingOverlaps() async throws {
        let m = await makeModel()
        let png = Phase6Tests.png(seed: 1)
        try importReport(m, ReportFixture.report(sections: 10), files: [("a.md", Data("# A\n".utf8)), ("b.png", png)])
        try importReport(m, "Коротко.", files: [])
        for ref in [m.imports[0].ref, m.imports[1].ref] {
            m.open(ref)
            for maxContent: CGFloat in [341, 448] {
                let island = IslandHost(model: m, maxContentHeight: maxContent)
                let f = island.presentation.layoutFrames
                let task = try XCTUnwrap(f["card.task"]), context = try XCTUnwrap(f["card.handoff"])
                let answer = try XCTUnwrap(f["card.response"]), files = try XCTUnwrap(f["card.attachments"])
                XCTAssertEqual(task.maxY, context.maxY, accuracy: 0.5, "top row ends on one line")
                XCTAssertEqual(answer.maxY, files.maxY, accuracy: 0.5, "bottom row ends on one line")
                XCTAssertEqual(task.minY, context.minY, accuracy: 0.5)
                island.assertNoOverlap(["details.header", "card.task", "card.handoff", "card.response", "card.attachments", "details.footer"])
                island.close()
            }
        }
    }

    /// More → Less in the real island: the Task card changes height once per
    /// click, never dropping below its collapsed height, the Answer keeps room.
    func testTaskExpandsWithoutASnap() async throws {
        let m = await makeModel()
        let task = (1...40).map { "Строка \($0) длинного запроса" }.joined(separator: "\n")
        try importReport(m, ReportFixture.report(sections: 4), task: task)
        let island = IslandHost(model: m, maxContentHeight: 448)
        let collapsed = try XCTUnwrap(island.presentation.layoutFrames["task.body"]).height
        var heights: [CGFloat] = []
        withAnimation(Island.geometry(reduceMotion: false)) { m.taskExpanded = true }
        for _ in 0..<10 {
            island.host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            heights.append(island.presentation.layoutFrames["task.body"]?.height ?? 0)
        }
        XCTAssertGreaterThanOrEqual(heights.min() ?? 0, collapsed - 0.5, "never below the collapsed height: \(heights)")
        XCTAssertGreaterThan(heights.last ?? 0, collapsed + 40, "it opened: \(heights)")
        XCTAssertLessThanOrEqual(heights.last ?? 0, TaskCard.expandedHeight + 0.5, "bounded; the rest scrolls inside")
        island.assertNoOverlap(["details.header", "card.task", "card.handoff", "card.response", "card.attachments", "details.footer"])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(island.presentation.layoutFrames["response.scroll"]).height, 40, "the Answer keeps room")
        m.taskExpanded = false
        island.settle()
        XCTAssertEqual(try XCTUnwrap(island.presentation.layoutFrames["task.body"]).height, collapsed, accuracy: 0.5, "Less closes it")
        island.close()
    }

    // MARK: Copy with Context

    func testPreviewShowsExactlyWhatIsCopiedAndBelongsToOneAnswer() async throws {
        let m = await makeModel()
        let answer = "Ответ с **Markdown** и уникальной строкой 7f3a."
        let a = try importReport(m, answer, files: [("notes.md", Data("# Notes\n".utf8))])
        await m.openPackPreview()
        XCTAssertEqual(m.route, .packagePreview)
        guard case .ready(let pack)? = m.packPreview else { return XCTFail("built") }
        XCTAssertTrue(pack.text.hasPrefix("# Copy with Context:"), "neutral heading")
        XCTAssertEqual(pack.text.components(separatedBy: answer).count - 1, 1, "the answer once")
        XCTAssertTrue(pack.text.contains("notes.md"), "the chosen file is listed")
        await m.copyPreviewedPack()
        XCTAssertEqual(board.string(forType: .string), pack.text, "the copy is the previewed text, byte for byte")
        XCTAssertNotNil(m.activeHandoff, "step 2 for the chosen file")

        try importReport(m, "Другой ответ")
        XCTAssertNil(m.packPreview, "another answer: the old preview is dropped")
        XCTAssertNil(m.handoffStep)
        m.open(a)
        XCTAssertNil(m.packPreview)
    }

    // MARK: Attachment preview

    func testOpeningAnAttachmentChangesNothingAndShowsItsText() async throws {
        let m = await makeModel()
        let ref = try importReport(m, "Ответ", files: [("README.md", Data("# Заголовок\nтекст\n".utf8)),
                                                       ("shot.png", Phase6Tests.png(seed: 3))])
        let before = (m.currentRef, m.attachments(for: ref).map(\.isSelected))
        let doc = try XCTUnwrap(m.attachments(for: ref).first { $0.originalFilename == "README.md" })
        m.openAttachmentPreview(doc)
        XCTAssertEqual(m.route, .attachmentPreview)
        XCTAssertEqual(m.previewedAttachment?.id, doc.id)
        XCTAssertEqual(m.previewText(doc), "# Заголовок\nтекст\n", "the stored copy, read as is")
        XCTAssertEqual(m.currentRef, before.0, "the answer stays")
        XCTAssertEqual(m.attachments(for: ref).map(\.isSelected), before.1, "the choice of files stays")
        m.goBack()
        XCTAssertEqual(m.route, .home)
        let image = try XCTUnwrap(m.attachments(for: ref).first { $0.effectiveKind == .image })
        XCTAssertNil(m.previewText(image), "an image is not read as text")
        m.openAttachmentPreview(image)
        try importReport(m, "Другой")
        XCTAssertNil(m.previewedAttachment, "another answer's preview never shows this file")
    }

    /// PROMPT_RELAY_VISUALS=<dir>: Warm Cocoa renders (real SwiftUI).
    func testWriteWarmCocoaVisuals() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PROMPT_RELAY_VISUALS"] else { throw XCTSkip("set PROMPT_RELAY_VISUALS") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let m = await makeModel()
        let ref = try importReport(m, ReportFixture.report(sections: 6), task: "Сделай подробный отчёт о проделанной работе по островку",
                                   files: [("PHASE6.md", Data("# Phase 6\n\nНовая тема Warm Cocoa.\n".utf8)), ("island.png", Phase6Tests.png(seed: 2))])
        var island = IslandHost(model: m, surface: .peek)
        try island.png("\(dir)/warm-peek.png"); island.close()
        island = IslandHost(model: m, maxContentHeight: 341)
        try island.png("\(dir)/warm-details-14in.png"); island.close()
        island = IslandHost(model: m, maxContentHeight: 448)
        try island.png("\(dir)/warm-details.png"); island.close()
        await m.openPackPreview()
        island = IslandHost(model: m, maxContentHeight: 341)
        try island.png("\(dir)/warm-package-preview.png"); island.close()
        m.route = .home
        m.openAttachmentPreview(try XCTUnwrap(m.attachments(for: ref).first { $0.originalFilename == "PHASE6.md" }))
        island = IslandHost(model: m, maxContentHeight: 341)
        try island.png("\(dir)/warm-attachment-text.png"); island.close()
        m.route = .home
        m.openAttachmentPreview(try XCTUnwrap(m.attachments(for: ref).first { $0.effectiveKind == .image }))
        island = IslandHost(model: m, maxContentHeight: 341)
        try island.png("\(dir)/warm-attachment-image.png"); island.close()
    }
}
