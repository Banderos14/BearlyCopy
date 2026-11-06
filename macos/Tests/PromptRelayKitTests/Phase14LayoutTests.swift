import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// Phase 14, P0: no half-visible rows or text lines in Details. The owner's
/// screenshot showed the Copy with Context card with "Request & answer"
/// whole and "Commands" cut by the card's bottom edge, and the Answer with
/// its last line half visible. Both sit in a `BoundedScroll` whose height
/// was any value between its minimum and its content.
@MainActor
final class Phase14LayoutTests: XCTestCase {
    var suite: String!
    var defaults: MemorySettingsStore!
    var board: NSPasteboard!
    var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        suite = "PromptRelayTests.p14layout.\(UUID().uuidString)"
        defaults = TestDefaults.named(suite)
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP14-\(UUID().uuidString)"))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-p14-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        removeTestDefaults(suite)
        try? FileManager.default.removeItem(at: root)
    }

    func model(report: String, task: String = "Сделай подробный отчёт о проделанной работе по островку и маскоту") async -> AppModel {
        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-29T16:13:51.000000Z")])
        core.sessionsByProject["/a"] = [sessionSummary("sa", project: "/a", last: "2026-10-29T16:13:51.000000Z")]
        core.turnsBySession["sa"] = [turn(1, preview: "Ответ", chars: 5, request: "Задача")]
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults,
                         reportStore: ReportStore(root: root))
        await m.refreshNow()
        _ = m.importReport(text: report, task: task, projectPath: "/a", sessionLabel: nil)
        return m
    }

    /// Plain paragraphs only, so the true line pitch is known.
    static let paragraphs = (1...14).map { i in
        "Paragraph \(i): the island keeps every line either fully visible or out of view, and the copy always takes the whole text without any change at all, character for character."
    }.joined(separator: "\n\n")

    /// The line box of 13 pt body text with the reader's 2.5 pt spacing, measured.
    func measuredLine() -> (height: CGFloat, pitch: CGFloat) {
        func h(_ s: String) -> CGFloat {
            NSHostingView(rootView: Text(s).font(.system(size: 13)).lineSpacing(2.5).fixedSize()).fittingSize.height
        }
        let one = h("Ag"), two = h("Ag\nAg")
        return (one, two - one)
    }

    func testCopyWithContextRowsAreWholeOrHidden() async throws {
        let m = await model(report: ReportFixture.report(sections: 12))
        var checked = 0
        for maxContent: CGFloat in [268, 300, 330, 341, 388, 448, 568] {
            let island = IslandHost(model: m, maxContentHeight: maxContent)
            defer { island.close() }
            if DetailsLayout(presentation: island.presentation).twoColumns == false { continue }
            let f = island.presentation.layoutFrames
            let viewport = try XCTUnwrap(f["handoff.viewport"], "rows laid out at \(maxContent)")
            let rows = f.filter { $0.key.hasPrefix("handoff.row.") }
            XCTAssertGreaterThanOrEqual(rows.count, 3)
            for (id, r) in rows {
                let inside = r.minY >= viewport.minY - 0.5 && r.maxY <= viewport.maxY + 0.5
                let outside = r.minY >= viewport.maxY - 0.5
                XCTAssertTrue(inside || outside, "\(id) \(r) is cut by the card (viewport \(viewport), max \(maxContent))")
                checked += 1
            }
            XCTAssertTrue(rows.contains { $0.value.maxY <= viewport.maxY + 0.5 }, "at least one row is visible")
            // Hidden rows are announced, never half drawn.
            let visible = rows.filter { $0.value.maxY <= viewport.maxY + 0.5 }.count
            XCTAssertEqual(HandoffContentsCard.hiddenRows(count: rows.count, visibleHeight: viewport.height, explained: false),
                           rows.count - visible)
            if let png = ProcessInfo.processInfo.environment["PR_P14_PNG"] { try island.png("\(png)/details-\(Int(maxContent)).png") }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testAnswerNeverEndsInAHalfLine() async throws {
        let m = await model(report: Self.paragraphs)
        let line = measuredLine()
        var checked = 0
        for maxContent: CGFloat in [300, 330, 341, 360, 388, 410, 448, 500] {
            let island = IslandHost(model: m, maxContentHeight: maxContent)
            defer { island.close() }
            let f = island.presentation.layoutFrames
            guard let viewport = f["response.viewport"] else { continue }
            let cut = viewport.maxY
            for (id, block) in f where id.hasPrefix("response.block.") && block.minY < cut - 0.5 && block.maxY > cut + 0.5 {
                // A line k spans [top + k·pitch, top + k·pitch + height].
                var k: CGFloat = 0
                while block.minY + k * line.pitch < block.maxY {
                    let top = block.minY + k * line.pitch, bottom = top + line.height
                    XCTAssertFalse(cut > top + 1.5 && cut < bottom - 1.5,
                                   "\(id): the Answer ends inside a line (\(top)…\(bottom), cut \(cut), max \(maxContent))")
                    k += 1
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "some size cuts through a paragraph")
    }

    func testAttachmentRowsAreWholeOrHidden() async throws {
        let m = await model(report: ReportFixture.report(sections: 12))
        let dir = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls = try (1...6).map { i -> URL in
            let url = dir.appendingPathComponent("shot-\(i).png")
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            try rep.representation(using: .png, properties: [:])!.write(to: url)
            return url
        }
        m.addAttachments(urls, to: try XCTUnwrap(m.currentRef))
        for maxContent: CGFloat in [341, 388, 448] {
            let island = IslandHost(model: m, maxContentHeight: maxContent)
            defer { island.close() }
            let f = island.presentation.layoutFrames
            guard let card = f["card.attachments"] else { continue }
            let rows = f.filter { $0.key.hasPrefix("attachment.row.") }
            XCTAssertFalse(rows.isEmpty)
            // The viewport ends at the card's padding at most.
            let bottom = card.maxY - Island.cardPadding.bottom
            for (id, r) in rows where r.minY < bottom - 0.5 {
                XCTAssertLessThanOrEqual(r.maxY, bottom + 0.5, "\(id) \(r) is cut by the Attachments card (\(maxContent))")
            }
        }
    }
}
