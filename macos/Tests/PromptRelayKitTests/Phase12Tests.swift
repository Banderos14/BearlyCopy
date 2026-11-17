import AppKit
import Foundation
import Testing
@testable import PromptRelayKit

/// Phase 12: several agents and local profiles side by side, the Results
/// Inbox, independent read states, Quick Switcher, shortcuts, Follow Latest
/// while reading, Open at Login, and the "What can be trusted?" summary.
/// All with test doubles (FakeCore, in-memory defaults); no real hooks,
/// login items or global hot keys are touched.
@MainActor
@Suite(.serialized) struct Phase12Tests {
    // MARK: Fixtures

    static func session(_ key: String, provider: String = "claude_code", host: String = "claude_desktop", profile: String? = nil,
                        hint: String? = nil, project: String, last: String, turns: Int = 1, title: String? = nil,
                        completion: String = "answer") -> SessionSummary {
        var json: [String: Any] = [
            "session_id": key, "session_key": key, "project": ["path": project, "name": (project as NSString).lastPathComponent],
            "first_event_at": last, "last_event_at": last, "event_count": 2, "turn_count": turns, "cwds": [project],
            "last_turn": ["index": turns, "status": "stop_received", "answered_at": last, "completion": completion],
            "integrity": ["corrupt_lines": 0, "unsupported_lines": 0, "foreign_lines": 0],
            "answered_count": turns, "running": false,
            "source": ["provider": provider, "host": host, "native_session_id": "same-native-id", "capture": "hooks",
                       "capabilities": ["prompt", "final_response"]],
        ]
        if let title { json["title"] = title }
        if let profile {
            json["profile"] = ["id": profile, "provider": provider, "basis": profile.hasSuffix("-default") ? "default_home" : "config_dir",
                               "default": profile.hasSuffix("-default"), "hint": hint as Any]
        }
        return try! JSONDecoder().decode(SessionSummary.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func model(_ core: FakeCore, defaults: MemorySettingsStore? = nil) -> (AppModel, NSPasteboard) {
        let board = NSPasteboard(name: .init("PromptRelay12-\(UUID().uuidString)"))
        return (AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults), board)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = Date().addingTimeInterval(60)   // returns as soon as true; generous for the busy full run
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out", sourceLocation: sourceLocation); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func show(_ core: FakeCore) {
        core.showResult = { [unowned core] key, i in
            .success(CoreResult(data: ShowData(session: try! core.session(key), turn: turn(i, text: "\(key)#\(i)")), warnings: []))
        }
    }

    /// Claude Personal (default home) and Claude Work (CLAUDE_CONFIG_DIR) in
    /// one project, same title and same native id; Codex in Xcode elsewhere;
    /// one Claude session recorded before Phase 12 (no profile).
    private func fourAgents() -> FakeCore { Self.makeFourAgents() }

    static func makeFourAgents() -> FakeCore {
        let core = FakeCore(projects: [Phase93Tests.info("/repo", sessions: 3, last: "2026-11-05T12:00:00Z"),
                                       Phase93Tests.info("/app", sessions: 1, last: "2026-11-05T11:00:00Z")])
        core.showResult = { [unowned core] key, i in
            .success(CoreResult(data: ShowData(session: try! core.session(key), turn: turn(i, text: "\(key)#\(i)")), warnings: []))
        }
        core.sessionsByProject["/repo"] = [
            Self.session("personal", profile: "cc-default", hint: "~/.claude", project: "/repo", last: "2026-11-05T12:00:00Z",
                         title: "Fix the login bug"),
            Self.session("work", profile: "cc-0123456789abcdef", hint: "~/.claude-work", project: "/repo",
                         last: "2026-11-05T11:30:00Z", title: "Fix the login bug"),
            Self.session("legacy", project: "/repo", last: "2026-11-04T09:00:00Z", title: "Old task"),
        ]
        core.sessionsByProject["/app"] = [
            Self.session("codex", provider: "codex", host: "xcode", profile: "cx-fedcba9876543210",
                         hint: "~/Library/Developer/Xcode/CodingAssistant/codex", project: "/app", last: "2026-11-05T11:00:00Z",
                         title: "Build the app"),
        ]
        core.turnsBySession["personal"] = [turn(1, request: "Fix the login bug", at: "2026-11-05T12:00:00Z", completion: "answer")]
        core.turnsBySession["work"] = [turn(1, request: "Fix the login bug", at: "2026-11-05T11:30:00Z", completion: "answer")]
        core.turnsBySession["legacy"] = [turn(1, request: "Old task", at: "2026-11-04T09:00:00Z", completion: "answer")]
        core.turnsBySession["codex"] = [turn(1, request: "Build the app", at: "2026-11-05T11:00:00Z", completion: "answer")]
        return core
    }

    // MARK: Identity and By Agent

    @Test func profilesStayApartWithEqualTitlesAndNativeIDs() async throws {
        let (m, board) = model(fourAgents())
        defer { board.releaseGlobally() }
        await m.refreshNow()
        let keys = m.knownProfiles
        #expect(keys.map(\.id) == ["claude_code/cc-default", "claude_code/cc-0123456789abcdef", "claude_code/unassigned",
                                   "codex/cx-fedcba9876543210"], "Default first, Unassigned last, per provider")
        #expect(m.showsProfiles)
        #expect(m.profileTitle(keys[0]) == "Claude · Default")
        #expect(m.profileTitle(keys[1]) == "Claude · claude-work")
        #expect(m.profileTitle(keys[2]) == "Claude · Unassigned")
        #expect(m.profileTitle(keys[3]) == "Codex · Xcode")
        let groups = m.agentGroups
        #expect(groups.count == 4)
        let work = try #require(groups.first { $0.key.profileID == "cc-0123456789abcdef" })
        #expect(work.projects.map(\.name) == ["repo"])
        #expect(work.projects[0].sessions.map(\.sessionKey) == ["work"], "the other profile's equal title is not merged")
        // By Project still shows all three conversations of the project.
        #expect(m.sessionsByProject.first { $0.project == "/repo" }?.sessions.count == 3)
    }

    @Test func profileLabelsPersistAndRemovingOneKeepsHistory() async throws {
        let defaults = MemorySettingsStore()
        let core = fourAgents()
        let (m, board) = model(core, defaults: defaults)
        defer { board.releaseGlobally() }
        await m.refreshNow()
        let work = ProfileKey(provider: .claudeCode, profileID: "cc-0123456789abcdef")
        m.setProfileLabel(work, "  Work  ")
        #expect(m.profileTitle(work) == "Claude · Work")
        let (again, board2) = model(core, defaults: defaults)
        defer { board2.releaseGlobally() }
        await again.refreshNow()
        #expect(again.profileTitle(work) == "Claude · Work", "names survive a restart")
        again.setProfileLabel(work, "")
        #expect(again.profileTitle(work) == "Claude · claude-work")
        #expect(again.agentGroups.first { $0.key == work }?.sessionCount == 1, "removing a name removes no conversation")
        #expect(again.profileExplanation(work).contains("A folder is not an account"), "never presented as an account")
    }

    @Test func historicalSessionsWithoutProfileAreUnassignedNotGuessed() async throws {
        let (m, board) = model(fourAgents())
        defer { board.releaseGlobally() }
        await m.refreshNow()
        let legacy = try #require(m.allSessions.first { $0.sessionKey == "legacy" })
        #expect(legacy.profile == nil)
        #expect(legacy.profileKey.isUnassigned)
        #expect(m.profileExplanation(legacy.profileKey).contains("not moved into another profile"))
    }

    @Test func decodesTheCoresResultsDocument() throws {
        let json = #"""
        {"session_key":"abc.0123456789ab","turn":2,"answered_at":"2026-11-05T12:00:00.000000Z","status":"stop_received",
         "completion":"answer","conversation":{"title":"Fix login","session_id":"abc.0123456789ab"},
         "source":{"provider":"claude_code","host":"claude_desktop","native_session_id":"abc","capabilities":[],"capture":"hooks"},
         "profile":{"id":"cc-0123456789abcdef","provider":"claude_code","basis":"config_dir","default":false,"hint":"~/.claude-work"},
         "native_session_id":"abc","project":{"path":"/repo","name":"repo"},
         "request":{"turn":1,"own":false,"display_preview":"Run the tests","char_count":13},
         "response":{"preview":"All passed","truncated":false,"char_count":10},
         "observed":{"tool_events":3,"runs_exit_zero":1,"runs_nonzero":0,"runs_unknown":0,"files_changed":2,"background_started":0}}
        """#
        let r = try JSONDecoder().decode(ResultSummary.self, from: Data(json.utf8))
        #expect(r.ref == .local(sessionKey: "abc.0123456789ab", turn: 2))
        #expect(r.profileKey == ProfileKey(provider: .claudeCode, profileID: "cc-0123456789abcdef"))
        #expect(r.request?.own == false && r.request?.turn == 1)
        #expect(r.observed?.filesChanged == 2)
        #expect(r.nativeSessionID == "abc")
    }

    // MARK: Results Inbox and read state

    @Test func inboxListsEveryAgentNewestFirstAndOnlyFinalResults() async throws {
        let core = fourAgents()
        core.turnsBySession["personal"] = [
            turn(1, request: "Run the tests", at: "2026-11-05T11:50:00Z", completion: "intermediate", continuedIn: 2),
            turn(2, request: "<task-notification>x</task-notification>", at: "2026-11-05T12:00:00Z", completion: "answer",
                 origin: "automated"),
        ]
        let (m, board) = model(core)
        defer { board.releaseGlobally() }
        await m.refreshNow()
        m.surfaceAppeared()
        m.navigate(to: .inbox)
        try await waitUntil { m.inbox.value != nil }
        #expect(m.inboxEntries.map(\.sessionKey) == ["personal", "work", "codex", "legacy"])
        #expect(m.inboxEntries.first?.turn == 2, "one result per task: the intermediate Stop is not listed")
        #expect(Set(m.inboxEntries.map(\.provider)) == [.claudeCode, .codex])
        m.inboxProfile = ProfileKey(provider: .codex, profileID: "cx-fedcba9876543210")
        #expect(m.inboxEntries.map(\.sessionKey) == ["codex"])
        m.inboxProfile = nil
        m.providerFilter = .codex      // set in Project and Session or History, not visible here
        #expect(m.inboxEntries.count == 4, "no hidden filter from another screen")
    }

    /// The 60 s ceiling in `waitUntil` only absorbs other suites holding the
    /// main thread in the parallel full run. The model itself must be fast:
    /// measured here with a strict bound. Wall-clock timing is meaningful only
    /// when no other suite blocks the main thread, so it runs on request
    /// (`PROMPT_RELAY_TIMING=1`, alone or with `--no-parallel`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROMPT_RELAY_TIMING"] == "1"))
    func inboxAndOpeningAResultAreFast() async throws {
        let (m, board) = model(fourAgents())
        defer { board.releaseGlobally() }
        await m.refreshNow()
        m.surfaceAppeared()
        let clock = ContinuousClock()
        let start = clock.now
        m.navigate(to: .inbox)
        try await waitUntil { m.inbox.value != nil }
        let inboxLoad = clock.now - start
        let work = try #require(m.inboxEntries.first { $0.sessionKey == "work" })
        let open = clock.now
        m.openResult(work)
        try await waitUntil { m.selectedResponseText == "work#1" }
        let opened = clock.now - open
        let direct = await clock.measure { await m.loadInbox() }
        print("PHASE12-TIMING inbox=\(inboxLoad) open=\(opened) loadInbox=\(direct)")
        #expect(inboxLoad < .seconds(1), "Inbox appeared after \(inboxLoad)")
        #expect(opened < .seconds(1), "result opened after \(opened)")
        #expect(direct < .seconds(1))
    }

    @Test func completionUnknownIsSeparateFromFinishedResults() async throws {
        let defaults = MemorySettingsStore()
        defaults.set("2026-11-01T00:00:00Z", forKey: AppModel.lastSeenKey)
        let core = fourAgents()
        // Codex stopped while its tests ran and nothing followed for > 2 h.
        core.sessionsByProject["/app"] = [Self.session("codex", provider: "codex", host: "xcode", profile: "cx-fedcba9876543210",
                                                       project: "/app", last: "2026-11-05T12:30:00Z", title: "Build the app",
                                                       completion: "waiting_background")]
        core.turnsBySession["codex"] = [turn(1, request: "Build the app", at: "2026-11-05T12:30:00Z", completion: "waiting_background")]
        let (m, board) = model(core, defaults: defaults)
        defer { board.releaseGlobally() }
        await m.refreshNow()
        m.surfaceAppeared()
        m.navigate(to: .inbox)
        try await waitUntil { m.inbox.value != nil }
        let finished = m.inboxEntries.map(\.sessionKey)
        #expect(!finished.contains("codex"), "completion unknown is never listed as finished")
        #expect(m.inboxNeedsAttention.map(\.sessionKey) == ["codex"], "kept, in its own section")
        if let visuals = ProcessInfo.processInfo.environment["PROMPT_RELAY_VISUALS"] {
            let island = IslandHost(model: m, maxContentHeight: 448)
            defer { island.close() }
            island.presentation.reduceMotion = true
            island.settle()
            try island.png("\(visuals)/phase12-inbox-attention-448.png")
        }
        let unknown = try #require(m.inboxNeedsAttention.first)
        #expect(!m.isUnread(unknown), "never counted as a new result")
        #expect(AppModel.inboxSection(unknown) == .needsAttention)
        m.inboxFilter = .unread
        #expect(!m.inboxEntries.contains { $0.sessionKey == "codex" })
        m.inboxFilter = .all
        m.markInboxRead()
        m.inboxFilter = .attention
        #expect(m.inboxEntries.map(\.sessionKey) == ["codex"])
        m.switcherQuery = "build"
        #expect(!m.switcherItems().contains { $0.kind == .result && $0.title == "Build the app" && $0.unread })
        // Still openable: history and diagnostics are not lost.
        m.openResult(unknown)
        try await waitUntil { m.selectedResponseText == "codex#1" }
        // A wait that has not expired yet is not listed anywhere.
        #expect(AppModel.inboxSection(unknown, now: Wording.date("2026-11-05T13:00:00Z")!) == nil)
    }

    @Test func readingOneResultLeavesTheOthersUnreadAcrossRestarts() async throws {
        let defaults = MemorySettingsStore()
        defaults.set("2026-11-01T00:00:00Z", forKey: AppModel.lastSeenKey)    // everything here is new
        let core = fourAgents()
        let (m, board) = model(core, defaults: defaults)
        defer { board.releaseGlobally() }
        await m.refreshNow()
        #expect(m.unreadResultCount == 4, "nothing is read before the island opens")
        // Opening the island shows Latest (Claude Personal): only that one is read.
        m.surfaceAppeared()
        await m.refreshNow()
        try await waitUntil { m.selectedResponseText == "personal#1" }
        try await waitUntil { m.unreadResultCount == 3 }
        m.navigate(to: .inbox)
        try await waitUntil { m.inbox.value != nil }
        #expect(m.inboxEntries.filter(m.isUnread).map(\.sessionKey) == ["work", "codex", "legacy"])
        let work = try #require(m.inboxEntries.first { $0.sessionKey == "work" })
        m.openResult(work)
        try await waitUntil { m.selectedResponseText == "work#1" }
        #expect(m.route == .home && m.currentRef == work.ref, "opens exactly that result")
        #expect(!m.isUnread(work))
        m.navigate(to: .inbox)
        try await waitUntil { m.inbox.value != nil }
        #expect(m.inboxEntries.filter(m.isUnread).map(\.sessionKey) == ["codex", "legacy"],
                "Codex and the old Claude session keep their unread state")
        m.surfaceDisappeared()

        let (again, board2) = model(core, defaults: defaults)
        defer { board2.releaseGlobally() }
        await again.refreshNow()
        #expect(again.unreadResultCount == 2, "kept after restart")
        #expect(Set(again.unseenAnswers.map(\.sessionKey)) == ["codex", "legacy"])
    }

    @Test func markAllReadOnlyMarksTheRowsShownAndNextUnreadWalksNewestFirst() async throws {
        let defaults = MemorySettingsStore()
        defaults.set("2026-11-01T00:00:00Z", forKey: AppModel.lastSeenKey)
        let (m, board) = model(fourAgents(), defaults: defaults)
        defer { board.releaseGlobally() }
        await m.refreshNow()
        m.surfaceAppeared()
        await m.refreshNow()
        try await waitUntil { m.selectedResponseText == "personal#1" && m.unreadResultCount == 3 }
        m.navigate(to: .inbox)
        try await waitUntil { m.inbox.value != nil }
        m.inboxProfile = ProfileKey(provider: .codex, profileID: "cx-fedcba9876543210")
        m.markInboxRead()
        m.inboxProfile = nil
        #expect(m.inboxEntries.filter(m.isUnread).map(\.sessionKey) == ["work", "legacy"], "only the Codex rows shown were marked")
        // Next unread: newest first, skipping what is on screen.
        #expect(m.nextUnread?.sessionKey == "work")
        #expect(m.openNextUnread())
        try await waitUntil { m.selectedResponseText == "work#1" }
        #expect(m.nextUnread?.sessionKey == "legacy")
        #expect(m.openNextUnread())
        try await waitUntil { m.selectedResponseText == "legacy#1" }
        #expect(!m.openNextUnread(), "nothing left")
        #expect(m.unreadResultCount == 0)
    }

    @Test func copyWithContextUsesTheResultOpenedFromTheInbox() async throws {
        let core = fourAgents()
        let codex = try core.session("codex")
        core.contextResult = .success(CoreResult(data: ContextData(session: codex, turn: turn(1, text: "codex#1"), exportedAt: "now",
                                                                   text: "PACK codex#1", sensitiveFindings: [],
                                                                   git: GitSummary(available: false, reason: "fixture", branch: nil, head: nil,
                                                                                   changedFileCount: 0, changedFilesTruncated: false)),
                                                 warnings: []))
        let (m, board) = model(core)
        defer { board.releaseGlobally() }
        await m.refreshNow()
        m.surfaceAppeared()
        m.navigate(to: .inbox)
        try await waitUntil { m.inbox.value != nil }
        m.openResult(try #require(m.inboxEntries.first { $0.sessionKey == "codex" }))
        try await waitUntil { m.selectedResponseText == "codex#1" }
        await m.copySelectedContext()
        #expect(core.contextCalls.last.map { "\($0.0)#\($0.1)" } == "codex#1")
    }

    @Test func resultsAreNotLoadedInIdleOrOnHome() async throws {
        let core = fourAgents()
        let (m, board) = model(core)
        defer { board.releaseGlobally() }
        await m.refreshNow()
        m.startBackgroundObservation()
        await m.refreshNow()
        #expect(core.resultsCalls == 0, "the compact notch and Home never load the Inbox")
        m.surfaceAppeared()
        await m.refreshNow()
        #expect(core.resultsCalls == 0)
        m.navigate(to: .inbox)
        try await waitUntil { core.resultsCalls == 1 }
        await m.refreshNow()
        #expect(core.resultsCalls == 2, "refreshed while on screen")
        m.navigate(to: .home)
        await m.refreshNow()
        #expect(core.resultsCalls == 2)
    }

    @Test func inboxShowsErrorsAndRecovers() async throws {
        let core = fourAgents()
        core.resultsOverride = .failure(.timedOut(seconds: 30))
        let (m, board) = model(core)
        defer { board.releaseGlobally() }
        await m.refreshNow()
        m.surfaceAppeared()
        m.navigate(to: .inbox)
        try await waitUntil { m.inbox.error != nil }
        core.resultsOverride = nil
        await m.loadInbox()
        #expect(m.inbox.value?.count == 4)
    }

    // MARK: Follow Latest with several agents

    @Test func aNewerAnswerNeverReplacesTheOneBeingRead() async throws {
        let core = fourAgents()
        let (m, board) = model(core)
        defer { board.releaseGlobally() }
        await m.refreshNow()
        #expect(m.selectedSessionKey == "personal", "launch follows Latest")
        m.surfaceAppeared()
        try await waitUntil { m.selectedResponseText == "personal#1" }
        // Codex finishes a minute later while the user reads Claude's answer.
        core.sessionsByProject["/app"] = [Self.session("codex", provider: "codex", host: "xcode", profile: "cx-fedcba9876543210",
                                                       project: "/app", last: "2026-11-05T12:01:00Z", turns: 2)]
        core.turnsBySession["codex"] = [turn(1, at: "2026-11-05T11:00:00Z", completion: "answer"),
                                        turn(2, at: "2026-11-05T12:01:00Z", completion: "answer")]
        await m.refreshNow()
        #expect(m.readyAnswer?.sessionKey == "codex", "Latest (received) is Codex")
        #expect(m.selectedSessionKey == "personal", "what is read stays")
        #expect(m.deferredLatest?.sessionKey == "codex")
        #expect(m.newAnswerElsewhere?.sessionKey == "codex", "the new answer is announced, not forced")
        m.surfaceDisappeared()
        #expect(m.selectedSessionKey == "codex", "Follow Latest moves on when the island closes")
        #expect(m.deferredLatest == nil)
    }

    @Test func pinnedConversationSurvivesOtherAgentsFinishing() async throws {
        let core = fourAgents()
        let (m, board) = model(core)
        defer { board.releaseGlobally() }
        m.staysOnChosenSession = true
        await m.refreshNow()
        m.surfaceAppeared()
        m.selectSession("work")
        try await waitUntil { m.selectedResponseText == "work#1" }
        m.surfaceDisappeared()
        core.sessionsByProject["/app"] = [Self.session("codex", provider: "codex", host: "xcode", profile: "cx-fedcba9876543210",
                                                       project: "/app", last: "2026-11-05T12:05:00Z", turns: 2)]
        core.turnsBySession["codex"] = [turn(1, at: "2026-11-05T11:00:00Z"), turn(2, at: "2026-11-05T12:05:00Z")]
        await m.refreshNow()
        #expect(m.selectedSessionKey == "work" && m.sessionPinned)
        #expect(m.newAnswerElsewhere?.sessionKey == "codex")
    }

    // MARK: Quick Switcher

    @Test func quickSwitcherFindsAndOpensEachKindOfTarget() async throws {
        let defaults = MemorySettingsStore()
        defaults.set("2026-11-01T00:00:00Z", forKey: AppModel.lastSeenKey)
        let (m, board) = model(fourAgents(), defaults: defaults)
        defer { board.releaseGlobally() }
        await m.refreshNow()
        m.surfaceAppeared()
        m.navigate(to: .switcher)
        let first = m.switcherItems()
        #expect(first.first?.kind == .latest)
        #expect(first.contains { $0.kind == .agent && $0.title == "Claude · claude-work" })
        #expect(first.contains { $0.kind == .project && $0.title == "app" })

        m.switcherQuery = "build the"
        let hits = m.switcherItems()
        let conversation = try #require(hits.first { $0.kind == .conversation })
        #expect(conversation.title == "Build the app")
        m.activate(conversation)
        try await waitUntil { m.selectedSessionKey == "codex" && m.route == .home }

        m.navigate(to: .switcher)
        m.switcherScope = .agents
        let agent = try #require(m.switcherItems().first { $0.title == "Claude · claude-work" })
        m.activate(agent)
        #expect(m.workspaceMode == .byAgent && m.route == .projects)
        #expect(m.browsingProfile == ProfileKey(provider: .claudeCode, profileID: "cc-0123456789abcdef"))

        m.navigate(to: .switcher)
        #expect(m.switcherQuery.isEmpty, "a fresh query each time it opens")
        m.switcherScope = .unread
        #expect(m.switcherItems().allSatisfy { $0.unread })
    }

    @Test func workspaceModeIsRememberedAndByProjectStaysTheDefault() async throws {
        let defaults = MemorySettingsStore()
        let (m, board) = model(fourAgents(), defaults: defaults)
        defer { board.releaseGlobally() }
        #expect(m.workspaceMode == .byProject)
        m.workspaceMode = .byAgent
        m.browsingProfile = ProfileKey(provider: .codex, profileID: "cx-fedcba9876543210")
        let (again, board2) = model(fourAgents(), defaults: defaults)
        defer { board2.releaseGlobally() }
        #expect(again.workspaceMode == .byAgent)
        #expect(again.browsingProfile?.provider == .codex)
    }

    // MARK: Scale (synthetic, no AI)

    @Test func thousandsOfResultsStayResponsive() async throws {
        let core = FakeCore(projects: [Phase93Tests.info("/big", sessions: 50, last: "2026-11-05T12:00:00Z")])
        show(core)
        var sessions: [SessionSummary] = []
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let iso = ISO8601DateFormatter()
        for s in 0..<60 {
            let profile = ["cc-default", "cc-0123456789abcdef", "cx-fedcba9876543210"][s % 3]
            let provider = profile.hasPrefix("cx") ? "codex" : "claude_code"
            var turns: [Turn] = []
            for t in 1...50 {
                turns.append(turn(t, request: "task \(s)-\(t)", at: iso.string(from: start.addingTimeInterval(Double(s * 50 + t))),
                                  completion: "answer"))
            }
            core.turnsBySession["s\(s)"] = turns
            sessions.append(Self.session("s\(s)", provider: provider, profile: profile, project: "/big",
                                         last: iso.string(from: start.addingTimeInterval(Double(s * 50 + 50))), turns: 50,
                                         title: "Conversation \(s)"))
        }
        core.sessionsByProject["/big"] = sessions
        let (m, board) = model(core)
        defer { board.releaseGlobally() }
        await m.refreshNow()
        m.surfaceAppeared()
        m.loadMoreInbox(); m.loadMoreInbox(); m.loadMoreInbox(); m.loadMoreInbox(); m.loadMoreInbox(); m.loadMoreInbox(); m.loadMoreInbox()
        m.navigate(to: .inbox)
        try await waitUntil { (m.inbox.value?.count ?? 0) >= 2400 }
        #expect(m.inboxTotal == 3000)
        let clock = ContinuousClock()
        var entries: [ResultSummary] = []
        let filter = clock.measure { entries = m.inboxEntries }
        #expect(entries.first?.sessionKey == "s59" && entries.first?.turn == 50, "newest first")
        let groups = clock.measure { _ = m.agentGroups }
        m.switcherQuery = "task 12-"
        var hits: [AppModel.SwitcherItem] = []
        let search = clock.measure { hits = m.switcherItems() }
        #expect(!hits.isEmpty)
        #expect(filter < .milliseconds(250), "Inbox filter over \(entries.count) rows took \(filter)")
        #expect(groups < .milliseconds(250), "By Agent grouping took \(groups)")
        #expect(search < .milliseconds(500), "Quick Switcher search took \(search)")
    }

    // MARK: Shortcuts

    @Test func globalShortcutsAreOffByDefaultAndRegisterOnlyWhenTurnedOn() async throws {
        let suite = "PromptRelay12.shortcuts.\(UUID().uuidString)"
        let defaults = try #require(TestDefaults.named(suite))
        defer { removeTestDefaults(suite) }
        let settings = NotchSettings(defaults: defaults)
        settings.animation = .reduced
        #expect(settings.enabledShortcuts.isEmpty)
        let (m, board) = model(fourAgents())
        defer { board.releaseGlobally() }
        var asked: [(GlobalShortcut, ShortcutModifiers)] = []
        let controller = NotchController(model: m, settings: settings, actions: SurfaceActions(quit: {}),
                                         screens: FakeScreens([builtInScreen()]), scheduler: ManualScheduler(),
                                         center: NotificationCenter(), workspaceCenter: NotificationCenter(),
                                         makeHotKey: { nil },
                                         makeShortcut: { shortcut, modifiers in
                                             asked.append((shortcut, modifiers))
                                             return shortcut == .nextUnread ? nil : HotKeyRegistration(inert: ())
                                         },
                                         neighbors: FakeNeighbors(), pointerEvents: FakePointerEvents())
        controller.start()
        defer { controller.stop() }
        #expect(asked.isEmpty, "nothing is registered until the user turns a shortcut on")
        settings.setShortcut(.quickSwitcher, enabled: true)
        settings.setShortcut(.nextUnread, enabled: true)
        #expect(asked.last?.1 == .controlOptionCommand)
        #expect(settings.unavailableShortcuts == [.nextUnread], "a refused combination is reported, not hidden")
        settings.shortcutModifiers = .controlShiftCommand
        #expect(asked.last?.1 == .controlShiftCommand, "re-registered with the new modifiers")
        #expect(settings.display(.quickSwitcher) == "⌃⇧⌘K")
        let reread = NotchSettings(defaults: defaults)
        #expect(reread.enabledShortcuts == [.quickSwitcher, .nextUnread])
        #expect(reread.shortcutModifiers == .controlShiftCommand)
        settings.setShortcut(.quickSwitcher, enabled: false)
        settings.setShortcut(.nextUnread, enabled: false)
        #expect(settings.unavailableShortcuts.isEmpty)
    }

    // MARK: Open at Login

    final class FakeLogin: LoginItemService, @unchecked Sendable {
        var current: LoginItemStatus = .off
        var registerError: Error?
        var afterRegister: LoginItemStatus = .on
        var calls: [String] = []
        func status() -> LoginItemStatus { current }
        func register() throws {
            calls.append("register")
            if let registerError { throw registerError }
            current = afterRegister
        }
        func unregister() throws { calls.append("unregister"); current = .off }
        func openSystemSettings() { calls.append("settings") }
    }

    @Test func openAtLoginIsOffByDefaultAndOnlyForTheInstalledReleaseCopy() {
        let installed = URL(fileURLWithPath: "/Users/x/Applications/BearlyCopy.app")
        let fake = FakeLogin()
        let debug = LoginItemController(service: fake, bundleURL: installed, isDebugBuild: true, installedLocations: [installed])
        #expect(debug.unavailableReason != nil)
        debug.set(true)
        #expect(fake.calls.isEmpty, "a Debug build never registers itself")
        let build = LoginItemController(service: fake, bundleURL: URL(fileURLWithPath: "/tmp/DerivedData/BearlyCopy.app"),
                                        isDebugBuild: false, installedLocations: [installed])
        #expect(build.unavailableReason != nil)
        let app = LoginItemController(service: fake, bundleURL: installed, isDebugBuild: false, installedLocations: [installed])
        #expect(app.unavailableReason == nil && !app.isOn, "off until the user turns it on")
        app.set(true)
        #expect(app.isOn && fake.calls == ["register"])
        app.set(false)
        #expect(!app.isOn && fake.calls == ["register", "unregister"])
        fake.afterRegister = .requiresApproval
        app.set(true)
        #expect(app.status == .requiresApproval && app.message?.contains("Login Items") == true)
        fake.current = .off
        fake.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        app.set(true)
        #expect(!app.isOn && app.message?.hasPrefix("macOS did not add") == true, "a failure is shown, not retried")
    }

    // MARK: What can be trusted?

    @Test func trustSummaryKeepsFactsClaimsAndOpenChecksApart() {
        var input = EvidenceCheck.Input()
        input.observed = try? JSONDecoder().decode(ObservedCounts.self, from: Data(#"""
        {"tool_events":4,"runs_exit_zero":1,"runs_nonzero":1,"runs_unknown":0,"files_changed":2,"background_started":0,"commands_nonzero":1}
        """#.utf8))
        input.answer = "All tests pass and the build succeeds."
        let evidence = EvidenceCheck.make(input)
        let completeness = ArtifactCompleteness(lines: [
            .init(id: "docs", title: "Documents", text: "2 stored"),
            .init(id: "mock", title: "Mockup", text: "1 of 3 states", alert: true, missing: ["Hover", "Error"]),
        ])
        let checklist = ReviewChecklist(items: [.init(id: "run-tests", text: "Run the tests yourself", reason: "Only the agent says so")])
        let trust = TrustSummary.make(evidence: evidence, completeness: completeness, checklist: checklist)
        let confirmed = trust.rows(.confirmed).map(\.text)
        #expect(confirmed.contains("2 files changed with Edit/Write"))
        #expect(confirmed.contains("Documents: 2 stored"))
        #expect(trust.rows(.confirmed).contains { $0.alert }, "a failed command is a confirmed fact, flagged")
        #expect(trust.rows(.reported).map(\.text).contains("The answer says tests pass"))
        #expect(!confirmed.contains { $0.contains("tests pass") }, "a claim is never a confirmed fact")
        let open = trust.rows(.needsVerification)
        #expect(open.contains { $0.text.hasPrefix("Mockup:") && $0.detail?.contains("Hover") == true })
        #expect(open.contains { $0.checklistID == "run-tests" })
        #expect(!trust.rows.contains { $0.text == "CI not connected" }, "unavailable facts stay in Details")
        // Nothing of Evidence, Completeness or the Checklist is lost.
        let shown = evidence.items.filter { $0.kind != .unavailable }.count + completeness.lines.count + checklist.items.count
        #expect(trust.rows.count == shown)
    }
}

/// Phase 12 screens rendered offscreen in the real island (no live GUI):
/// they stay inside the island at small and large heights, and visiting them
/// does not change the height Details opens with (the old Details-height bug).
extension Phase12Tests {
    @Test func newScreensFitAndLeaveDetailsHeightAlone() async throws {
        _ = NSApplication.shared
        let suite = "PromptRelay12.layout.\(UUID().uuidString)"
        let defaults = try #require(TestDefaults.named(suite))
        defaults.set("2026-11-01T00:00:00Z", forKey: AppModel.lastSeenKey)
        defer { removeTestDefaults(suite) }
        let core = Phase12Tests.makeFourAgents()
        let board = NSPasteboard(name: .init(suite))
        defer { board.releaseGlobally() }
        let model = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults)
        await model.refreshNow()
        model.surfaceAppeared()
        await model.refreshNow()
        let visuals = ProcessInfo.processInfo.environment["PROMPT_RELAY_VISUALS"]
        for height: CGFloat in [268, 448] {
            let island = IslandHost(model: model, maxContentHeight: height)
            defer { island.close() }
            island.presentation.reduceMotion = true
            model.route = .home
            island.settle()
            let detailsBefore = island.height
            for (route, mode) in [(AppModel.IslandRoute.inbox, AppModel.WorkspaceMode.byProject), (.switcher, .byProject),
                                  (.projects, .byAgent), (.projects, .byProject), (.evidence, .byProject)] {
                model.workspaceMode = mode
                model.route = .home
                model.navigate(to: route)
                if route == .inbox { try await waitFor { model.inbox.value != nil } }
                island.settle()
                #expect(island.height <= 32 + height + 0.5, "\(route) \(mode) at \(height): \(island.height)")
                #expect(island.height > 32 + 60, "\(route) renders content")
                if let visuals { try island.png("\(visuals)/phase12-\(route.rawValue)-\(mode == .byAgent ? "agent-" : "")\(Int(height)).png") }
            }
            model.route = .home
            island.settle()
            #expect(abs(island.height - detailsBefore) < 0.5, "Details opens at the same height after the new screens")
            if let visuals { try island.png("\(visuals)/phase12-home-\(Int(height)).png") }
        }
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)   // returns as soon as true; generous for the busy full run
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    }
}
