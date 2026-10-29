import AppKit
import XCTest
@testable import PromptRelayKit

/// A Core double built from golden answers or inline values.
final class FakeCore: CoreProviding, @unchecked Sendable {
    var projectsResult: Result<CoreResult<ProjectsData>, CoreError>
    var sessionsByProject: [String: [SessionSummary]] = [:]
    var turnsBySession: [String: [Turn]] = [:]
    var showResult: (String, Int) -> Result<CoreResult<ShowData>, CoreError>
    var contextResult: Result<CoreResult<ContextData>, CoreError> = .failure(.api(code: "not_found", message: "none"))
    private(set) var showCalls: [(String, Int)] = []
    private(set) var sessionsCalls = 0
    private(set) var turnsCalls = 0

    init(projects: [ProjectInfo]) {
        projectsResult = .success(CoreResult(data: ProjectsData(projects: projects, settings: RetentionSettings(retentionDays: nil, automaticDeletion: false)), warnings: []))
        showResult = { _, _ in .failure(.api(code: "not_found", message: "none")) }
    }

    func projects() async throws -> CoreResult<ProjectsData> { try projectsResult.get() }
    func sessions(project: String?) async throws -> CoreResult<SessionsData> {
        sessionsCalls += 1
        let list = project.map { sessionsByProject[$0] ?? [] }
            ?? sessionsByProject.values.flatMap { $0 }.sorted { ($0.lastEventAt ?? "") > ($1.lastEventAt ?? "") }
        return CoreResult(data: SessionsData(projectFilter: project, sessions: list), warnings: [])
    }
    func turns(sessionKey: String) async throws -> CoreResult<TurnsData> {
        turnsCalls += 1
        guard let turns = turnsBySession[sessionKey] else { throw CoreError.api(code: "not_found", message: "no session") }
        return CoreResult(data: TurnsData(session: try session(sessionKey), turns: turns), warnings: [])
    }
    func show(sessionKey: String, turn: Int) async throws -> CoreResult<ShowData> {
        showCalls.append((sessionKey, turn))
        return try showResult(sessionKey, turn).get()
    }
    func context(sessionKey: String, turn: Int) async throws -> CoreResult<ContextData> { try contextResult.get() }
    var doctorResult: Result<CoreResult<DoctorData>, CoreError> = .failure(.api(code: "internal_error", message: "n/a"))
    func doctor() async throws -> CoreResult<DoctorData> { try doctorResult.get() }

    private(set) var captureCalls: [(Bool, String)] = []
    var captureError: CoreError?
    func setCapture(_ enabled: Bool, path: String) async throws -> String {
        captureCalls.append((enabled, path))
        if let captureError { throw captureError }
        if let i = projectsList.firstIndex(where: { $0.path == path }) {
            projectsList[i] = project(path, sessions: projectsList[i].sessionCount, last: projectsList[i].lastEventAt, enabled: enabled)
        } else if enabled {
            projectsList.append(project(path, sessions: 0, last: nil, enabled: true))
        }
        return "capture \(enabled ? "enabled" : "disabled") for \(path)"
    }

    /// The projects the fake Core reports (kept in step with setCapture).
    var projectsList: [ProjectInfo] {
        get { (try? projectsResult.get().data.projects) ?? [] }
        set { projectsResult = .success(CoreResult(data: ProjectsData(projects: newValue, settings: RetentionSettings(retentionDays: nil, automaticDeletion: false)), warnings: [])) }
    }

    func session(_ key: String) throws -> SessionSummary {
        try XCTUnwrap(sessionsByProject.values.flatMap { $0 }.first { $0.sessionKey == key })
    }
}

func project(_ path: String, sessions: Int, last: String?, enabled: Bool = true) -> ProjectInfo {
    try! JSONDecoder().decode(ProjectInfo.self, from: Data("""
    {"path":"\(path)","name":"\((path as NSString).lastPathComponent)","capture_enabled":\(enabled),"explicitly_enabled":\(enabled),
     "session_count":\(sessions),"last_event_at":\(last.map { "\"\($0)\"" } ?? "null")}
    """.utf8))
}

func sessionSummary(_ key: String, project: String, last: String, lastTurn: Int = 1,
                    status: String = "stop_received") -> SessionSummary {
    try! JSONDecoder().decode(SessionSummary.self, from: Data("""
    {"session_id":"\(key)","session_key":"\(key)","project":{"path":"\(project)","name":"p"},"first_event_at":"\(last)",
     "last_event_at":"\(last)","event_count":2,"turn_count":\(lastTurn),"cwds":[],"last_turn":{"index":\(lastTurn),"status":"\(status)"},
     "integrity":{"corrupt_lines":0,"unsupported_lines":0,"foreign_lines":0}}
    """.utf8))
}

