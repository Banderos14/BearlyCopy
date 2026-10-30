import AppKit
import XCTest
@testable import PromptRelayKit

/// Phase 3C: capture per project from Settings, following the newest answer,
/// and the adapter for the enable/disable text commands.
@MainActor
final class ProjectCaptureTests: XCTestCase {
    var suite: String!
    var defaults: UserDefaults!
    var board: NSPasteboard!

    override func setUp() async throws {
        suite = "PromptRelayTests.daily.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayDaily-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
    }

    func model(_ core: FakeCore) -> AppModel {
        AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults)
    }

    func folder() throws -> URL {
        let base = FileManager.default.temporaryDirectory.path.withCString { realpath($0, nil) }.map { String(cString: $0) }!
        let url = URL(fileURLWithPath: base).appendingPathComponent("pr-daily-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAddedProjectStartsWithCaptureOffAndNoCoreCall() async throws {
        let core = FakeCore(projects: [])
        let m = model(core)
        await m.refreshNow()
        let dir = try folder()
        m.addProject(dir)
        XCTAssertEqual(m.projectRows.map(\.path), [dir.path])
        XCTAssertEqual(m.projectRows.first?.captureEnabled, false, "new projects are never enabled automatically")
        XCTAssertEqual(m.projectRows.first?.isAddedOnly, true)
        XCTAssertTrue(core.captureCalls.isEmpty)
        m.addProject(dir)
        XCTAssertEqual(m.projectRows.count, 1, "no duplicates")

        // Remembered across restarts.
        let restarted = model(core)
        XCTAssertEqual(restarted.projectRows.map(\.path), [dir.path])
        restarted.removeAddedProject(dir.path)
        XCTAssertTrue(restarted.projectRows.isEmpty)
    }

    func testEnableAndDisableGoThroughTheCoreAndRefresh() async throws {
        let core = FakeCore(projects: [])
        let m = model(core)
        await m.refreshNow()
        let dir = try folder()
        m.addProject(dir)
        await m.setCapture(true, for: dir.path)
        XCTAssertEqual(core.captureCalls.map(\.0), [true])
        XCTAssertEqual(core.captureCalls.map(\.1), [dir.path])
        XCTAssertEqual(m.projectRows.first?.captureEnabled, true)
        XCTAssertEqual(m.projectRows.first?.isAddedOnly, false, "the Core now knows it")
        guard case .done(_, let message)? = m.captureChange else { return XCTFail("\(String(describing: m.captureChange))") }
        XCTAssertTrue(message.contains("enabled"))

        await m.setCapture(false, for: dir.path)
        XCTAssertEqual(m.projectRows.first?.captureEnabled, false)
        XCTAssertEqual(m.projectRows.count, 1, "still listed after turning capture off")
    }

    func testDisablingKeepsHistoryVisible() async {
        let core = FakeCore(projects: [project("/p", sessions: 1, last: "2026-10-29T10:00:00.000000Z")])
        core.sessionsByProject["/p"] = [sessionSummary("s", project: "/p", last: "2026-10-29T10:00:00.000000Z")]
        core.turnsBySession["s"] = [turn(1)]
        let m = model(core)
        await m.refreshNow()
        await m.setCapture(false, for: "/p")
        XCTAssertEqual(m.projectRows.first?.sessionCount, 1)
        XCTAssertEqual(m.selectedSessionKey, "s")
        XCTAssertEqual(m.turns.value?.count, 1)
    }

    func testCoreRefusalIsShown() async {
        let core = FakeCore(projects: [])
        core.captureError = .api(code: "capture_change_failed", message: "refusing to enable capture for / or your home directory")
        let m = model(core)
        await m.setCapture(true, for: NSHomeDirectory())
        guard case .failed(_, let message)? = m.captureChange else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("home directory"))
    }

    func testInheritedCaptureIsReported() async {
        let core = FakeCore(projects: [])
        core.projectsList = [try! JSONDecoder().decode(ProjectInfo.self, from: Data("""
        {"path":"/root/sub","name":"sub","capture_enabled":true,"explicitly_enabled":false,"session_count":2,"last_event_at":null}
        """.utf8))]
        let m = model(core)
        await m.refreshNow()
        let row = m.projectRows.first
        XCTAssertEqual(row?.captureEnabled, true)
        XCTAssertEqual(row?.explicitlyEnabled, false, "the UI must not offer to turn this off here")
    }
}

