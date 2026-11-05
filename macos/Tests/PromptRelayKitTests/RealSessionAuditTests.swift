import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// Opt-in audit against the user's REAL captured history (read-only):
/// PROMPT_RELAY_AUDIT_SESSION=<session key>, PROMPT_RELAY_AUDIT_TURN=<n>,
/// PROMPT_RELAY_AUDIT_EXPECTED=<file with the expected bytes, e.g. the text
/// from the Claude Code transcript>, optional PROMPT_RELAY_AUDIT_RENDER=<dir>.
/// Uses a private pasteboard and no persisted state; nothing is written to
/// the history. Skipped unless the variables are set.
@MainActor
final class RealSessionAuditTests: XCTestCase {
    func testRealCapturedReportSurvivesCopyReviewPackAndReader() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["PROMPT_RELAY_AUDIT_SESSION"], let turnText = env["PROMPT_RELAY_AUDIT_TURN"], let turnIndex = Int(turnText),
              let expectedPath = env["PROMPT_RELAY_AUDIT_EXPECTED"] else {
            throw XCTSkip("set PROMPT_RELAY_AUDIT_SESSION, _TURN and _EXPECTED to audit a real captured report")
        }
        let expected = try Data(contentsOf: URL(fileURLWithPath: expectedPath))
        var processEnv = env
        processEnv["PROMPT_RELAY_CLI"] = env["PROMPT_RELAY_CLI"] ?? Repo.cli
        let locator = CoreLocator(processEnvironment: processEnv, bundleResourceURL: nil, defaults: { _ in nil })
        let board = NSPasteboard(name: NSPasteboard.Name("PromptRelayAudit-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let model = AppModel(core: CoreClient.live(locator: locator), clipboard: ClipboardService(pasteboard: board),
                             dataDirectory: nil)
        model.tracksReadyAnswers = true
        await model.refreshNow()
        if env["PROMPT_RELAY_AUDIT_EXPECT_LATEST"] == "1" {
            XCTAssertEqual(model.readyAnswer?.sessionKey, key, "the newest finished answer is this session's")
            XCTAssertEqual(model.readyAnswer?.turnIndex, turnIndex)
        }
        model.open(.local(sessionKey: key, turn: turnIndex))
        let deadline = Date().addingTimeInterval(20)
        while model.selectedResponseText == nil, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        let shown = try XCTUnwrap(model.selectedResponseText, "the full text was loaded for the reader")
        XCTAssertEqual(Data(shown.utf8), expected, "Full Report text == expected bytes")

        await model.copySelectedResponse()
        let copied = try XCTUnwrap(board.data(forType: .string))
        XCTAssertEqual(copied, expected, "Copy Response: byte-identical")

        await model.copySelectedContext()
        let pack = try XCTUnwrap(board.string(forType: .string))
        // The pack is the response plus metadata; what must equal the
        // transcript is the response read back out of it, not the whole pack.
        let packed = try XCTUnwrap(ReviewPackReader.response(in: pack), "Review Pack: one response section")
        XCTAssertEqual(Data(packed.utf8), expected, "Review Pack: the response extracted from it is byte-identical")
        XCTAssertEqual(pack.components(separatedBy: shown).count - 1, 1, "Review Pack: the report appears exactly once")
        XCTAssertTrue(pack.contains("- Source: Claude Code on this Mac"))
        if let dir = env["PROMPT_RELAY_AUDIT_RENDER"] {
            try Data(pack.utf8).write(to: URL(fileURLWithPath: "\(dir)/real-review-pack.md"))
        }

        // The formatted reader drops no line of the report.
        let missing = MarkdownCoverage.missingLines(shown)
        XCTAssertTrue(missing.isEmpty, "lines not shown in Formatted: \(missing.prefix(5))")

        if let dir = env["PROMPT_RELAY_AUDIT_RENDER"] {
            try AuditRender.island(model, route: .home, to: "\(dir)/real-home.png")
            try AuditRender.island(model, route: .reader, to: "\(dir)/real-reader.png")
            try AuditRender.island(model, route: .copies, to: "\(dir)/real-copies.png")
            try AuditRender.island(model, route: .history, to: "\(dir)/real-history.png")
            try AuditRender.island(model, route: .projects, to: "\(dir)/real-projects.png")
            try AuditRender.island(model, route: .importReport, to: "\(dir)/real-import.png")
            try AuditRender.island(model, route: .settings, to: "\(dir)/real-settings-full.png", unbounded: true)

            // The same real answer with three images, kept in a temporary
            // store: the user's own attachments are neither read nor changed.
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pr-audit-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            let withImages = AppModel(core: CoreClient.live(locator: locator), clipboard: ClipboardService(pasteboard: board),
                                      dataDirectory: nil, reportStore: ReportStore(root: scratch.appendingPathComponent("app")))
            await withImages.refreshNow()
            withImages.open(.local(sessionKey: key, turn: turnIndex))
            while withImages.selectedResponseText == nil, Date() < deadline.addingTimeInterval(20) { try await Task.sleep(nanoseconds: 50_000_000) }
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let images = try ["Снимок экрана 2026-10-30 в 10.12.04.png", "island-before.png", "chatgpt-paste.png"].enumerated().map { i, name -> URL in
                let drawing = NSImage(size: NSSize(width: 1440, height: 900), flipped: false) { rect in
                    [NSColor.systemTeal, .systemOrange, .systemPurple][i].setFill(); rect.fill(); return true
                }
                let url = scratch.appendingPathComponent(name)
                try NSBitmapImageRep(data: drawing.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: url)
                return url
            }
            withImages.addAttachments(images, to: .local(sessionKey: key, turn: turnIndex))
            XCTAssertEqual(withImages.attachments(for: withImages.currentRef).count, 3)
            try AuditRender.island(withImages, route: .home, to: "\(dir)/real-home-images.png")
            await withImages.copySelectedContext()
            let packWithImages = try XCTUnwrap(board.string(forType: .string))
            XCTAssertEqual(ReviewPackReader.response(in: packWithImages).map { Data($0.utf8) }, expected,
                           "with images listed, the response in the pack is still the original")
            XCTAssertTrue(packWithImages.contains("## Attachments (3, sent separately)"))
            try Data(packWithImages.utf8).write(to: URL(fileURLWithPath: "\(dir)/real-review-pack-images.md"))
        }
    }
}