func turn(_ index: Int, status: String = "stop_received", preview: String? = "answer…", chars: Int = 7, text: String? = nil,
          request: String? = nil, link: String = "prompt_id") -> Turn {
    let requestJSON = request.map { r in
        "{\"preview\":\(String(data: try! JSONEncoder().encode(r), encoding: .utf8)!),\"truncated\":false,\"char_count\":\(r.count),\"utf8_bytes\":\(r.utf8.count),\"prompt_id\":\"p\(index)\",\"received_at\":\"2026-10-29T16:13:00.000000Z\"}"
    } ?? "null"
    let response = preview.map { p in
        let textField = text.map { ",\"text\":" + String(data: try! JSONEncoder().encode($0), encoding: .utf8)! } ?? ""
        return "{\"preview\":\(String(data: try! JSONEncoder().encode(p), encoding: .utf8)!),\"truncated\":true,\"char_count\":\(chars),\"utf8_bytes\":\(chars),\"prompt_id\":\"p\(index)\",\"received_at\":\"2026-10-29T16:13:51.000000Z\"\(textField)}"
    } ?? "null"
    let error = status == "api_error" ? #"{"type":"rate_limit","details":null,"message":"API Error: Rate limit"}"# : "null"
    return try! JSONDecoder().decode(Turn.self, from: Data("""
    {"index":\(index),"status":"\(status)","link":"\(link)","request":\(requestJSON),"final_response":\(response),
     "response_event_count":1,"background_tasks":null,"error":\(error),"candidate_request_turns":[]}
    """.utf8))
}

