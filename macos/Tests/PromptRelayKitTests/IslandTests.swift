import AppKit
import XCTest
@testable import PromptRelayKit

/// Phase 3D.1 (redesign): one island with views inside it (projects, recent,
/// all responses, settings, full response) over the AppModel, and telling
/// Debug and Release builds apart.
@MainActor
final class IslandNavigationTests: XCTestCase {
    var suite: String!
    var defaults: UserDefaults!
    var board: NSPasteboard!

    override func setUp() async throws {
        suite = "PromptRelayTests.workspace.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayWorkspace-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        removeTestDefaults(suite)
    }

    func twoProjects() -> FakeCore {
        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-29T16:00:00.000000Z"),
                                       project("/b", sessions: 1, last: "2026-10-29T15:00:00.000000Z")])
        core.sessionsByProject["/a"] = [sessionSummary("sa", project: "/a", last: "2026-10-29T16:00:00.000000Z", lastTurn: 2)]
        core.sessionsByProject["/b"] = [sessionSummary("sb", project: "/b", last: "2026-10-29T15:00:00.000000Z")]
        core.turnsBySession["sa"] = [turn(1, preview: "a1", chars: 2), turn(2, preview: "a2", chars: 2)]
        core.turnsBySession["sb"] = [turn(1, preview: "b1", chars: 2)]
        return core
    }

    func model(_ core: FakeCore) -> AppModel {
        AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults)
    }

    func settle() async { try? await Task.sleep(nanoseconds: 100_000_000) }

    func testStartsOnHomeAndBackReturnsWhereItCameFrom() {
        let m = model(twoProjects())
        XCTAssertEqual(m.route, .home)
        m.navigate(to: .settings)
        m.navigate(to: .projects)                         // Settings → Capture → Projects
        XCTAssertEqual(m.backRoute, .settings)
        m.goBack()
        XCTAssertEqual(m.route, .settings)
        m.goBack()
        XCTAssertEqual(m.route, .home)
        m.navigate(to: .history)
        m.route = .home                                   // picking an answer returns Home
        XCTAssertEqual(m.backRoute, .home)
    }

    func testPickingAProjectShowsItsNewestAnswer() async {
        let m = model(twoProjects())
        await m.refreshNow()
        XCTAssertEqual(m.selectedProjectPath, "/a")
        m.navigate(to: .projects)
        m.openProject("/b")
        XCTAssertEqual(m.route, .home)
        await settle()
        XCTAssertEqual(m.selectedProjectPath, "/b")
        XCTAssertEqual(m.selectedSessionKey, "sb")
        XCTAssertEqual(m.selectedTurnIndex, 1)
        XCTAssertFalse(m.followsLatest, "a manual pick is not overridden by the next answer")
    }

    func testPickingTheSelectedProjectAgainOnlySwitchesTab() async {
        let core = twoProjects()
        let m = model(core)
        await m.refreshNow()
        let calls = core.sessionsCalls
        m.navigate(to: .projects)
        m.openProject("/a")
        await settle()
        XCTAssertEqual(m.route, .home)
        XCTAssertEqual(core.sessionsCalls, calls, "no reload for the project already shown")
    }

    func testHistoryOpensAnEarlierAnswer() async {
        let m = model(twoProjects())
        await m.refreshNow()
        XCTAssertEqual(m.selectedTurnIndex, 2)
        m.navigate(to: .history)
        m.openAnswer(turn: 1)
        XCTAssertEqual(m.route, .home)
        XCTAssertEqual(m.selectedTurnIndex, 1)
        await settle()
        XCTAssertEqual(m.turnsNewestFirst.map(\.index), [2, 1], "nothing is hidden or removed")
    }

    func testAllResponsesGroupsEverySessionByProjectWithoutExtraCalls() async {
        let core = twoProjects()
        core.sessionsByProject["/a"] = [sessionSummary("sa", project: "/a", last: "2026-10-29T16:00:00.000000Z", lastTurn: 2),
                                        sessionSummary("sa2", project: "/a/sub", last: "2026-10-29T14:00:00.000000Z")]
        core.turnsBySession["sa2"] = [turn(1, preview: "sub", chars: 3)]
        let m = model(core)
        await m.refreshNow()
        let groups = m.sessionsByProject
        XCTAssertEqual(groups.map(\.project), ["/a", "/b"], "newest activity first")
        XCTAssertEqual(groups[0].sessions.map(\.sessionKey), ["sa", "sa2"], "a subfolder belongs to its enabled root")
        let calls = core.sessionsCalls
        m.focusSession(groups[1].sessions[0])             // open a session of another project
        await settle()
        XCTAssertEqual(m.selectedProjectPath, "/b")
        XCTAssertEqual(m.selectedSessionKey, "sb")
        XCTAssertEqual(m.selectedTurnIndex, 1)
        XCTAssertEqual(core.sessionsCalls, calls + 1, "only that project's sessions are reloaded")
    }

    func testNewAnswerMarksItsProjectAndParentFolders() async {
        let core = twoProjects()
        let m = model(core)
        await m.refreshNow()                              // first run: everything counts as seen
        XCTAssertFalse(m.hasNewAnswer(inProject: "/a"))
        core.sessionsByProject["/a"] = [sessionSummary("sa", project: "/a/sub", last: "2026-10-29T17:00:00.000000Z", lastTurn: 3)]
        core.turnsBySession["sa"] = [turn(1, at: "2026-10-29T15:50:00.000000Z"), turn(2, at: "2026-10-29T16:00:00.000000Z"), turn(3, preview: "new", chars: 3, at: "2026-10-29T17:00:00.000000Z")]
        await m.refreshNow()
        XCTAssertTrue(m.hasUnseenAnswer)
        XCTAssertTrue(m.hasNewAnswer(inProject: "/a"), "captured under /a (a subfolder)")
        XCTAssertFalse(m.hasNewAnswer(inProject: "/b"))
        XCTAssertFalse(m.hasNewAnswer(inProject: "/a/s"), "a path prefix is not a parent folder")
        m.acknowledgeReadyAnswer()
        XCTAssertFalse(m.hasNewAnswer(inProject: "/a"))
    }

    func testCopyFromTheWorkspaceUsesTheFullText() async {
        let core = twoProjects()
        let full = String(repeating: "Полный ответ 🚀\n", count: 400)    // longer than anything shown
        core.showResult = { [core] key, i in
            .success(CoreResult(data: ShowData(session: try! core.session(key), turn: turn(i, chars: full.unicodeScalars.count, text: full)),
                                warnings: []))
        }
        let m = model(core)
        await m.refreshNow()
        await settle()
        XCTAssertGreaterThan(full.count, 800, "longer than any preview")
        await m.copySelectedResponse()
        XCTAssertEqual(board.string(forType: .string), full)
        XCTAssertEqual(m.turnsNewestFirst.count, 2, "copy keeps every answer")
    }
}

final class AppBuildTests: XCTestCase {
    func testOtherBuildsAreDetectedWithoutCountingItself() {
        let release = AppBuild.releaseBundleID, debug = AppBuild.debugBundleID
        XCTAssertEqual(AppBuild.otherBuilds(own: release, running: ["com.apple.finder", release]), [])
        XCTAssertEqual(AppBuild.otherBuilds(own: release, running: [release, debug]), [debug])
        XCTAssertEqual(AppBuild.otherBuilds(own: debug, running: [release, debug, "fr.louisraille.Coucou"]), [release])
        XCTAssertEqual(AppBuild.otherBuilds(own: release, running: [release, release]), [release], "a second copy of the same build")
        XCTAssertEqual(AppBuild.name(of: debug), "Prompt Relay (Debug)")
    }
}
