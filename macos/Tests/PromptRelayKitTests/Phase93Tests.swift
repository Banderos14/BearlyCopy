import AppKit
import Foundation
import Testing
@testable import PromptRelayKit

/// Phase 9.3: one Latest across Claude Code and Codex, explicit pinning,
/// logical projects, session states, smart attachments and continuation
/// context. Fake Core and named pasteboards only: no real history, no
/// system clipboard.
@Suite(.serialized)
@MainActor
struct Phase93Tests {
    // MARK: Fixtures

    static func session(_ key: String, provider: String? = nil, host: String = "unknown", project: String,
                        logical: String? = nil, last: String, answeredAt: String? = nil, turns: Int = 1,
                        status: String = "stop_received", answered: Int? = nil, running: Bool = false) -> SessionSummary {
        var json: [String: Any] = [
            "session_id": key, "session_key": key, "project": ["path": project, "name": (project as NSString).lastPathComponent],
            "first_event_at": last, "last_event_at": last, "event_count": 2, "turn_count": turns, "cwds": [project],
            "last_turn": ["index": turns, "status": status].merging(answeredAt.map { ["answered_at": $0] } ?? [:]) { a, _ in a },
            "integrity": ["corrupt_lines": 0, "unsupported_lines": 0, "foreign_lines": 0],
            "answered_count": answered ?? (status.hasPrefix("stop_received") && status != "stop_received_without_text" ? turns : 0),
            "running": running,
        ]
        if let provider {
            json["source"] = ["provider": provider, "host": host, "native_session_id": "native-" + key, "capture": "hooks",
                              "capabilities": ["prompt", "final_response"]]
        }
        if let logical {
            json["logical_project"] = ["path": logical, "name": (logical as NSString).lastPathComponent, "basis": "git_root"]
        }
        return try! JSONDecoder().decode(SessionSummary.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func info(_ path: String, logical: String? = nil, sessions: Int, last: String?, enabled: Bool = true) -> ProjectInfo {
        var p = project(path, sessions: sessions, last: last, enabled: enabled)
        if let logical { p.logicalProject = LogicalProject(path: logical, name: (logical as NSString).lastPathComponent, basis: "git_root") }
        return p
    }

    private func model(_ core: FakeCore, defaults: UserDefaults? = nil) -> (AppModel, NSPasteboard) {
        let board = NSPasteboard(name: .init("PromptRelay93-\(UUID().uuidString)"))
        return (AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults), board)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func show(_ core: FakeCore) {
        core.showResult = { [unowned core] key, i in
            .success(CoreResult(data: ShowData(session: try! core.session(key), turn: turn(i, text: "\(key)#\(i)")), warnings: []))
        }
    }

    // MARK: A. Claude → Codex → Claude

    @Test func latestFollowsCompletionAcrossProviders() async throws {
        let core = FakeCore(projects: [Self.info("/repo", sessions: 2, last: "2026-11-05T10:00:00Z")])
        show(core)
        core.sessionsByProject["/repo"] = [Self.session("claude", project: "/repo", last: "2026-11-05T10:00:00Z")]
        core.turnsBySession["claude"] = [turn(1, preview: "A")]
        let (m, board) = model(core)
        defer { board.releaseGlobally() }
        await m.refreshNow()
        #expect(m.readyAnswer?.sessionKey == "claude")
        #expect(m.selectedSessionKey == "claude")

        // Codex in Xcode finishes B: Quick Peek moves to it, no provider switch needed.
        core.sessionsByProject["/repo"] = [
            Self.session("codex", provider: "codex", host: "xcode", project: "/repo/macos", logical: "/repo",
                         last: "2026-11-05T10:05:00Z", answeredAt: "2026-11-05T10:05:00Z"),
            Self.session("claude", project: "/repo", last: "2026-11-05T10:00:00Z"),
        ]
        core.turnsBySession["codex"] = [turn(1, preview: "B")]
        await m.refreshNow()
        #expect(m.readyAnswer?.sessionKey == "codex")
        #expect(m.readyAnswer?.provider == .codex)
        #expect(m.readyAnswer?.sourceLabel == "Codex · Xcode · This Mac")
        #expect(m.readyAnswer?.projectPath == "/repo", "the logical project, not `macos`")
        #expect(m.selectedSessionKey == "codex")

        // Claude finishes C: Latest is C again.
        core.sessionsByProject["/repo"] = [
            Self.session("claude", project: "/repo", last: "2026-11-05T10:09:00Z", answeredAt: "2026-11-05T10:09:00Z", turns: 2),
            Self.session("codex", provider: "codex", host: "xcode", project: "/repo/macos", logical: "/repo",
                         last: "2026-11-05T10:05:00Z", answeredAt: "2026-11-05T10:05:00Z"),
        ]
        core.turnsBySession["claude"] = [turn(1, preview: "A"), turn(2, preview: "C", at: "2026-11-05T10:09:00Z")]
        await m.refreshNow()
        #expect(m.readyAnswer?.sessionKey == "claude" && m.readyAnswer?.turnIndex == 2)
        #expect(m.readyAnswer?.provider == .claudeCode)
        #expect(m.readyAnswer?.sourceLabel == "Claude Code · Unknown · This Mac", "the host is never guessed")
        try await waitUntil { m.selectedResponseText == "claude#2" }
        #expect(m.selectedSessionKey == "claude" && m.selectedTurnIndex == 2)
    }

    // MARK: B. Parallel agents: completion decides, not start or activity

    @Test func parallelAgentsAreOrderedByCompletionWithText() async throws {
        let core = FakeCore(projects: [Self.info("/repo", sessions: 2, last: "2026-11-05T11:00:00Z")])
        show(core)
        // Codex started first and has the newest activity (a tool event after
        // its Stop), but Claude's answer was stored later.
        core.sessionsByProject["/repo"] = [
            Self.session("codex", provider: "codex", host: "xcode", project: "/repo", last: "2026-11-05T11:00:00Z",
                         answeredAt: "2026-11-05T10:50:00Z"),
            Self.session("claude", project: "/repo", last: "2026-11-05T10:55:00Z", answeredAt: "2026-11-05T10:55:00Z"),
        ]
        core.turnsBySession["codex"] = [turn(1)]
        core.turnsBySession["claude"] = [turn(1)]
        let (m, board) = model(core)
        defer { board.releaseGlobally() }
        await m.refreshNow()
        #expect(m.readyAnswer?.sessionKey == "claude", "completion time, not latest activity")

        // A running session (prompt, no Stop) and a Stop without text never become Latest.
        core.sessionsByProject["/repo"] = [
            Self.session("codex", provider: "codex", host: "xcode", project: "/repo", last: "2026-11-05T11:30:00Z",
                         turns: 2, status: "awaiting_response", answered: 1, running: true),
            Self.session("empty", provider: "codex", host: "terminal", project: "/repo", last: "2026-11-05T11:20:00Z",
                         status: "stop_received_without_text"),
            Self.session("claude", project: "/repo", last: "2026-11-05T10:55:00Z", answeredAt: "2026-11-05T10:55:00Z"),
        ]
        core.turnsBySession["codex"] = [turn(1, at: "2026-11-05T10:50:00Z"), turn(2, status: "awaiting_response", preview: nil)]
        core.turnsBySession["empty"] = [turn(1, status: "stop_received_without_text", preview: nil)]
        await m.refreshNow()
        #expect(m.readyAnswer?.sessionKey == "claude")
        #expect(m.sessionState(core.sessionsByProject["/repo"]![0]) == .working)
        #expect(m.sessionState(core.sessionsByProject["/repo"]![1]) == .noAnswer, "0 answers never looks finished")
        #expect(m.sessionState(core.sessionsByProject["/repo"]![2]) == .answered)

        // Codex then finishes later: it becomes Latest; repeating the same data changes nothing.
        core.sessionsByProject["/repo"]![0] = Self.session("codex", provider: "codex", host: "xcode", project: "/repo",
                                                           last: "2026-11-05T11:40:00Z", answeredAt: "2026-11-05T11:40:00Z", turns: 2)
        core.turnsBySession["codex"] = [turn(1, at: "2026-11-05T10:50:00Z"), turn(2, at: "2026-11-05T11:40:00Z")]
        await m.refreshNow()
        #expect(m.readyAnswer?.sessionKey == "codex" && m.readyAnswer?.turnIndex == 2)
        let before = m.readyAnswer
        await m.refreshNow()
        #expect(m.readyAnswer == before, "a repeated delivery is not a new answer")
    }

    // MARK: C. Pinned session vs Follow Latest

    @Test func pinnedSessionStaysAndOffersJumpToLatest() async throws {
        let core = FakeCore(projects: [Self.info("/repo", sessions: 2, last: "2026-11-05T12:00:00Z")])
        show(core)
        core.sessionsByProject["/repo"] = [
            Self.session("new", project: "/repo", last: "2026-11-05T12:00:00Z", answeredAt: "2026-11-05T12:00:00Z"),
            Self.session("old", provider: "codex", host: "xcode", project: "/repo", last: "2026-11-04T09:00:00Z"),
        ]
        core.turnsBySession["new"] = [turn(1)]
        core.turnsBySession["old"] = [turn(1)]
        let (m, board) = model(core)
        defer { board.releaseGlobally() }
        m.staysOnChosenSession = true
        await m.refreshNow()
        m.surfaceAppeared()
        m.selectSession("old")
        try await waitUntil { m.selectedResponseText == "old#1" }
        #expect(m.sessionPinned)
        m.surfaceDisappeared()

        core.sessionsByProject["/repo"]![0] = Self.session("new", project: "/repo", last: "2026-11-05T12:30:00Z",
                                                           answeredAt: "2026-11-05T12:30:00Z", turns: 2)
        core.turnsBySession["new"] = [turn(1), turn(2, at: "2026-11-05T12:30:00Z")]
        await m.refreshNow()
        #expect(m.selectedSessionKey == "old", "the pinned session is not replaced")
        #expect(m.newAnswerElsewhere?.sessionKey == "new", "the new answer is announced")
        #expect(m.isOffLatest)

        m.jumpToLatest()
        try await waitUntil { m.selectedResponseText == "new#2" }
        #expect(m.selectedSessionKey == "new")
        #expect(m.sessionPinned, "Jump to Latest keeps pin mode, now on the latest session")

        m.followLatestNow()
        #expect(!m.staysOnChosenSession && !m.sessionPinned)
    }

    @Test func followLatestHoldsOnlyWhileTheIslandIsOpen() async throws {
        let core = FakeCore(projects: [Self.info("/repo", sessions: 2, last: "2026-11-05T12:00:00Z")])
        show(core)
        core.sessionsByProject["/repo"] = [
            Self.session("new", provider: "codex", host: "xcode", project: "/repo", last: "2026-11-05T12:00:00Z"),
            Self.session("old", project: "/repo", last: "2026-11-04T09:00:00Z"),
        ]
        core.turnsBySession["new"] = [turn(1)]
        core.turnsBySession["old"] = [turn(1)]
        let (m, board) = model(core)
        defer { board.releaseGlobally() }
        await m.refreshNow()
        #expect(!m.staysOnChosenSession, "new installs follow Latest")
        m.surfaceAppeared()
        m.selectSession("old")
        try await waitUntil { m.selectedResponseText == "old#1" }
        #expect(!m.sessionPinned, "browsing does not pin")

        core.sessionsByProject["/repo"]![0] = Self.session("new", provider: "codex", host: "xcode", project: "/repo",
                                                           last: "2026-11-05T12:30:00Z", answeredAt: "2026-11-05T12:30:00Z", turns: 2)
        core.turnsBySession["new"] = [turn(1), turn(2, at: "2026-11-05T12:30:00Z")]
        await m.refreshNow()
        #expect(m.selectedSessionKey == "old", "never switched while the user reads")
        #expect(m.newAnswerElsewhere?.sessionKey == "new", "but the new answer is visible")

        m.surfaceDisappeared()
        core.sessionsByProject["/repo"]![0] = Self.session("new", provider: "codex", host: "xcode", project: "/repo",
                                                           last: "2026-11-05T12:40:00Z", answeredAt: "2026-11-05T12:40:00Z", turns: 3)
        core.turnsBySession["new"] = [turn(1), turn(2, at: "2026-11-05T12:30:00Z"), turn(3, at: "2026-11-05T12:40:00Z")]
        await m.refreshNow()
        try await waitUntil { m.selectedResponseText == "new#3" }
        #expect(m.selectedSessionKey == "new", "after the island closed, Latest takes over")
    }

    @Test func savedPinMigratesToStayModeAndIsKept() async throws {
        let suite = "PromptRelay93.migrate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(AppModel.SavedSelection(projectPath: "/repo/macos", sessionKey: "old", pinnedAt: nil)),
                     forKey: AppModel.selectionKey)
        let core = FakeCore(projects: [Self.info("/repo", logical: "/repo", sessions: 1, last: "2026-11-05T12:00:00Z"),
                                       Self.info("/repo/macos", logical: "/repo", sessions: 1, last: "2026-11-04T09:00:00Z", enabled: false)])
        show(core)
        core.sessionsByProject["/repo"] = [
            Self.session("new", project: "/repo", logical: "/repo", last: "2026-11-05T12:00:00Z"),
            Self.session("old", provider: "codex", host: "xcode", project: "/repo/macos", logical: "/repo", last: "2026-11-04T09:00:00Z"),
        ]
        core.turnsBySession["new"] = [turn(1)]
        core.turnsBySession["old"] = [turn(1)]
        let (m, board) = model(core, defaults: defaults)
        defer { board.releaseGlobally() }
        #expect(m.staysOnChosenSession, "an existing pin is migrated, not dropped")
        #expect(defaults.bool(forKey: AppModel.staysKey))
        await m.refreshNow()
        #expect(m.selectedProjectPath == "/repo", "the saved `macos` folder is shown under its logical project")
        #expect(m.selectedSessionKey == "old")
        #expect(m.sessionPinned)

        let fresh = try #require(UserDefaults(suiteName: suite + ".fresh"))
        defer { fresh.removePersistentDomain(forName: suite + ".fresh") }
        let (n, board2) = model(core, defaults: fresh)
        defer { board2.releaseGlobally() }
        #expect(!n.staysOnChosenSession)
    }

    // MARK: E. Persistent Handoff is never taken away by a newer answer

    @Test func unfinishedHandoffHoldsTheReportUntilDone() async throws {
        let core = FakeCore(projects: [Self.info("/repo", sessions: 2, last: "2026-11-05T12:00:00Z")])
        show(core)
        core.sessionsByProject["/repo"] = [Self.session("a", project: "/repo", last: "2026-11-05T12:00:00Z")]
        core.turnsBySession["a"] = [turn(1)]
        let (m, board) = model(core)
        defer { board.releaseGlobally() }
        await m.refreshNow()
        try await waitUntil { m.selectedResponseText == "a#1" }
        let ref = ReportRef.local(sessionKey: "a", turn: 1)
        // Copy with Context put the text on the clipboard; files are still to transfer.
        m.handoffs[ref.key] = AppModel.HandoffStep(ref: ref, text: "pack", attachmentIDs: ["x"], textChangeCount: 1)
        m.surfaceAppeared()
        m.surfaceDisappeared()   // the user switches to the other AI

        core.sessionsByProject["/repo"] = [
            Self.session("b", provider: "codex", host: "xcode", project: "/repo", last: "2026-11-05T12:10:00Z"),
            Self.session("a", project: "/repo", last: "2026-11-05T12:00:00Z"),
        ]
        core.turnsBySession["b"] = [turn(1)]
        await m.refreshNow()
        #expect(m.currentRef == ref, "the report with the unfinished transfer stays")
        #expect(m.activeHandoff?.attachmentIDs == ["x"], "the transfer is there on return, no Details visit")
        #expect(m.newAnswerElsewhere?.sessionKey == "b", "the newer answer is announced")
        m.surfaceAppeared()
        m.surfaceDisappeared()
        #expect(m.currentRef == ref, "closing again does not drop it either")

        m.handoffs[ref.key] = nil   // Done
        m.surfaceAppeared()
        m.surfaceDisappeared()
        try await waitUntil { m.selectedSessionKey == "b" }
        #expect(m.currentRef == .local(sessionKey: "b", turn: 1), "after Done, Follow Latest resumes")
    }

    // MARK: F/G. One logical project; history kept

    @Test func nestedFolderSessionsShareTheLogicalProject() async throws {
        let core = FakeCore(projects: [
            Self.info("/repo", logical: "/repo", sessions: 2, last: "2026-11-05T12:00:00Z"),
            Self.info("/repo/macos", logical: "/repo", sessions: 2, last: "2026-11-05T12:10:00Z", enabled: false),
            Self.info("/repo/acceptance/smoke", sessions: 1, last: "2026-11-05T09:00:00Z"),
            Self.info("/other/macos", logical: "/other", sessions: 1, last: "2026-11-05T08:00:00Z"),
        ])
        show(core)
        let smoke = Self.session("smoke", provider: "codex", host: "xcode", project: "/repo/acceptance/smoke",
                                 last: "2026-11-05T09:00:00Z")
        core.sessionsByProject["/repo"] = [
            Self.session("codex", provider: "codex", host: "xcode", project: "/repo/macos", logical: "/repo", last: "2026-11-05T12:10:00Z"),
            Self.session("claude", provider: "claude_code", host: "claude_desktop", project: "/repo", logical: "/repo", last: "2026-11-05T12:00:00Z"),
            smoke,   // the real Core matches by prefix; a nested project of its own is filtered out
        ]
        core.sessionsByProject["/repo/acceptance/smoke"] = [smoke]
        core.sessionsByProject["/other"] = [Self.session("elsewhere", project: "/other/macos", logical: "/other", last: "2026-11-05T08:00:00Z")]
        for key in ["codex", "claude", "smoke", "elsewhere"] { core.turnsBySession[key] = [turn(1)] }
        let (m, board) = model(core)
        defer { board.releaseGlobally() }
        await m.refreshNow()
        let paths = m.projects.value?.compactMap(\.path) ?? []
        #expect(paths.contains("/repo") && !paths.contains("/repo/macos"), "no duplicate `macos` project")
        #expect(paths.contains("/other"), "a same-named folder in another repository stays separate")
        #expect(paths.contains("/repo/acceptance/smoke"))
        let repo = try #require(m.projects.value?.first { $0.path == "/repo" })
        #expect(repo.sessionCount == 4 && Set(repo.memberPaths) == ["/repo", "/repo/macos"])
        #expect(m.projectRows.contains { $0.path == "/repo/macos" }, "capture rows stay per folder")

        m.selectProject("/repo")
        try await waitUntil { m.sessions.value != nil }
        #expect(Set(m.sessions.value?.map(\.sessionKey) ?? []) == ["codex", "claude"])
        let groups = m.sessionsByProject
        let group = try #require(groups.first { $0.project == "/repo" })
        #expect(group.sessions.map(\.sessionKey) == ["codex", "claude"], "newest first, both providers, one project")
        #expect(group.sessions.map(\.sourceLabel) == ["Codex · Xcode · This Mac", "Claude Code · Claude Desktop · This Mac"])
        #expect(groups.contains { $0.project == "/repo/acceptance/smoke" })
        #expect(groups.first { $0.project == "/repo" }?.sessions.contains { $0.sessionKey == "codex" } == true)
        // Old Claude sessions without source or logical project still show (G).
        #expect(Self.session("legacy", project: "/repo", last: "x").sourceLabel == "Claude Code · Unknown · This Mac")
    }

    // MARK: H. Indicator and errors

    @Test func captureErrorIsAWarningNotAReadyDot() async {
        let core = FakeCore(projects: [])
        core.projectsResult = .failure(.api(code: "internal_error", message: "boom"))
        let (m, board) = model(core)
        defer { board.releaseGlobally() }
        await m.refreshNow()
        #expect(m.readyIndicator == .attention)
    }

    // MARK: D. Smart attachments from a nested working folder

    private func resultShow(repo: URL, cwd: URL, requestAt: Date) throws -> ShowData {
        let observed: [String: Any] = ["commands": [], "files_changed": [["path": repo.appendingPathComponent("docs/REPORT.md").path,
                                                                           "tools": ["Write"], "count": 1]],
                                       "shown_files": [], "artifacts": [], "notifications": 0]
        let answer = "Wrote docs/REPORT.md and rendered shot.png, old.png. See also .env and source.swift."
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func text(_ value: String, at: Date) -> [String: Any] {
            ["text": value, "preview": value, "truncated": false, "char_count": value.count, "utf8_bytes": value.utf8.count,
             "prompt_id": "t", "received_at": iso.string(from: at)]
        }
        let session: [String: Any] = ["session_id": "c", "session_key": "codex-nested", "project": ["path": cwd.path, "name": "macos"],
                                      "logical_project": ["path": repo.path, "name": repo.lastPathComponent, "basis": "git_root"],
                                      "first_event_at": "2026-11-05T10:00:00Z", "last_event_at": "2026-11-05T10:01:00Z",
                                      "event_count": 3, "turn_count": 1, "cwds": [cwd.path], "last_turn": ["index": 1, "status": "stop_received"],
                                      "integrity": ["corrupt_lines": 0, "unsupported_lines": 0, "foreign_lines": 0],
                                      "source": ["provider": "codex", "host": "xcode", "capture": "hooks", "capabilities": ["prompt"]]]
        let turn: [String: Any] = ["index": 1, "status": "stop_received", "link": "prompt_id", "request": text("Make a report", at: requestAt),
                                   "final_response": text(answer, at: Date()), "response_event_count": 1,
                                   "candidate_request_turns": [], "observed_detail": observed]
        return try JSONDecoder().decode(ShowData.self, from: JSONSerialization.data(withJSONObject: ["session": session, "turn": turn]))
    }

    @Test func observedAndVerifiedNamedResultsAreAutoSelectedOthersAreNot() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("pr93-" + UUID().uuidString)
        let cwd = repo.appendingPathComponent("macos")
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let old = repo.appendingPathComponent("macos/old.png")
        try TypedAttachmentTests.png(.blue).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: old.path)
        let requestAt = Date(timeIntervalSinceNow: -60)
        try Data("# Report\nrelay".utf8).write(to: repo.appendingPathComponent("docs/REPORT.md"))
        try TypedAttachmentTests.png(.red).write(to: cwd.appendingPathComponent("shot.png"))   // made by a shell command this turn
        try Data("SECRET=1".utf8).write(to: cwd.appendingPathComponent(".env"))
        try Data("let x = 1".utf8).write(to: cwd.appendingPathComponent("source.swift"))
        let data = try resultShow(repo: repo, cwd: cwd, requestAt: requestAt)
        let store = ReportStore(root: repo.appendingPathComponent("store-data"))
        let ref = ReportRef.local(sessionKey: "codex-nested", turn: 1)