@MainActor
final class FollowLatestTests: XCTestCase {
    var board: NSPasteboard!

    override func setUp() async throws {
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayFollow-\(UUID().uuidString)"))
    }

    override func tearDown() async throws { board.releaseGlobally() }

    /// Project /busy has the newest activity, but its last turn is still
    /// waiting; /done has the newest finished answer.
    func core() -> FakeCore {
        let core = FakeCore(projects: [project("/busy", sessions: 1, last: "2026-10-29T12:00:00.000000Z"),
                                       project("/done", sessions: 2, last: "2026-10-29T11:00:00.000000Z"),
                                       project("/failed", sessions: 1, last: "2026-10-29T11:30:00.000000Z")])
        core.sessionsByProject["/busy"] = [sessionSummary("busy", project: "/busy", last: "2026-10-29T12:00:00.000000Z",
                                                          lastTurn: 1, status: "awaiting_response")]
        core.sessionsByProject["/failed"] = [sessionSummary("failed", project: "/failed", last: "2026-10-29T11:30:00.000000Z",
                                                            lastTurn: 1, status: "api_error")]
        core.sessionsByProject["/done"] = [sessionSummary("done-new", project: "/done", last: "2026-10-29T11:00:00.000000Z", lastTurn: 2),
                                           sessionSummary("done-old", project: "/done", last: "2026-10-28T09:00:00.000000Z")]
        core.turnsBySession["busy"] = [turn(1, status: "awaiting_response", preview: nil)]
        core.turnsBySession["failed"] = [turn(1, status: "api_error", preview: nil)]
        core.turnsBySession["done-new"] = [turn(1), turn(2, preview: "latest", chars: 6)]
        core.turnsBySession["done-old"] = [turn(1, preview: "older", chars: 5)]
        core.showResult = { [unowned core] key, i in
            .success(CoreResult(data: ShowData(session: try! core.session(key), turn: turn(i, text: "\(key)#\(i)")), warnings: []))
        }
        return core
    }

    func testLaunchOpensOnNewestFinishedAnswer() async {
        let m = AppModel(core: core(), clipboard: ClipboardService(pasteboard: board), dataDirectory: nil)
        await m.refreshNow()
        XCTAssertEqual(m.selectedProjectPath, "/done", "not the project with a prompt still waiting, nor an API error")
        XCTAssertEqual(m.selectedSessionKey, "done-new")
        XCTAssertEqual(m.selectedTurnIndex, 2)
        XCTAssertEqual(m.selectedResponseText, "done-new#2")
    }

