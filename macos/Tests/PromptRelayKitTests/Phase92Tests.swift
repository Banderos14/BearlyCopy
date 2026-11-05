import AppKit
import Foundation
import Testing
@testable import PromptRelayKit

@MainActor
struct Phase92Tests {
    private func doctor() throws -> DoctorData {
        try JSONDecoder().decode(DoctorData.self, from: Data(#"""
        {"core":{"prompt_relay_version":"test","python":{"executable":"python","version":"3.9","supported":true},"pinned_python":{"state":"ok"}},
         "storage":{"data_dir":"/test","exists":true,"writable":true,"session_files":1},
         "capture":{"enabled_projects":["/project"]},"configuration":{"plugin":{"state":"ok","records":[]}},
         "observed":{"state":"ok","by_via":{},"outcomes":{}},"findings":[],"unverified":[]}
        """#.utf8))
    }

    @Test func connectionCheckPublishesFreshSessions() async throws {
        let core = FakeCore(projects: [])
        core.doctorResult = .success(CoreResult(data: try doctor(), warnings: []))
        core.sessionsByProject["/project"] = [sessionSummary("fresh", project: "/project", last: "2026-11-04T09:00:00Z")]
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let model = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil)
        model.tracksReadyAnswers = false
        #expect(model.allSessions.isEmpty)
        _ = await model.testIntegrationConnection()
        #expect(model.allSessions.map(\.sessionKey) == ["fresh"])
    }

    @Test func diagnosticsSeparateExecutionFromStorageAndSupportOldCore() throws {
        #expect(try doctor().observed.bySource == nil)
        let empty = CodexDeliveryStatus(sessions: [], observed: nil)
        #expect(empty.summary.contains("not confirmed"))
        let source = try JSONDecoder().decode(DoctorData.Observed.Source.self, from: Data(#"""
        {"events":1,"last_at":"2026-11-04T09:00:00Z","last_event":"UserPromptSubmit","last_outcome":"project_not_enabled"}
        """#.utf8))
        let rejected = CodexDeliveryStatus(sessions: [], observed: source)
        #expect(rejected.summary.contains("handler executed"))
        #expect(rejected.detail.contains("capture is off"))
        #expect(!rejected.summary.contains("events saved"))
        let legacy = CodexDeliveryStatus(sessions: [sessionSummary("claude", project: "/p", last: "now")], observed: nil)
        #expect(legacy.xcodeSessions.isEmpty)
    }

    @Test func cliCannotConfirmXcodeAndPromptCannotConfirmStop() throws {
        func captured(host: String, status: String) throws -> SessionSummary {
            try JSONDecoder().decode(SessionSummary.self, from: Data("""
            {"session_id":"native","session_key":"codex-test","project":{"path":"/p","name":"p"},
             "first_event_at":"2026-11-04T09:00:00Z","last_event_at":"2026-11-04T09:00:00Z",
             "event_count":1,"turn_count":1,"cwds":["/p"],"last_turn":{"index":1,"status":"\(status)"},
             "integrity":{"corrupt_lines":0,"unsupported_lines":0,"foreign_lines":0},
             "source":{"provider":"codex","host":"\(host)","native_session_id":"native","capture":"hooks","capabilities":["prompt","final_response"]}}
            """.utf8))
        }
        let cli = CodexDeliveryStatus(sessions: [try captured(host: "terminal", status: "stop_received")], observed: nil)
        #expect(cli.summary.contains("not confirmed"))
        let prompt = CodexDeliveryStatus(sessions: [try captured(host: "xcode", status: "awaiting_response")], observed: nil)
        #expect(prompt.summary.contains("events saved"))
        #expect(prompt.detail.contains("waiting for Stop"))
        let stopped = CodexDeliveryStatus(sessions: [try captured(host: "xcode", status: "stop_received")], observed: nil)
        #expect(stopped.detail.contains("Stop and answer received"))
        let noText = CodexDeliveryStatus(sessions: [try captured(host: "xcode", status: "stop_received_without_text")], observed: nil)
        #expect(noText.detail.contains("without answer text"))
    }
}
