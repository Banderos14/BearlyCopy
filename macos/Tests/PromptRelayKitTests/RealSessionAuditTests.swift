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
        XCTAssertEqual(pack.components(separatedBy: shown).count - 1, 1, "Review Pack: the full report exactly once")
        XCTAssertTrue(pack.contains("- Source: Claude Code on this Mac"))
        XCTAssertTrue(Data(pack.utf8).range(of: expected) != nil, "Review Pack contains the expected bytes")

        // The formatted reader drops no line of the report.
        let missing = MarkdownCoverage.missingLines(shown)
        XCTAssertTrue(missing.isEmpty, "lines not shown in Formatted: \(missing.prefix(5))")

        if let dir = env["PROMPT_RELAY_AUDIT_RENDER"] {
            try AuditRender.island(model, route: .home, to: "\(dir)/real-home.png")
            try AuditRender.island(model, route: .reader, to: "\(dir)/real-reader.png")
            try AuditRender.island(model, route: .copies, to: "\(dir)/real-copies.png")
            try AuditRender.island(model, route: .settings, to: "\(dir)/real-settings-full.png", unbounded: true)
        }
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
        let settings = NotchSettings(defaults: UserDefaults(suiteName: "PromptRelayAudit-\(UUID().uuidString)")!)
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