    func testNewAnswerIsFollowedUnlessTheUserBrowsesElsewhere() async throws {
        let c = core()
        let m = AppModel(core: c, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil)
        await m.refreshNow()

        // A new answer in /busy: followed (nobody picked anything).
        c.sessionsByProject["/busy"] = [sessionSummary("busy", project: "/busy", last: "2026-10-29T13:00:00.000000Z", lastTurn: 1)]
        c.turnsBySession["busy"] = [turn(1, preview: "now done", chars: 8)]
        await m.refreshNow()
        XCTAssertEqual(m.selectedSessionKey, "busy")

        // The user opens an older session of /done …
        m.surfaceAppeared()
        m.selectProject("/done")
        try await waitUntil { m.selectedSessionKey != nil }
        m.selectSession("done-old")
        try await waitUntil { m.selectedResponseText == "done-old#1" }
        XCTAssertFalse(m.followsLatest)

        // … and another answer arrives: the selection stays put.
        c.sessionsByProject["/failed"] = [sessionSummary("failed", project: "/failed", last: "2026-10-29T14:00:00.000000Z", lastTurn: 2)]
        c.turnsBySession["failed"] = [turn(1, status: "api_error", preview: nil), turn(2, preview: "recovered", chars: 9)]
        await m.refreshNow()
        XCTAssertEqual(m.selectedSessionKey, "done-old", "never switched while the user is reading")
        XCTAssertEqual(m.readyAnswer?.sessionKey, "failed")
        XCTAssertTrue(m.hasUnseenAnswer || m.readyAnswer != nil)

        // Phase 5 (R7): the user picked this session, so an answer in another
        // session never replaces it, even after the island closes: it waits
        // behind the "New in …" chip.
        m.surfaceDisappeared()
        XCTAssertTrue(m.followsLatest)
        XCTAssertTrue(m.sessionPinned)
        c.sessionsByProject["/done"] = [sessionSummary("done-new", project: "/done", last: "2026-10-29T15:00:00.000000Z", lastTurn: 3),
                                        sessionSummary("done-old", project: "/done", last: "2026-10-28T09:00:00.000000Z")]
        c.turnsBySession["done-new"] = [turn(1), turn(2), turn(3, preview: "third", chars: 5)]
        await m.refreshNow()
        XCTAssertEqual(m.selectedSessionKey, "done-old", "the chosen session stays")
        XCTAssertEqual(m.newAnswerElsewhere?.sessionKey, "done-new", "the new answer is announced, not shown")
        await m.revealReadyAnswer()
        XCTAssertEqual(m.selectedSessionKey, "done-old", "opening the island does not switch sessions either")

        // The chip opens the other session's newest answer and pins it.
        m.openNewAnswerElsewhere()
        try await waitUntil { m.selectedResponseText == "done-new#3" }
        XCTAssertEqual(m.selectedSessionKey, "done-new")
        XCTAssertEqual(m.selectedTurnIndex, 3)
        XCTAssertNil(m.newAnswerElsewhere)

        // A new answer in the pinned session itself is followed.
        c.sessionsByProject["/done"] = [sessionSummary("done-new", project: "/done", last: "2026-10-29T16:00:00.000000Z", lastTurn: 4),
                                        sessionSummary("done-old", project: "/done", last: "2026-10-28T09:00:00.000000Z")]
        c.turnsBySession["done-new"] = [turn(1), turn(2), turn(3, preview: "third", chars: 5), turn(4, preview: "fourth", chars: 6)]
        await m.refreshNow()
        XCTAssertEqual(m.selectedSessionKey, "done-new")
        XCTAssertEqual(m.selectedTurnIndex, 4)
    }