        #expect(try store.prepareResults(data) == 2)
        let prepared = store.attachments(for: ref)
        #expect(Set(prepared.map(\.originalFilename)) == ["REPORT.md", "shot.png"])
        #expect(prepared.allSatisfy { $0.isSelected })
        let report = try #require(prepared.first { $0.originalFilename == "REPORT.md" })
        let shot = try #require(prepared.first { $0.originalFilename == "shot.png" })
        #expect(report.effectiveSource == .agentResult, "observed write: confirmed")
        #expect(shot.effectiveSource == .namedVerified, "named and changed this turn; not called created by the agent")
        #expect(!ReviewPack.origin(shot).contains("created"))

        // The user excludes the PNG: it never comes back by itself.
        try store.setSelected(shot.id, false)
        #expect(try store.prepareResults(data) == 0)
        let restarted = ReportStore(root: store.root)
        #expect(try restarted.prepareResults(data) == 0)
        #expect(restarted.attachments(for: ref).first { $0.originalFilename == "shot.png" }?.isSelected == false)
        #expect(restarted.attachments(for: ref).first { $0.originalFilename == "REPORT.md" }?.isSelected == true)
    }

    @Test func namedFilesWithoutATurnWindowAreOnlyOffered() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("pr93-" + UUID().uuidString)
        let cwd = repo.appendingPathComponent("macos")
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try TypedAttachmentTests.png(.red).write(to: cwd.appendingPathComponent("shot.png"))
        let shot = cwd.appendingPathComponent("shot.png").path
        #expect(ResultAttachments.read(path: shot, root: repo.path, remaining: 1 << 20, modifiedAfter: Date(timeIntervalSinceNow: 3600)) == nil,
                "a file older than the turn is not picked")
        #expect(ResultAttachments.read(path: shot, root: repo.path, remaining: 1 << 20, modifiedAfter: Date(timeIntervalSinceNow: -3600)) != nil)
        #expect(ResultAttachments.read(path: repo.appendingPathComponent("../escape.png").path, root: repo.path, remaining: 1 << 20) == nil)
    }

    // MARK: Task continuation

    @Test func continuationKeepsTheRequestAndShowsTheEarlierTask() throws {
        let turn = try JSONDecoder().decode(Turn.self, from: Data("""
        {"index":2,"status":"stop_received","link":"prompt_id",
         "request":{"preview":"продолжи где остановился","truncated":false,"char_count":24,"utf8_bytes":45,"prompt_id":"p2","received_at":"2026-11-05T10:00:00Z","text":"продолжи где остановился"},
         "final_response":null,"response_event_count":1,"background_tasks":null,"error":null,"candidate_request_turns":[],
         "continues_request":{"turn":1,"preview":"Перенеси экспорт","truncated":false,"char_count":16,"utf8_bytes":30,"prompt_id":"p1","received_at":"2026-11-05T09:00:00Z","text":"Перенеси экспорт в модуль"}}
        """.utf8))
        let task = FullTask.local(request: turn.request, fullText: turn.request?.text, requestOrigin: .user, link: .promptID,
                                  earlier: nil, continues: turn.continuesRequest, continuesText: turn.continuesRequest?.text)
        #expect(task.original == "продолжи где остановился", "the exact request stays the task")
        #expect(task.continued?.turn == 1)
        #expect(task.continued?.text == "Перенеси экспорт в модуль")
        #expect(task.notes.contains { $0.contains("short continuation") })
        #expect(task.canCopy)
    }
}
