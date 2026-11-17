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

    /// A believable app screenshot for the attachment: a settings page with a sidebar and
    /// Dark mode switched on (drawn, so the README images never contain real data).
    static func settingsMockPNG() -> Data {
        let size = NSSize(width: 1200, height: 760)
        let accent = NSColor(calibratedRed: 0.36, green: 0.52, blue: 0.98, alpha: 1)
        let image = NSImage(size: size, flipped: false) { rect in
            func fill(_ r: NSRect, _ c: NSColor, _ radius: CGFloat = 0) { c.setFill(); NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill() }
            func text(_ t: String, _ p: NSPoint, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ c: NSColor = .white) {
                NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: c]).draw(at: p)
            }
            fill(rect, NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.11, alpha: 1))
            // window bar
            fill(NSRect(x: 0, y: 712, width: 1200, height: 48), NSColor(white: 1, alpha: 0.05))
            for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() { fill(NSRect(x: 22 + CGFloat(i) * 26, y: 726, width: 16, height: 16), c, 8) }
            text("Acme Web — Settings", NSPoint(x: 500, y: 722), 18, .medium, NSColor(white: 1, alpha: 0.6))
            // sidebar
            fill(NSRect(x: 0, y: 0, width: 260, height: 712), NSColor(white: 1, alpha: 0.035))
            for (i, item) in ["Profile", "Appearance", "Notifications", "Security", "Billing"].enumerated() {
                let y = CGFloat(630 - i * 62)
                if item == "Appearance" { fill(NSRect(x: 16, y: y - 12, width: 228, height: 48), accent.withAlphaComponent(0.22), 12) }
                fill(NSRect(x: 36, y: y + 2, width: 20, height: 20), item == "Appearance" ? accent : NSColor(white: 1, alpha: 0.25), 6)
                text(item, NSPoint(x: 72, y: y), 21, item == "Appearance" ? .semibold : .regular, item == "Appearance" ? .white : NSColor(white: 1, alpha: 0.7))
            }
            // content
            text("Appearance", NSPoint(x: 310, y: 640), 38, .bold)
            text("Choose how Acme looks on this device.", NSPoint(x: 310, y: 604), 20, .regular, NSColor(white: 1, alpha: 0.55))
            func row(_ y: CGFloat, _ title: String, _ sub: String, on: Bool) {
                fill(NSRect(x: 310, y: y, width: 840, height: 92), NSColor(white: 1, alpha: 0.06), 16)
                text(title, NSPoint(x: 340, y: y + 50), 24, .semibold)
                text(sub, NSPoint(x: 340, y: y + 20), 18, .regular, NSColor(white: 1, alpha: 0.55))
                fill(NSRect(x: 1048, y: y + 28, width: 76, height: 40), on ? accent : NSColor(white: 1, alpha: 0.2), 20)
                fill(NSRect(x: on ? 1088 : 1052, y: y + 32, width: 32, height: 32), .white, 16)
            }
            row(470, "Dark mode", "Use a dark color scheme across the app", on: true)
            row(360, "Follow system", "Switch automatically with macOS", on: false)
            row(250, "Reduce motion", "Fewer animations", on: false)
            // theme preview cards
            for (i, (name, dark)) in [("Light", false), ("Dark", true)].enumerated() {
                let x = CGFloat(310 + i * 230)
                fill(NSRect(x: x, y: 48, width: 210, height: 160), dark ? NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.18, alpha: 1) : NSColor(white: 0.95, alpha: 1), 16)
                fill(NSRect(x: x + 16, y: 150, width: 90, height: 12), dark ? NSColor(white: 1, alpha: 0.5) : NSColor(white: 0.2, alpha: 0.5), 6)
                fill(NSRect(x: x + 16, y: 120, width: 140, height: 10), dark ? NSColor(white: 1, alpha: 0.25) : NSColor(white: 0.2, alpha: 0.25), 5)
                fill(NSRect(x: x + 16, y: 28 + 60, width: 60, height: 26), accent, 8)
                text(name, NSPoint(x: x + 16, y: 60), 18, .medium, dark ? .white : NSColor(white: 0.2, alpha: 1))
                if dark { NSColor.white.withAlphaComponent(0.9).setStroke(); let b = NSBezierPath(roundedRect: NSRect(x: x, y: 48, width: 210, height: 160), xRadius: 16, yRadius: 16); b.lineWidth = 3; accent.setStroke(); b.stroke() }
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
        Exported by BearlyCopy. No AI service was used.

        Provenance labels: [Confirmed locally] = recorded on this Mac by BearlyCopy; [Reported by Claude] = Claude's own words, not checked; [Not verified] = no independent source.

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
