import XCTest
@testable import PromptRelayKit

/// The real Python CLI of this checkout against a temporary data dir: the
/// user's history is never read or written.
final class CoreIntegrationTests: XCTestCase {
    var home: URL!
    var project: URL!

    override func setUpWithError() throws {
        // Real path (/var is a symlink to /private/var; Foundation's
        // resolvingSymlinksInPath strips /private again). Claude Code reports real paths.
        let base = FileManager.default.temporaryDirectory.path.withCString { realpath($0, nil) }.map { String(cString: $0) }!
        let tmp = URL(fileURLWithPath: base).appendingPathComponent("pr-int-\(UUID().uuidString)")
        home = tmp.appendingPathComponent("data")
        project = tmp.appendingPathComponent("project-a")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func locator() -> CoreLocator {
        CoreLocator(processEnvironment: ["HOME": NSHomeDirectory(), "PROMPT_RELAY_HOME": home.path, "PROMPT_RELAY_CLI": Repo.cli],
                    bundleResourceURL: nil, defaults: { _ in nil })
    }

    func runCLI(_ args: [String], stdin: Data? = nil) throws {
        let location = try locator().locate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: location.python)
        p.arguments = ["-I", "-S", location.cli] + args
        p.environment = ["HOME": NSHomeDirectory(), "PROMPT_RELAY_HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        if let stdin { input.fileHandleForWriting.write(stdin) }
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, args.joined(separator: " "))
    }

    func hook(_ payload: [String: Any]) throws {
        try runCLI(["hook"], stdin: try JSONSerialization.data(withJSONObject: payload))
    }

    func testEmptyStoreThroughTheRealCore() async throws {
        let core = CoreClient.live(locator: locator())
        let projects = try await core.projects()
        XCTAssertEqual(projects.data.projects, [])
        let sessions = try await core.sessions(project: nil)
        XCTAssertEqual(sessions.data.sessions, [])
        do {
            _ = try await core.turns(sessionKey: "missing")
            XCTFail("expected not_found")
        } catch {
            XCTAssertEqual((error as? CoreError)?.apiCode, "not_found")
        }
    }

    func testCapturedAnswerRoundTripsExactly() async throws {
        let answer = "Привет 🚀\r\n```py\nprint(1)\n```\n\u{0}end  "
        try runCLI(["enable", project.path])
        try hook(["hook_event_name": "UserPromptSubmit", "session_id": "s-1", "prompt_id": "p-1", "cwd": project.path, "prompt": "say hi"])
        try hook(["hook_event_name": "Stop", "session_id": "s-1", "prompt_id": "p-1", "cwd": project.path, "last_assistant_message": answer])

        let core = CoreClient.live(locator: locator())
        let projects = try await core.projects()
        XCTAssertEqual(projects.data.projects.map(\.sessionCount), [1])
        let sessions = try await core.sessions(project: project.path)
        XCTAssertEqual(sessions.data.sessions.map(\.sessionKey), ["s-1"])
        let turns = try await core.turns(sessionKey: "s-1")
        XCTAssertEqual(turns.data.turns.first?.link, .promptID)
        let show = try await core.show(sessionKey: "s-1", turn: 1)
        XCTAssertEqual(show.data.turn.finalResponse?.text.map { Array($0.unicodeScalars) }, Array(answer.unicodeScalars))
        let context = try await core.context(sessionKey: "s-1", turn: 1)
        XCTAssertTrue(context.data.text.contains("print(1)"))
        // Phase 7: both detail levels from the real Core; the answer is whole in each.
        let standard = try await core.context(sessionKey: "s-1", turn: 1, detail: .standard)
        let full = try await core.context(sessionKey: "s-1", turn: 1, detail: .full)
        XCTAssertTrue(standard.data.text.contains("Detail: Standard"))
        XCTAssertFalse(full.data.text.contains("Detail: Standard"))
        for text in [standard.data.text, full.data.text] { XCTAssertTrue(text.contains("print(1)")) }
        let doctor = try await core.doctor()
        XCTAssertEqual(doctor.data.storage.dataDir, home.path)
        XCTAssertEqual(doctor.data.capture.enabledProjects.count, 1)
    }

    @MainActor
    func testModelLoadsRealCoreAndCopiesToPrivatePasteboard() async throws {
        try runCLI(["enable", project.path])
        try hook(["hook_event_name": "Stop", "session_id": "s-2", "prompt_id": "p-9", "cwd": project.path, "last_assistant_message": "Готово ✅"])
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PromptRelayIntegration-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let model = AppModel(core: CoreClient.live(locator: locator()), clipboard: ClipboardService(pasteboard: pasteboard),
                             dataDirectory: home)
        await model.refreshNow()
        XCTAssertEqual(model.selectedSessionKey, "s-2")
        let deadline = Date().addingTimeInterval(10)
        while model.selectedResponseText == nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(model.selectedResponseText, "Готово ✅")
        await model.copySelectedResponse()
        XCTAssertEqual(pasteboard.string(forType: .string), "Готово ✅")
    }
}
