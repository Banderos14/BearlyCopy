import AppKit
import Foundation
import Testing
@testable import PromptRelayKit

/// Phase 12.1: Needs Input in the app, from the Core's `attention` only.
/// FakeCore data and offscreen rendering; no live agents, dialogs or
/// notifications.
@MainActor
@Suite(.serialized) struct Phase121Tests {
    static func session(_ key: String, provider: String = "claude_code", host: String = "claude_desktop", project: String = "/repo",
                        last: String, status: String = "awaiting_response", completion: String = "working",
                        attention: String? = nil, since: String? = nil, running: Bool = true, turns: Int = 1) -> SessionSummary {
        var json: [String: Any] = [
            "session_id": key, "session_key": key, "project": ["path": project, "name": (project as NSString).lastPathComponent],
            "first_event_at": last, "last_event_at": last, "event_count": 2, "turn_count": turns, "cwds": [project],
            "last_turn": ["index": turns, "status": status, "completion": completion],
            "integrity": ["corrupt_lines": 0, "unsupported_lines": 0, "foreign_lines": 0],
            "answered_count": 0, "running": running, "title": "Task \(key)",
            "source": ["provider": provider, "host": host, "native_session_id": key, "capture": "hooks", "capabilities": []],
        ]
        if let attention {
            json["attention"] = ["state": "needs_input", "kind": attention, "since": since ?? last, "subagent": false]
        }
        return try! JSONDecoder().decode(SessionSummary.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func now(minus seconds: TimeInterval = 0) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date().addingTimeInterval(-seconds))
    }

