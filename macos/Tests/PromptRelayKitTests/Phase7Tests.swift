import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// Phase 7: tooltips inside the visible island, Clipboard image hit-testing,
/// View Full Task, Markdown Source, Standard / Full context, Evidence Check,
/// Artifact Completeness, Review Checklist, Import AI Result, Export Bundle.
@MainActor
final class Phase7Tests: XCTestCase {
    var suite: String!
    var defaults: UserDefaults!
    var board: NSPasteboard!
    var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        suite = "PromptRelayTests.p7.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP7-\(UUID().uuidString)"))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-p7-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
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

    // MARK: Tooltips

    /// The placement keeps a tip of any size inside the black part of the
    /// island: below the band, inside the flared sides, clear of the rounded
    /// bottom corners, and never over its own control.
    func testTipPlacementStaysInsideTheVisibleIslandForEveryAnchor() {
        let island = CGSize(width: 520, height: 300), band: CGFloat = 32
        let safe = TipPlacement.safeArea(island: island, band: band)
        for tip in [CGSize(width: 60, height: 16), CGSize(width: 220, height: 44), CGSize(width: 600, height: 400)] {
            for x in stride(from: 0, through: island.width, by: 20) {
                for y in stride(from: band, through: island.height - 20, by: 12) {
                    let anchor = CGRect(x: x, y: y, width: 26, height: 20)
                    let f = TipPlacement.frame(anchor: anchor, tip: tip, island: island, band: band)
                    XCTAssertTrue(safe.insetBy(dx: -0.5, dy: -0.5).contains(f), "\(f) outside \(safe), anchor \(anchor)")
                    if f.maxY > island.height - TipPlacement.bottomRadius {
                        XCTAssertGreaterThanOrEqual(f.minX, TipPlacement.bottomRadius - 0.5, "clear of the bottom-left corner")
                        XCTAssertLessThanOrEqual(f.maxX, island.width - TipPlacement.bottomRadius + 0.5, "clear of the bottom-right corner")
                    }
                    let fitsBelow = anchor.maxY + 4 + tip.height <= safe.maxY
                    let fitsAbove = anchor.minY - 4 - tip.height >= safe.minY
                    if fitsBelow || fitsAbove {
                        XCTAssertFalse(f.intersects(anchor.insetBy(dx: 1, dy: 1)), "never over its own control \(anchor)")
                    }
                }
            }
        }
    }

    /// Every control with a tip, on every surface, in the real view tree:
    /// the drawn tip (its measured frame) stays inside the visible island.
    func testEveryRealTooltipIsDrawnInsideTheIsland() async throws {
        let m = await makeModel()
        try importReport(m, ReportFixture.report(sections: 6), files: [("a.md", Data("# A\n".utf8)), ("b.png", Phase6Tests.png(seed: 2))])
        var checked = 0
        for surface in [NotchPresentation.Surface.peek, .expanded] {
            for maxContent: CGFloat in [268, 448] {
                let routes: [AppModel.IslandRoute] = surface == .peek ? [.home] : [.home, .history, .clipboard, .settings, .reader, .packagePreview]
                for route in routes {
                    m.route = route
                    let tips = IslandTooltips()
                    let host = IslandHost(model: m, surface: surface, maxContentHeight: maxContent, tips: tips)
                    defer { host.close() }
                    let island = CGSize(width: host.width, height: host.height)
                    let safe = TipPlacement.safeArea(island: island, band: 32)
                    let controls = tips.controls.filter { safe.intersects($0.value.anchor) }
                    if [.home, .history, .clipboard].contains(route) { XCTAssertFalse(controls.isEmpty, "\(surface) \(route): controls with tips") }
                    for (owner, control) in controls {
                        tips.show(owner, text: control.text, anchor: control.anchor)
                        host.settle()
                        let f = try XCTUnwrap(host.presentation.layoutFrames["tooltip"], "\(route) \(control.text)")
                        XCTAssertTrue(safe.insetBy(dx: -1, dy: -1).contains(f),
                                      "\(surface) \(route) \(maxContent): “\(control.text)” at \(f), island \(island)")
                        checked += 1
                    }
                    tips.hideAll()
                }
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 30, "the check covered the real controls")
    }

    func testNoAppKitTooltipsInTheSources() throws {
        // `.help` opens AppKit's own tooltip window, which can cover other
        // apps beside the island (the probe in docs/PHASE7.md shows it).
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources").standardized
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains(".help("), "\(file.lastPathComponent) uses .help")
            XCTAssertFalse(text.contains("toolTip ="), "\(file.lastPathComponent) sets an AppKit toolTip")
        }
    }
}

// MARK: - Clipboard image hit-testing

@MainActor
final class Phase7ClipboardHitTests: XCTestCase {
    /// A wide screenshot, so `.fill` overflows its 96 × 64 thumbnail.
    static func wide(_ color: NSColor) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 160, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill(); NSRect(x: 0, y: 0, width: 800, height: 160).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// Five wide screenshots: the thumbnails sit side by side, none over
    /// another, each with its own frame.
    func testFiveWideThumbnailsDoNotOverlap() async throws {
        _ = NSApplication.shared
        let suite = "PromptRelayTests.p7c.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP7c-\(UUID().uuidString)"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pr-p7c-\(UUID().uuidString)")
        defer { board.releaseGlobally(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let history = ClipboardImageHistory(folder: folder, pasteboard: board)
        history.setEnabled(true)
        defer { history.setEnabled(false) }
        for color in [NSColor.red, .green, .blue, .yellow, .purple] {
            board.clearContents(); board.setData(Self.wide(color), forType: .png); history.poll()
        }
        XCTAssertEqual(history.items.count, 5)
        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-31T10:00:00.000000Z")])
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults)
        await m.refreshNow()
        m.clipboardImages = history
        m.route = .clipboard
        m.clipboardTab = .images
        let host = IslandHost(model: m)
        defer { host.close() }
        let frames = try history.items.map { try XCTUnwrap(host.presentation.layoutFrames["clipboard.thumb.\($0.id)"]) }
        for (i, a) in frames.enumerated() {
            XCTAssertEqual(a.size, CGSize(width: 96, height: 64), "the hit area is the visible thumbnail")
            for b in frames[(i + 1)...] { XCTAssertFalse(a.intersects(b), "thumbnails \(a) and \(b) overlap") }
        }
    }

    /// `.clipped()` does not limit hit-testing: every `.fill` image must
    /// also get a content shape, or its overflow takes the neighbour's clicks
    /// (proved with `scripts/probes/thumbnail-hit.swift`).
    func testEveryFillImageHasAContentShape() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources").standardized
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var sites = 0
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("contentMode: .fill") {
                sites += 1
                let after = lines[i..<min(lines.count, i + 18)].joined(separator: "\n")
                XCTAssertTrue(after.contains(".contentShape("), "\(file.lastPathComponent):\(i + 1) has no content shape")
            }
        }
        XCTAssertEqual(sites, 3)
    }
}