/// Reads the response back out of a Review Pack: the fenced block under
/// "## Claude final response", skipping fenced blocks elsewhere (a task may
/// quote anything). Nil unless there is exactly one such section.
enum ReviewPackReader {
    static func response(in pack: String) -> String? {
        let lines = pack.components(separatedBy: "\n")
        var fence: String?
        var inSection = false, sections = 0
        var body: [String]?, result: String?
        for line in lines {
            if let open = fence {
                if line == open {
                    fence = nil
                    if let lines = body { result = result == nil ? lines.joined(separator: "\n") : result; body = nil; inSection = false }
                } else {
                    body?.append(line)
                }
                continue
            }
            if ["## Claude final response", "## Codex final response", "## AI final response"].contains(line) { sections += 1; inSection = true; continue }
            if line.hasPrefix("## ") { inSection = false }
            let run = line.prefix { $0 == "`" }
            if run.count >= 3 {
                fence = String(run)
                if inSection, line.dropFirst(run.count) == "markdown" { body = [] }
            }
        }
        return sections == 1 ? result : nil
    }
}

/// Which source lines a Formatted reader would not show. Fence lines and
/// Markdown markers are not content; everything else must appear in a block.
enum MarkdownCoverage {
    static func missingLines(_ source: String) -> [String] {
        let blocks = Markdown.parse(source)
        let shown = blocks.map { block -> String in
            switch block {
            case .heading(_, let t), .paragraph(let t), .quote(let t), .code(_, let t): return t
            case .listItem(_, _, let t): return t
            case .table(let rows): return rows.joined(separator: "\n")
            case .rule: return ""
            }
        }.joined(separator: "\n")
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        return lines.compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || Markdown.fenceMarker(line) != nil || ["---", "***", "___"].contains(line) { return nil }
            while line.hasPrefix("#") { line.removeFirst() }
            if line.hasPrefix(">") { line.removeFirst() }
            if case .listItem(_, _, let t)? = Markdown.listItem(raw) { line = t }
            line = line.trimmingCharacters(in: .whitespaces)
            return line.isEmpty || shown.contains(line) ? nil : raw
        }
    }
}

@MainActor
enum AuditRender {
    /// Renders a view of the island; `unbounded` lets scrolling views show
    /// all of their content, to check every row for clipping.
    static func island(_ model: AppModel, route: AppModel.IslandRoute, to path: String, unbounded: Bool = false) throws {
        model.route = .home
        if route != .home { model.navigate(to: route) }
        let p = NotchPresentation()
        p.notchSize = CGSize(width: 185, height: 32)
        p.islandWidth = NotchLayout.expandedWidth
        p.isExpanded = true
        p.surface = .expanded
        p.showsMascot = true
        p.maxContentHeight = unbounded ? 3000 : 568
        let settings = NotchSettings(defaults: TestDefaults.named("PromptRelayAudit-\(UUID().uuidString)")!)
        for _ in 0..<3 {
            let size = NSSize(width: NotchLayout.expandedWidth, height: 32 + p.contentHeight)
            let host = NSHostingView(rootView: NotchRootView(model: model, presentation: p,
                                                             interaction: NotchInteraction(scheduler: MainQueueScheduler()),
                                                             actions: SurfaceActions(quit: {}), settings: settings)
                .frame(width: size.width, height: size.height).background(Color(white: 0.86)))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            window.close()
        }
        model.route = .home
    }
}
