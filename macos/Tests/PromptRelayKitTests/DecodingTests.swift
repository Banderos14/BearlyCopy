import XCTest
@testable import PromptRelayKit

/// Every golden CLI answer (tests/golden/expected) decodes into the Swift
/// models, and the decoded values match the documented semantics.
final class DecodingTests: XCTestCase {
    func testEveryGoldenResponseDecodesOrMapsToItsError() throws {
        let calls = try GoldenCall.all()
        XCTAssertGreaterThanOrEqual(calls.count, 40)
        for call in calls {
            let label = "\(call.file):\(call.name)"
            do {
                switch call.command {
                case "projects": _ = try CoreClient.decode(call.output) as CoreResult<ProjectsData>
                case "sessions": _ = try CoreClient.decode(call.output) as CoreResult<SessionsData>
                case "turns": _ = try CoreClient.decode(call.output) as CoreResult<TurnsData>
                case "show": _ = try CoreClient.decode(call.output) as CoreResult<ShowData>
                case "context": _ = try CoreClient.decode(call.output) as CoreResult<ContextData>
                default: continue  // retention etc.: not used by the app
                }
                XCTAssertEqual(call.exitCode, 0, label)
            } catch let error as CoreError {
                guard case .api(let code, let message) = error else { return XCTFail("\(label): \(error)") }
                XCTAssertNotEqual(call.exitCode, 0, label)
                XCTAssertFalse(code.isEmpty, label)
                XCTAssertFalse(message.isEmpty, label)
            }
        }
    }

    func testRealDesktopAnswerIsExact() throws {
        let show: CoreResult<ShowData> = try CoreClient.decode(GoldenCall.named("01", "show").output)
        XCTAssertEqual(show.data.turn.finalResponse?.text, "Привет, мир! 🚀")
        XCTAssertEqual(show.data.turn.link, .promptID)
        XCTAssertEqual(show.data.turn.status, .stopReceived)
        // char_count is Unicode scalars, not grapheme clusters.
        XCTAssertEqual(show.data.turn.finalResponse?.charCount, "Привет, мир! 🚀".unicodeScalars.count)
    }

    func testUnicodeAndMarkdownSurviveDecoding() throws {
        for name in ["show_unicode", "show_markdown"] {
            let call = try GoldenCall.named("09", name)
            let show: CoreResult<ShowData> = try CoreClient.decode(call.output)
            let raw = try JSONSerialization.jsonObject(with: call.stdout) as! [String: Any]
            let expected = (((raw["data"] as! [String: Any])["turn"] as! [String: Any])["final_response"] as! [String: Any])["text"] as! String
            XCTAssertEqual(show.data.turn.finalResponse?.text.map { Array($0.unicodeScalars) }, Array(expected.unicodeScalars), name)
        }
    }

    func testAmbiguousAndApiErrorTurns() throws {
        let ambiguous: CoreResult<TurnsData> = try CoreClient.decode(GoldenCall.named("05", "turns").output)
        let last = try XCTUnwrap(ambiguous.data.turns.last)
        XCTAssertEqual(last.link, .ambiguous)
        XCTAssertNil(last.request)
        XCTAssertEqual(last.candidateRequestTurns, [1, 2])

        let api: CoreResult<TurnsData> = try CoreClient.decode(GoldenCall.named("06", "turns").output)
        let failed = try XCTUnwrap(api.data.turns.first)
        XCTAssertEqual(failed.status, .apiError)
        XCTAssertNil(failed.finalResponse)
        XCTAssertNotNil(AppModel.copyBlocker(for: failed))
        XCTAssertThrowsError(try CoreClient.decode(GoldenCall.named("06", "show").output) as CoreResult<ShowData>) {
            XCTAssertEqual(($0 as? CoreError)?.apiCode, "no_final_response")
        }
    }

    func testEmptyStore() throws {
        let sessions: CoreResult<SessionsData> = try CoreClient.decode(GoldenCall.named("13", "sessions").output)
        XCTAssertEqual(sessions.data.sessions, [])
        let projects: CoreResult<ProjectsData> = try CoreClient.decode(GoldenCall.named("13", "projects").output)
        // An enabled project without history is still listed, with zero sessions.
        XCTAssertTrue(projects.data.projects.allSatisfy { $0.sessionCount == 0 })
        XCTAssertThrowsError(try CoreClient.decode(GoldenCall.named("13", "turns").output) as CoreResult<TurnsData>) {
            XCTAssertEqual(($0 as? CoreError)?.apiCode, "not_found")
        }
    }

    func testBackgroundTasksWarningIsKept() throws {
        let show: CoreResult<ShowData> = try CoreClient.decode(GoldenCall.named("10", "show_turn_1").output)
        XCTAssertEqual(show.data.turn.status, .stopReceivedBackgroundTasksPending)
        XCTAssertTrue(show.warnings.contains { $0.code == "background_tasks_pending" })
    }

    func testUnknownFieldsAndEnumValuesAreTolerated() throws {
        let data = """
        {"projects":[{"path":"/p","name":"p","capture_enabled":true,"explicitly_enabled":true,
          "session_count":1,"last_event_at":null,"future_field":{"x":1}}],
         "settings":{"retention_days":null,"automatic_deletion":false},"another":[]}
        """
        let result: CoreResult<ProjectsData> = try CoreClient.decode(CommandOutput(exitCode: 0, stdout: envelope(command: "projects", data: data)))
        XCTAssertEqual(result.data.projects.first?.path, "/p")

        let turn = try JSONDecoder().decode(Turn.self, from: Data("""
        {"index":1,"status":"brand_new_status","link":"telepathy","request":null,"final_response":null,
         "response_event_count":0,"background_tasks":null,"error":null,"candidate_request_turns":[]}
        """.utf8))
        XCTAssertEqual(turn.status, .unknown("brand_new_status"))
        XCTAssertEqual(turn.link, .unknown("telepathy"))
    }
}