    func testPinnedSessionSurvivesARestart() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "pr-pin-\(UUID().uuidString)"))
        let c = core()
        let first = AppModel(core: c, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults)
        await first.refreshNow()
        first.selectProject("/done")
        try await waitUntil { first.selectedSessionKey != nil }
        first.selectSession("done-old")
        try await waitUntil { first.selectedResponseText == "done-old#1" }

        let second = AppModel(core: c, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults)
        await second.refreshNow()
        XCTAssertEqual(second.selectedSessionKey, "done-old", "the chosen session is back after a restart")
        XCTAssertTrue(second.sessionPinned)
    }

    func testCopyKeepsEveryAnswer() async {
        let m = AppModel(core: core(), clipboard: ClipboardService(pasteboard: board), dataDirectory: nil)
        await m.refreshNow()
        let before = m.turns.value
        await m.copySelectedResponse()
        XCTAssertEqual(board.string(forType: .string), "done-new#2")
        await m.refreshNow()
        XCTAssertEqual(m.turns.value, before, "copying hides nothing")
        XCTAssertEqual(m.selectedTurnIndex, 2)
    }

    func testEmptyHistoryAndErrors() async {
        let empty = AppModel(core: FakeCore(projects: []), clipboard: ClipboardService(pasteboard: board), dataDirectory: nil)
        await empty.refreshNow()
        XCTAssertNil(empty.readyAnswer)
        XCTAssertNil(empty.selectedProjectPath)

        let broken = FakeCore(projects: [])
        broken.projectsResult = .failure(.pythonMissing(searched: []))
        let m = AppModel(core: broken, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil)
        await m.refreshNow()
        XCTAssertEqual(m.projects.error, .pythonMissing(searched: []))
        XCTAssertNil(m.readyAnswer, "no answer is guessed when the Core is unavailable")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("condition not met in time") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

final class CaptureCommandTests: XCTestCase {
    let location = CoreLocation(python: "/py", cli: "/pr/bin/prompt-relay")

    func testEnableRunsTheTextCommandWithoutJSON() async throws {
        let runner = FakeRunner([CommandOutput(exitCode: 0, stdout: Data("capture enabled for /p\nplugin hooks will use Python 3.9.6 (/py)\n".utf8))])
        let loc = location
        let message = try await CoreClient(runner: runner) { loc }.setCapture(true, path: "/p")
        XCTAssertEqual(runner.calls.first?.arguments, ["-I", "-S", "-B", "/pr/bin/prompt-relay", "enable", "/p"])
        XCTAssertEqual(message, "capture enabled for /p")
    }

    func testRefusalCarriesTheCoreMessage() async {
        let runner = FakeRunner([CommandOutput(exitCode: 1, stdout: Data(),
                                               stderr: Data("prompt-relay: not a directory: /nope\n".utf8))])
        let loc = location
        do {
            _ = try await CoreClient(runner: runner) { loc }.setCapture(true, path: "/nope")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CoreError, .api(code: "capture_change_failed", message: "not a directory: /nope"))
        }
        let disable = FakeRunner([CommandOutput(exitCode: 0, stdout: Data("capture disabled for /p (existing history is kept; use 'delete' to remove it)\n".utf8))])
        let message = try? await CoreClient(runner: disable) { loc }.setCapture(false, path: "/p")
        XCTAssertEqual(disable.calls.first?.arguments.suffix(2), ["disable", "/p"])
        XCTAssertTrue(message?.contains("history is kept") ?? false)
    }
}

/// The real Core: enable and disable a temporary folder in a temporary data dir.
final class CaptureIntegrationTests: XCTestCase {
    func testRealEnableDisableRoundTrip() async throws {
        let base = FileManager.default.temporaryDirectory.path.withCString { realpath($0, nil) }.map { String(cString: $0) }!
        let tmp = URL(fileURLWithPath: base).appendingPathComponent("pr-cap-\(UUID().uuidString)")
        let project = tmp.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let locator = CoreLocator(processEnvironment: ["HOME": NSHomeDirectory(), "PROMPT_RELAY_HOME": tmp.appendingPathComponent("data").path,
                                                       "PROMPT_RELAY_CLI": Repo.cli],
                                  bundleResourceURL: nil, defaults: { _ in nil })
        let core = CoreClient.live(locator: locator)
        let on = try await core.setCapture(true, path: project.path)
        XCTAssertTrue(on.contains("capture enabled"))
        let listed = try await core.projects().data.projects
        XCTAssertEqual(listed.map(\.path), [project.path])
        XCTAssertEqual(listed.first?.captureEnabled, true)
        let off = try await core.setCapture(false, path: project.path)
        XCTAssertTrue(off.contains("capture disabled"))
        let after = try await core.projects().data.projects
        XCTAssertTrue(after.allSatisfy { !$0.captureEnabled })
        do {
            _ = try await core.setCapture(true, path: NSHomeDirectory())
            XCTFail("the Core refuses the home folder")
        } catch {
            XCTAssertEqual((error as? CoreError)?.apiCode, "capture_change_failed")
        }
    }
}
