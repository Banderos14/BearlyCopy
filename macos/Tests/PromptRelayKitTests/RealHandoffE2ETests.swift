import AppKit
import CryptoKit
import XCTest
@testable import PromptRelayKit

/// Opt-in end-to-end check of the Phase 5.11 hand-off against a REAL captured
/// turn (read-only history): PROMPT_RELAY_E2E_SESSION=<session key>,
/// PROMPT_RELAY_E2E_TURN=<n>, PROMPT_RELAY_E2E_FILES=<comma-separated file
/// names the turn produced>, optional PROMPT_RELAY_E2E_FAILED_EXIT=<code>,
/// PROMPT_RELAY_E2E_RENDER=<dir>. Attachments go to a temporary store and
/// the clipboard is a private pasteboard: the user's data is not changed.
@MainActor
final class RealHandoffE2ETests: XCTestCase {
    func testRealTurnSuggestionsCopyAndFileHandoff() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["PROMPT_RELAY_E2E_SESSION"], let turnIndex = env["PROMPT_RELAY_E2E_TURN"].flatMap(Int.init),
              let files = env["PROMPT_RELAY_E2E_FILES"]?.split(separator: ",").map(String.init) else {
            throw XCTSkip("set PROMPT_RELAY_E2E_SESSION, _TURN and _FILES to check a real hand-off")
        }
        var processEnv = env
        processEnv["PROMPT_RELAY_CLI"] = env["PROMPT_RELAY_CLI"] ?? Repo.cli
        let locator = CoreLocator(processEnvironment: processEnv, bundleResourceURL: nil, defaults: { _ in nil })
        let board = NSPasteboard(name: NSPasteboard.Name("PromptRelayE2E-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pr-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = AppModel(core: CoreClient.live(locator: locator), clipboard: ClipboardService(pasteboard: board),
                             dataDirectory: nil, reportStore: ReportStore(root: scratch.appendingPathComponent("app")))
        await model.refreshNow()
        let ref = ReportRef.local(sessionKey: key, turn: turnIndex)
        model.open(ref)
        let deadline = Date().addingTimeInterval(20)
        while (model.selectedResponseText == nil || model.suggestions.isEmpty), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let answer = try XCTUnwrap(model.selectedResponseText)
        let turn = try XCTUnwrap(model.selectedTurn)
        XCTAssertGreaterThan(turn.observed?.toolEvents ?? 0, 0, "tool events were captured for this turn")
        if let code = env["PROMPT_RELAY_E2E_FAILED_EXIT"].flatMap(Int.init) {
            XCTAssertTrue(model.detail.value?.turn.observedDetail?.commands.contains { $0.exitCode == code } ?? false,
                          "the failing command's exit code \(code) was captured")
        }

        // Suggestions: each produced file, with where it came from.
        let suggestions = model.suggestions
        for name in files {
            XCTAssertTrue(suggestions.contains { $0.title == name && $0.exists }, "\(name) is suggested: \(suggestions.map(\.title))")
        }
        print("E2E suggestions:", suggestions.map { "\($0.title) — \($0.reason)" })
        model.acceptAll(suggestions)
        let attached = model.attachments(for: ref)
        XCTAssertEqual(Set(attached.map(\.originalFilename)).isSuperset(of: files), true)

        // Copy Response: only the answer.
        await model.copySelectedResponse()
        XCTAssertEqual(board.string(forType: .string), answer, "Copy Response is the answer, byte for byte")

        // Copy for ChatGPT: the answer once, the files listed by name.
        await model.copySelectedContext()
        let pack = try XCTUnwrap(board.string(forType: .string))
        XCTAssertEqual(pack.components(separatedBy: answer).count - 1, 1, "the answer appears exactly once")
        XCTAssertEqual(ReviewPackReader.response(in: pack), answer)
        for name in files { XCTAssertTrue(pack.contains(name), "\(name) is listed in the pack") }
        XCTAssertTrue(pack.contains("part of this review only if they are attached"), "the pack does not claim the files were sent")
        if let code = env["PROMPT_RELAY_E2E_FAILED_EXIT"] { XCTAssertTrue(pack.contains("exit \(code)")) }

        // Step 2: the files on the clipboard, identical to the originals.
        XCTAssertEqual(model.handoffStep?.fileCount, attached.count)
        model.copyHandoffFiles()
        let urls = try XCTUnwrap(board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
        XCTAssertEqual(urls.count, attached.count)
        let root = try XCTUnwrap(model.detail.value?.session.project.path)
        func digest(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
        let originals = try Set(attached.compactMap(\.originalPath).map { try digest(URL(fileURLWithPath: $0.hasPrefix("/") ? $0 : root + "/" + $0)) })
        XCTAssertEqual(originals.count, attached.count, "every attachment knows its original file")
        XCTAssertEqual(try Set(urls.map(digest)), originals, "the files on the clipboard are byte-identical to the originals")
        print("E2E handed over:", urls.map(\.lastPathComponent))
        if let dir = env["PROMPT_RELAY_E2E_RENDER"] {
            try Data(pack.utf8).write(to: URL(fileURLWithPath: "\(dir)/e2e-pack.md"))
            try AuditRender.island(model, route: .home, to: "\(dir)/e2e-details.png")
            try AuditRender.island(model, route: .activity, to: "\(dir)/e2e-activity.png")
        }
    }
}
