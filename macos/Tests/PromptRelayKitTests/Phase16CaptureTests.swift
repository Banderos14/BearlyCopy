import AppKit
import XCTest
@testable import PromptRelayKit

/// Phase 16: Global Capture through the real Core of this checkout — real
/// CLI, real hook handler, a temporary data folder (the user's history is
/// never read or written). The owner's case: answers from a repository that
/// was never switched on must appear, grouped by project, without a step.
@MainActor
final class Phase16CaptureTests: XCTestCase {
    var base: URL!
    var home: URL!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory.path.withCString { realpath($0, nil) }.map { String(cString: $0) }!
        base = URL(fileURLWithPath: tmp).appendingPathComponent("pr16-capture-\(UUID().uuidString)")
        home = base.appendingPathComponent("data")
        // An isolated HOME: the Mac's real Claude Code plugin is not seen.
        try FileManager.default.createDirectory(at: base.appendingPathComponent("home"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    func repo(_ name: String) throws -> String {
        let url = base.appendingPathComponent("repos/\(name)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: url.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        return url.path
    }

    func locator() -> CoreLocator {
        CoreLocator(processEnvironment: ["HOME": base.appendingPathComponent("home").path, "PROMPT_RELAY_HOME": home.path, "PROMPT_RELAY_CLI": Repo.cli],
                    bundleResourceURL: nil, defaults: { _ in nil })
    }

    /// The hook exactly as Claude Code runs it: one JSON object on stdin.
    func hook(_ payload: [String: Any]) throws {
        let location = try locator().locate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: location.python)
        p.arguments = ["-I", "-S", location.cli, "hook"]
        p.environment = ["HOME": base.appendingPathComponent("home").path, "PROMPT_RELAY_HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        try p.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty, "the hook never writes stdout")
    }

    func turn(_ session: String, in cwd: String, answer: String, prompt: String = "Задача") throws {
        try hook(["hook_event_name": "UserPromptSubmit", "session_id": session, "cwd": cwd, "prompt": prompt, "prompt_id": "p-\(session)"])
        try hook(["hook_event_name": "Stop", "session_id": session, "cwd": cwd, "prompt_id": "p-\(session)",
                  "last_assistant_message": answer, "stop_hook_active": false])
    }

    func outcomes() throws -> [String] {
        try String(contentsOf: home.appendingPathComponent("handler.log"), encoding: .utf8)
            .split(separator: "\n").compactMap { $0.split(separator: " ").last.map(String.init) }
    }

    func model() -> (AppModel, NSPasteboard) {
        let board = NSPasteboard(name: .init("PR16-\(UUID().uuidString)"))
        return (AppModel(core: CoreClient.live(locator: locator()), clipboard: ClipboardService(pasteboard: board),
                         dataDirectory: nil, reportStore: ReportStore(root: base.appendingPathComponent("app"))), board)
    }

    func testGlobalCaptureFindsNewProjectsAndGroupsThemThroughTheRealCore() async throws {
        let relay = try repo("prompt-relay"), theatre = try repo("tete-a-tete-theatre"), third = try repo("third")
        let (m, board) = model()
        defer { board.releaseGlobally() }
        await m.refreshNow()
        XCTAssertEqual(m.captureSettings?.mode, .selected)
        XCTAssertTrue(m.offersGlobalCapture, "the one-time offer, nothing switched on silently")

        // Before Global Capture: the owner's lost answer.
        try turn("lost", in: theatre, answer: "never stored")
        XCTAssertEqual(try outcomes().suffix(2), ["project_not_enabled", "project_not_enabled"])

        await m.setCaptureMode(.mode(.global))
        XCTAssertEqual(m.captureSettings?.mode, .global)
        XCTAssertFalse(m.offersGlobalCapture)

        let theatreAnswer = "Сцена 2 готова ✅\n\n```js\nstage.play()\n```"
        try turn("s-relay", in: relay, answer: "Relay done")
        try turn("s-theatre", in: theatre, answer: theatreAnswer)
        try FileManager.default.createDirectory(atPath: third + "/src", withIntermediateDirectories: true)
        try turn("s-third", in: third + "/src", answer: "Third done")   // a subfolder of a third, unknown repository
        await m.refreshNow()
        let paths = Set(m.projectRows.map(\.path))
        XCTAssertTrue(paths.isSuperset(of: [relay, theatre, third]), "discovered automatically: \(paths)")
        XCTAssertFalse(paths.contains(third + "/src"), "a subfolder groups under its repository")
        XCTAssertTrue(m.projectRows.filter { [relay, theatre, third].contains($0.path) }.allSatisfy(\.captureEnabled))

        await m.loadInbox()
        let inbox = m.inboxEntries
        XCTAssertEqual(Set(inbox.map(\.sessionKey)), ["s-relay", "s-theatre", "s-third"])
        let show = try await CoreClient.live(locator: locator()).show(sessionKey: "s-theatre", turn: 1)
        XCTAssertEqual(show.data.turn.finalResponse?.text, theatreAnswer, "verbatim")

        // Reading the theatre answer (pinned); a new answer in another
        // project is announced, never replaces it.
        m.open(.local(sessionKey: "s-theatre", turn: 1))
        try await Task.sleep(nanoseconds: 300_000_000)
        m.staysOnChosenSession = true   // pins the session being read
        XCTAssertEqual(m.selectedSessionKey, "s-theatre")
        let fourth = try repo("fourth")
        try turn("s-fourth", in: fourth, answer: "Fourth done")
        await m.refreshNow()
        XCTAssertEqual(m.selectedSessionKey, "s-theatre", "the report being read stays")
        XCTAssertEqual(m.newAnswerElsewhere?.sessionKey, "s-fourth", "the new result is announced")
        XCTAssertTrue(m.hasNewAnswer(inProject: fourth), "and marked New on its project")

        // Restart: the same grouping from the stored history.
        let (again, board2) = model()
        defer { board2.releaseGlobally() }
        await again.refreshNow()
        XCTAssertTrue(Set(again.projectRows.map(\.path)).isSuperset(of: [relay, theatre, third]))
        XCTAssertEqual(again.captureSettings?.mode, .global)
    }

    func testExcludeAndPauseThroughTheAppAreHonoredByTheHook() async throws {
        let theatre = try repo("theatre"), secret = try repo("secret")
        let (m, board) = model()
        defer { board.releaseGlobally() }
        await m.refreshNow()
        await m.setCaptureMode(.mode(.global))
        try turn("a", in: secret, answer: "first")
        await m.refreshNow()
        await m.setCapture(false, for: secret)       // the project's Capture switch: off = exclude
        XCTAssertEqual(m.captureSettings?.excludedProjects, [secret])
        XCTAssertEqual(m.captureSettings?.mode, .global)
        try turn("b", in: secret, answer: "must not be stored")
        XCTAssertEqual(try outcomes().last, "project_excluded")
        XCTAssertFalse(m.projectRows.first { $0.path == secret }?.captureEnabled ?? true)

        await m.setCaptureMode(.mode(.paused))
        XCTAssertEqual(m.captureSettings?.mode, .paused)
        XCTAssertFalse(m.captureStatus.isActive, "never shown as capturing while paused")
        try turn("c", in: theatre, answer: "paused")
        XCTAssertEqual(try outcomes().last, "capture_paused")
        await m.setCaptureMode(.resume)
        XCTAssertEqual(m.captureSettings?.mode, .global)
        XCTAssertEqual(m.captureSettings?.resumeMode, nil)
        try turn("d", in: theatre, answer: "resumed")
        XCTAssertEqual(try outcomes().last, "stored")
    }

    func testStatusSaysWhenTheInstalledPluginCannotHonorTheMode() {
        let global = CaptureSettings(mode: .global)
        XCTAssertEqual(AppModel.captureStatus(settings: global, installedPlugin: "0.4.1"),
                       .pluginUpdateRequired(installed: "0.4.1", needed: "0.8.0"))
        XCTAssertFalse(AppModel.CaptureStatus.pluginUpdateRequired(installed: "0.4.1", needed: "0.8.0").isActive,
                       "never shown as capturing")
        XCTAssertEqual(AppModel.captureStatus(settings: global, installedPlugin: "0.8.0"), .allProjects(excluded: 0))
        XCTAssertEqual(AppModel.captureStatus(settings: CaptureSettings(mode: .selected, enabledProjects: ["/a"]), installedPlugin: "0.4.1"),
                       .selectedProjects(count: 1), "selected mode works with an old plugin as before")
        XCTAssertEqual(AppModel.captureStatus(settings: nil, installedPlugin: nil), .unknown)
        XCTAssertTrue(AppModel.CaptureStatus.pluginUpdateRequired(installed: "0.4.1", needed: "0.8.0").detail?
            .contains("claude plugin update prompt-relay@prompt-relay") ?? false)
    }

    func testOlderCoreJSONWithoutCaptureStillDecodes() throws {
        let old = #"{"projects":[{"path":"/p","name":"p","capture_enabled":true,"explicitly_enabled":true,"session_count":0,"last_event_at":null}],"settings":{"retention_days":null,"automatic_deletion":false}}"#
        let data = try JSONDecoder().decode(ProjectsData.self, from: Data(old.utf8))
        XCTAssertNil(data.settings.capture)
        XCTAssertFalse(data.projects[0].excluded)
    }
}