    private func model(_ core: FakeCore) -> (AppModel, NSPasteboard) {
        let board = NSPasteboard(name: .init("PromptRelay121-\(UUID().uuidString)"))
        return (AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil), board)
    }

    private func core(_ sessions: [SessionSummary]) -> FakeCore {
        let core = FakeCore(projects: [Phase93Tests.info("/repo", sessions: sessions.count, last: Self.now())])
        core.sessionsByProject["/repo"] = sessions
        for s in sessions { core.turnsBySession[s.sessionKey] = [turn(1, preview: nil, request: "Task", completion: "working")] }
        return core
    }

    @Test func decodesAttentionAndKinds() throws {
        let s = Self.session("a", last: Self.now(), attention: "plan_approval")
        #expect(s.attention?.kind == .planApproval)
        #expect(s.attention?.kind.title == "Plan approval")
        #expect(Self.session("b", last: Self.now(), attention: "permission").attention?.kind.title == "Permission required")
        #expect(Self.session("c", last: Self.now(), attention: "something_new").attention?.kind.title == "Input requested",
                "unknown kinds are accepted, worded neutrally")
        #expect(Self.session("d", last: Self.now()).attention == nil)
    }

    @Test func needsInputComesFirstAndOtherAgentsKeepTheirState() async throws {
        let waiting = Self.session("claude", last: Self.now(minus: 30), attention: "question")
        let working = Self.session("codex", provider: "codex", host: "xcode", last: Self.now(minus: 10))
        let (m, board) = model(core([waiting, working]))
        defer { board.releaseGlobally() }
        await m.refreshNow()
        #expect(m.readyIndicator == .needsInput(sessions: 1), "the amber dot, not the working dots")
        #expect(m.sessionState(m.allSessions.first { $0.sessionKey == "claude" }!) == .needsInput)
        #expect(m.sessionState(m.allSessions.first { $0.sessionKey == "codex" }!) == .working, "Codex still shows working")
        #expect(m.needsInputLine == "Claude Code · Needs input · Question")
        #expect(m.needsInputBandLine(withKind: false) == "Needs input")
        #expect(m.needsInputBandLine(withKind: true) == "Claude · Needs input · Question")
        #expect(m.agentsNeedingInput.map(\.sessionKey) == ["claude"])
        #expect(!m.hasUnseenAnswer, "a question is never an answer")
        #expect(m.readyAnswer == nil)
        #expect(SessionSwitcherView.chip(.needsInput).0 == "needs input")
        #expect(ReadyIndicatorView.label(.needsInput(sessions: 1)).contains("needs your input"))
    }

    @Test func answeredWaitReturnsToWorkingThenAnswer() async throws {
        let c = core([Self.session("claude", last: Self.now(minus: 30), attention: "permission")])
        let (m, board) = model(c)
        defer { board.releaseGlobally() }
        await m.refreshNow()
        #expect(m.readyIndicator == .needsInput(sessions: 1))
        c.sessionsByProject["/repo"] = [Self.session("claude", last: Self.now(minus: 5))]   // allowed: working again
        await m.refreshNow()
        #expect(m.readyIndicator == .working(sessions: 1))
        #expect(m.needsInputLine == nil)
    }

    @Test func severalWaitingAgentsAreCountedNotMerged() async throws {
        let (m, board) = model(core([
            Self.session("a", last: Self.now(minus: 60), attention: "question", since: Self.now(minus: 60)),
            Self.session("b", provider: "codex", host: "terminal", last: Self.now(minus: 20), attention: "permission",
                         since: Self.now(minus: 20)),
        ]))
        defer { board.releaseGlobally() }
        await m.refreshNow()
        #expect(m.readyIndicator == .needsInput(sessions: 2))
        #expect(m.needsInputLine == "2 agents need input")
        #expect(m.agentsNeedingInput.map(\.sessionKey) == ["a", "b"], "longest waiting first")
        #expect(m.agentsNeedingInput.map(\.kind) == [.question, .permission])
    }

    @Test func aHostWithoutSignalsKeepsItsLastConfirmedState() async throws {
        // Codex in Xcode: no waiting signal reaches Prompt Relay. Nothing is invented.
        let (m, board) = model(core([Self.session("x", provider: "codex", host: "xcode", last: Self.now(minus: 10))]))
        defer { board.releaseGlobally() }
        await m.refreshNow()
        #expect(m.readyIndicator == .working(sessions: 1))
        #expect(m.agentsNeedingInput.isEmpty)
    }

    @Test func notificationOncePerWaitNeverForWaitsFoundAtLaunch() async throws {
        let c = core([Self.session("old", last: Self.now(minus: 300), attention: "question", since: Self.now(minus: 300))])
        let (m, board) = model(c)
        defer { board.releaseGlobally() }
        var announced: [String] = []
        m.onNeedsInput = { announced.append($0.sessionKey + ":" + $0.kind.title) }
        await m.refreshNow()
        #expect(announced.isEmpty, "a wait already there at launch is not announced")
        let since = Self.now(minus: 2)
        c.sessionsByProject["/repo"]!.append(Self.session("new", last: since, attention: "permission", since: since))
        await m.refreshNow()
        await m.refreshNow()
        await m.refreshNow()
        #expect(announced == ["new:Permission required"], "announced once, however often it refreshes")
        c.sessionsByProject["/repo"]![1] = Self.session("new", last: Self.now(), attention: "question", since: Self.now())
        await m.refreshNow()
        #expect(announced.count == 2, "a later, different wait in the same conversation is new")

        // Restart: the same waits are the baseline again, nothing repeats.
        let (again, board2) = model(c)
        defer { board2.releaseGlobally() }
        var repeated = 0
        again.onNeedsInput = { _ in repeated += 1 }
        await again.refreshNow()
        await again.refreshNow()
        #expect(repeated == 0)
    }

    @Test func notifyNeedsInputIsOffByDefault() {
        let settings = NotchSettings(defaults: MemorySettingsStore())
        #expect(!settings.notifyNeedsInput)
        #expect(!settings.notifyWhenReady)
    }

    @Test func bandShowsNeedsInputInQuickPeekAndDetails() async throws {
        _ = NSApplication.shared
        let c = core([Self.session("claude", last: Self.now(minus: 30), attention: "plan_approval")])
        let (m, board) = model(c)
        defer { board.releaseGlobally() }
        await m.refreshNow()
        let visuals = ProcessInfo.processInfo.environment["PROMPT_RELAY_VISUALS"]
        for surface in [NotchPresentation.Surface.peek, .expanded] {
            let island = IslandHost(model: m, surface: surface, maxContentHeight: 268)
            defer { island.close() }
            island.presentation.reduceMotion = true
            island.settle()
            let frame = try #require(island.presentation.layoutFrames["band.needsInput"], "\(surface)")
            #expect(island.contains(frame.insetBy(dx: 1, dy: 1)), "inside the island (\(surface))")
            if let visuals { try island.png("\(visuals)/phase121-band-\(surface == .peek ? "peek" : "details").png") }
        }
    }
}