@MainActor
final class AppModelTests: XCTestCase {
    var pasteboard: NSPasteboard!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("PromptRelayModelTests-\(UUID().uuidString)"))
    }

    override func tearDown() async throws { pasteboard.releaseGlobally() }

    func model(_ core: FakeCore) -> AppModel {
        AppModel(core: core, clipboard: ClipboardService(pasteboard: pasteboard), dataDirectory: nil)
    }

    func testEmptyHistoryShowsNoProjects() async {
        let m = model(FakeCore(projects: []))
        await m.refreshNow()
        XCTAssertEqual(m.projects, .loaded([]))
        XCTAssertNil(m.selectedProjectPath)
        XCTAssertEqual(m.sessions, .loaded([]))
        XCTAssertNil(m.selectedTurn)
    }

    func testCoreFailureIsShownAndRecoverable() async {
        let core = FakeCore(projects: [])
        core.projectsResult = .failure(.pythonMissing(searched: ["/usr/bin/python3"]))
        let m = model(core)
        await m.refreshNow()
        XCTAssertEqual(m.projects.error, .pythonMissing(searched: ["/usr/bin/python3"]))
        core.projectsResult = .success(CoreResult(data: ProjectsData(projects: [], settings: RetentionSettings(retentionDays: nil, automaticDeletion: false)), warnings: []))
        await m.refreshNow()
        XCTAssertEqual(m.projects, .loaded([]))
    }

    func testDefaultsToNewestProjectSessionAndCopyableTurn() async throws {
        let core = FakeCore(projects: [project("/old", sessions: 1, last: "2026-01-01T00:00:00.000000Z"),
                                       project("/new", sessions: 1, last: "2026-10-29T00:00:00.000000Z"),
                                       project("/empty", sessions: 0, last: nil)])
        core.sessionsByProject["/new"] = [sessionSummary("s-new", project: "/new", last: "2026-10-29T00:00:00.000000Z",
                                                         lastTurn: 3, status: "awaiting_response")]
        core.turnsBySession["s-new"] = [turn(1), turn(2), turn(3, status: "awaiting_response", preview: nil)]
        core.showResult = { key, index in
            .success(CoreResult(data: ShowData(session: try! core.session(key), turn: turn(index, text: "full answer \(index)")), warnings: []))
        }
        let m = model(core)
        await m.refreshNow()
        XCTAssertEqual(m.selectedProjectPath, "/new")
        XCTAssertEqual(m.selectedSessionKey, "s-new")
        XCTAssertEqual(m.selectedTurnIndex, 2, "the newest turn with an answer, not the pending one")
        XCTAssertEqual(m.selectedResponseText, "full answer 2")
        XCTAssertEqual(m.turnsNewestFirst.map(\.index), [3, 2, 1])
    }

    func testCopyResponseUsesFullTextNotPreview() async throws {
        let core = FakeCore(projects: [project("/p", sessions: 1, last: "2026-10-29T00:00:00.000000Z")])
        core.sessionsByProject["/p"] = [sessionSummary("s", project: "/p", last: "2026-10-29T00:00:00.000000Z")]
        let full = String(repeating: "Ответ 🚀\r\n", count: 500) + "\u{0}end"
        core.turnsBySession["s"] = [turn(1, preview: String(full.prefix(200)), chars: full.unicodeScalars.count)]
        core.showResult = { key, i in
            .success(CoreResult(data: ShowData(session: try! core.session(key), turn: turn(i, chars: full.unicodeScalars.count, text: full)), warnings: []))
        }
        let m = model(core)
        await m.refreshNow()
        await m.copySelectedResponse()
        XCTAssertEqual(m.copyFeedback, .copied(.response, characters: full.unicodeScalars.count))
        XCTAssertEqual(pasteboard.data(forType: .string), Data(full.utf8))

        // A row button for another turn fetches its own full text.
        await m.copyResponse(sessionKey: "s", turn: 1)
        XCTAssertEqual(pasteboard.data(forType: .string), Data(full.utf8))
    }

    func testApiErrorTurnIsNotCopyable() async {
        let core = FakeCore(projects: [project("/p", sessions: 1, last: "2026-10-29T00:00:00.000000Z")])
        core.sessionsByProject["/p"] = [sessionSummary("s", project: "/p", last: "2026-10-29T00:00:00.000000Z")]
        core.turnsBySession["s"] = [turn(1, status: "api_error", preview: nil)]
        let m = model(core)
        await m.refreshNow()
        XCTAssertEqual(m.selectedTurnIndex, 1)
        XCTAssertNotNil(AppModel.copyBlocker(for: m.selectedTurn!))
        XCTAssertTrue(core.showCalls.isEmpty, "no show call for a turn without an answer")
        XCTAssertEqual(m.detail, .idle)
    }

    func testFailedShowReportsErrorAndClipboardIsUntouched() async {
        let core = FakeCore(projects: [project("/p", sessions: 1, last: "2026-10-29T00:00:00.000000Z")])
        core.sessionsByProject["/p"] = [sessionSummary("s", project: "/p", last: "2026-10-29T00:00:00.000000Z")]
        core.turnsBySession["s"] = [turn(1)]
        core.showResult = { _, _ in .failure(.timedOut(seconds: 30)) }
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)
        let m = model(core)
        await m.refreshNow()
        await m.copySelectedResponse()
        guard case .failed(let message) = m.copyFeedback else { return XCTFail("\(m.copyFeedback)") }
        XCTAssertTrue(message.contains("did not answer"))
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }

    func testSensitiveContextNeedsConfirmation() async throws {
        let core = FakeCore(projects: [project("/p", sessions: 1, last: "2026-10-29T00:00:00.000000Z")])
        core.sessionsByProject["/p"] = [sessionSummary("s", project: "/p", last: "2026-10-29T00:00:00.000000Z")]
        core.turnsBySession["s"] = [turn(1)]
        core.showResult = { key, i in .success(CoreResult(data: ShowData(session: try! core.session(key), turn: turn(i, text: "x")), warnings: [])) }
        let context = try JSONDecoder().decode(ContextData.self, from: Data("""
        {"session":\(String(data: try JSONEncoder.sessionJSON("s"), encoding: .utf8)!),
         "turn":{"index":1,"status":"stop_received","link":"prompt_id","request":null,"final_response":null,"response_event_count":1,"background_tasks":null,"error":null,"candidate_request_turns":[]},
         "exported_at":"2026-10-29T00:00:00.000000Z","text":"# Context\\nkey line",
         "sensitive_findings":[{"section":"response","line":2,"kind":"AWS access key id"}],
         "git":{"available":false,"reason":"not a git repository","branch":null,"head":null,"changed_file_count":0,"changed_files_truncated":false}}
        """.utf8))
        core.contextResult = .success(CoreResult(data: context, warnings: []))
        pasteboard.clearContents()
        let m = model(core)
        await m.refreshNow()
        await m.copySelectedContext()
        XCTAssertNotNil(m.pendingSensitiveContext)
        XCTAssertNil(pasteboard.string(forType: .string), "nothing copied before confirmation")
        XCTAssertTrue(SensitiveContextAlert.summary(context.sensitiveFindings).contains("AWS access key id — response, line 2"))
        m.confirmSensitiveContextCopy()
        XCTAssertEqual(pasteboard.string(forType: .string), "# Context\nkey line")
        XCTAssertEqual(m.copyFeedback, .copied(.context, characters: 18))
    }

    func testSelectionChangeLoadsThatSession() async throws {
        let core = FakeCore(projects: [project("/p", sessions: 2, last: "2026-10-29T00:00:00.000000Z")])
        core.sessionsByProject["/p"] = [sessionSummary("s2", project: "/p", last: "2026-10-29T00:00:00.000000Z"),
                                        sessionSummary("s1", project: "/p", last: "2026-10-28T00:00:00.000000Z")]
        core.turnsBySession["s2"] = [turn(1)]
        core.turnsBySession["s1"] = [turn(1), turn(2)]
        core.showResult = { key, i in .success(CoreResult(data: ShowData(session: try! core.session(key), turn: turn(i, text: "\(key)-\(i)")), warnings: [])) }
        let m = model(core)
        await m.refreshNow()
        XCTAssertEqual(m.selectedResponseText, "s2-1")
        m.selectSession("s1")
        try await waitUntil { m.selectedResponseText == "s1-2" }
        m.selectTurn(1)
        try await waitUntil { m.selectedResponseText == "s1-1" }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("condition not met in time") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

extension JSONEncoder {
    static func sessionJSON(_ key: String) throws -> Data {
        Data("""
        {"session_id":"\(key)","session_key":"\(key)","project":{"path":"/p","name":"p"},"first_event_at":null,"last_event_at":null,
         "event_count":1,"turn_count":1,"cwds":[],"last_turn":null,"integrity":{"corrupt_lines":0,"unsupported_lines":0,"foreign_lines":0}}
        """.utf8)
    }
}
