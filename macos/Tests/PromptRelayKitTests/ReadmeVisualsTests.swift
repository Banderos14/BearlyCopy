import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// PROMPT_RELAY_README_SHOTS=<dir>: the README screenshots — a local Claude
/// Code session with English synthetic content (real SwiftUI renders).
@MainActor
extension Phase6VisualTests {
    static let readmeAnswer = """
    ## Dark mode is in

    I added a **dark-mode toggle** to the settings page and wired it to the saved preferences.

    ### What changed
    - `SettingsPage.tsx`: new `ThemeToggle` (system / light / dark)
    - `useTheme.ts`: reads and writes the choice, follows the OS by default
    - `settings.test.tsx`: 6 new tests for the toggle

    ### Result
    All 42 tests pass (`npm test`). I also wrote a short note for the release: `release-notes.md`.
    """

    /// A believable settings-page picture for the attachment (no green square).
    static func settingsMockPNG() -> Data {
        let size = NSSize(width: 960, height: 600)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 1),
                                NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.22, alpha: 1)])!.draw(in: rect, angle: -90)
            func card(_ r: NSRect, _ fill: NSColor) { fill.setFill(); NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14).fill() }
            card(NSRect(x: 60, y: 120, width: 840, height: 400), NSColor(white: 1, alpha: 0.07))
            let title = NSAttributedString(string: "Settings", attributes: [.font: NSFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: NSColor.white])
            title.draw(at: NSPoint(x: 90, y: 456))
            let rows = ["Appearance", "Dark mode", "Notifications", "Language"]
            for (i, row) in rows.enumerated() {
                let y = CGFloat(400 - i * 78)
                NSAttributedString(string: row, attributes: [.font: NSFont.systemFont(ofSize: 22, weight: row == "Dark mode" ? .semibold : .medium),
                                                              .foregroundColor: NSColor(white: row == "Dark mode" ? 1 : 0.9, alpha: 1)])
                    .draw(at: NSPoint(x: 100, y: y))
                card(NSRect(x: 100, y: y - 20, width: 760, height: 1), NSColor(white: 1, alpha: 0.12))
                if row == "Dark mode" {
                    card(NSRect(x: 760, y: y - 8, width: 100, height: 48), NSColor(calibratedRed: 0.85, green: 0.65, blue: 0.42, alpha: 1))
                    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 812, y: y - 2, width: 36, height: 36)).fill()
                }
            }
            return true
        }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    func testWriteReadmeVisuals() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PROMPT_RELAY_README_SHOTS"] else { throw XCTSkip("set PROMPT_RELAY_README_SHOTS") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let nowDate = Date()
        let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let at = fmt.string(from: nowDate.addingTimeInterval(-90))
        let projectPath = "/Users/dev/acme-web"
        let core = FakeCore(projects: [project(projectPath, sessions: 1, last: at)])
        let session = Phase93Tests.session("a1b2c3d4", provider: "claude_code", host: "claude_desktop", project: projectPath,
                                           last: at, turns: 1)
        core.sessionsByProject[projectPath] = [session]
        let request = "Add a dark-mode toggle to the settings page and make sure all tests pass."
        let answer = Self.readmeAnswer
        core.turnsBySession["a1b2c3d4"] = [turn(1, preview: "Dark mode is in", chars: answer.count, text: answer, request: request, at: at, completion: "answer")]
        core.showResult = { [core] key, i in
            .success(CoreResult(data: ShowData(session: try! core.session(key), turn: turn(i, preview: "Dark mode is in", chars: answer.count,
                                                                                         text: answer, request: request, at: at, completion: "answer")), warnings: []))
        }
        let package = """
        # Copy with Context: Claude Code result for review
        Exported by Prompt Relay. No AI service was used.

        Provenance labels: [Confirmed locally] = recorded on this Mac by Prompt Relay; [Reported by Claude] = Claude's own words, not checked; [Not verified] = no independent source.

        ## Session
        - Agent: Claude Code · Claude Desktop [Confirmed locally]
        - Project: acme-web [Confirmed locally]

        ## Request
        Add a dark-mode toggle to the settings page and make sure all tests pass. [Confirmed locally]

        ## Claude's final answer (verbatim)
        Dark mode is in. All 42 tests pass (`npm test`). [Reported by Claude]

        ## Observed on this Mac
        - Command `npm test` finished with exit code 0 [Confirmed locally]
        - Files changed: SettingsPage.tsx, useTheme.ts [Confirmed locally]
        """
        core.contextResult = .success(CoreResult(data: ContextData(session: session, turn: turn(1, text: answer, request: request, at: at), exportedAt: at, text: package,
                                                                   sensitiveFindings: [],
                                                                   git: GitSummary(available: false, reason: "fixture", branch: nil, head: nil,
                                                                                   changedFileCount: 0, changedFilesTruncated: false)), warnings: []))
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults,
                         reportStore: ReportStore(root: root))
        await m.refreshNow()
        let ref = ReportRef.local(sessionKey: "a1b2c3d4", turn: 1)
        let dirURL0 = root.appendingPathComponent("src-readme")
        try FileManager.default.createDirectory(at: dirURL0, withIntermediateDirectories: true)
        var island = IslandHost(model: m, surface: .peek)
        try island.png2x("\(dir)/peek.png"); island.close()
        m.open(ref)
        let dirURL = root.appendingPathComponent("src-readme")
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let notes = dirURL.appendingPathComponent("release-notes.md")
        try Data("# Release notes\n\n- Dark mode toggle in Settings (system / light / dark)\n- 6 new tests\n".utf8).write(to: notes)
        let shot = dirURL.appendingPathComponent("settings-dark-mode.png")
        try Self.settingsMockPNG().write(to: shot)
        let store = try XCTUnwrap(m.reportStore)
        _ = try store.addFile(from: notes, to: ref, source: .agentResult, displayPath: "release-notes.md")
        _ = try store.addFile(from: shot, to: ref, source: .agentResult, displayPath: "settings-dark-mode.png")
        m.attachmentsVersion += 1
        island = IslandHost(model: m, surface: .peek)
        try island.png2x("\(dir)/peek-seen.png"); island.close()
        island = IslandHost(model: m, maxContentHeight: 448)
        try island.png2x("\(dir)/details.png"); island.close()
        await m.openPackPreview()
        island = IslandHost(model: m, maxContentHeight: 341)
        try island.png2x("\(dir)/context-preview.png"); island.close()
        m.route = .home
        m.openAttachmentPreview(try XCTUnwrap(m.attachments(for: ref).first { $0.effectiveKind == .image }))
        island = IslandHost(model: m, maxContentHeight: 341)
        try island.png2x("\(dir)/attachment.png"); island.close()
    }
}
