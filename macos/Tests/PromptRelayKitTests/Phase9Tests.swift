import AppKit
import Foundation
import Testing
@testable import PromptRelayKit

@Suite(.serialized)
@MainActor
struct Phase9Tests {
    private func show(root: URL, provider: String = "codex", key: String = "codex-session") throws -> ShowData {
        let names = ["REPORT.md", "PHASE9.md", "notes.txt", "one.png", "two.png", "source.swift", ".env", "missing.pdf"]
        let observed: [String: Any] = ["commands": [], "files_changed": names.map { ["path": root.appendingPathComponent($0).path, "tools": ["Write"], "count": 1] as [String: Any] }, "shown_files": [], "artifacts": [], "notifications": 0]
        let answer = names.joined(separator: "\n") + "\nhttps://claude.ai/artifacts/private.pdf"
        let source: [String: Any] = ["provider": provider, "host": "xcode", "native_session_id": "same-native", "installation_id": "test", "capabilities": ["prompt", "final_response", "tools", "file_changes"], "capture": "hooks"]
        let session: [String: Any] = ["session_id": "same-native", "session_key": key, "project": ["path": root.path, "name": "Project"], "first_event_at": "2026-11-03T10:00:00Z", "last_event_at": "2026-11-03T10:01:00Z", "event_count": 2, "turn_count": 1, "cwds": [root.path], "last_turn": ["index": 1, "status": "stop_received"], "integrity": ["corrupt_lines": 0, "unsupported_lines": 0, "foreign_lines": 0], "source": source]
        func text(_ value: String) -> [String: Any] { ["text": value, "preview": value, "truncated": false, "char_count": value.count, "utf8_bytes": value.utf8.count, "prompt_id": "native-turn", "received_at": "2026-11-03T10:01:00Z"] }
        let turn: [String: Any] = ["index": 1, "status": "stop_received", "link": "prompt_id", "request": text("Full original task"), "final_response": text(answer), "response_event_count": 1, "candidate_request_turns": [], "observed_detail": observed]
        return try JSONDecoder().decode(ShowData.self, from: JSONSerialization.data(withJSONObject: ["session": session, "turn": turn]))
    }

    private func files(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["REPORT.md", "PHASE9.md", "notes.txt", "source.swift", ".env"] {
            try Data(("Content for " + name).utf8).write(to: root.appendingPathComponent(name))
        }
        try TypedAttachmentTests.png(.red).write(to: root.appendingPathComponent("one.png"))
        try TypedAttachmentTests.png(.blue).write(to: root.appendingPathComponent("two.png"))
    }

    @Test func automaticallyPreparesFiveAndPreservesUserSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try files(root)
        let data = try show(root: root)
        let ref = ReportRef.local(sessionKey: data.session.sessionKey, turn: 1)
        let store = ReportStore(root: root.appendingPathComponent("store"))
        #expect(try store.prepareResults(data) == 5)
        let attachments = store.attachments(for: ref)
        #expect(attachments.count == 5 && attachments.allSatisfy(\.isSelected))
        let first = try #require(attachments.first)
        try store.setSelected(first.id, false)
        #expect(try store.prepareResults(data) == 0)
        #expect(store.attachments(for: ref).filter(\.isSelected).count == 4)
        let restarted = ReportStore(root: store.root)
        #expect(try restarted.prepareResults(data) == 0)
        #expect(restarted.attachments(for: ref).filter(\.isSelected).count == 4)
        try restarted.removeAttachment(first.id)
        #expect(try restarted.prepareResults(data) == 0)
        #expect(restarted.attachments(for: ref).count == 4)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(first.originalFilename).path))
        #expect(store.attachments(for: .local(sessionKey: "other", turn: 1)).isEmpty)
    }

    @Test func sensitiveUnavailableSymlinkAndOutsidePathsAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try files(root)
        let link = root.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("REPORT.md"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: root)
        for path in [link.path, "linked/REPORT.md", ".env", "missing.pdf", "../outside.md", "https://private.example/report.pdf", "source.swift"] {
            #expect(ResultAttachments.read(path: path, root: root.path, remaining: 10000) == nil, "Rejected: \(path)")
        }
        #expect(ResultAttachments.read(path: "REPORT.md", root: root.path, remaining: 1) == nil)
        let secret = root.appendingPathComponent("credentials.md")
        try Data("private".utf8).write(to: secret)
        #expect(ResultAttachments.read(path: secret.path, root: root.path, remaining: 10000) == nil)
    }

    @Test func snapshotAndQuickPeekHandoffUseSameSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        try files(root)
        let data = try show(root: root)
        let core = FakeCore(projects: [project(root.path, sessions: 1, last: data.session.lastEventAt)])
        core.sessionsByProject[root.path] = [data.session]
        core.turnsBySession[data.session.sessionKey] = [data.turn]
        core.showResult = { _, _ in .success(CoreResult(data: data, warnings: [])) }
        let context = ContextData(session: data.session, turn: data.turn, exportedAt: "now", text: "# Copy with Context\nCodex · Xcode\nFull original task\n" + (data.turn.finalResponse?.text ?? ""), sensitiveFindings: [], git: GitSummary(available: false, reason: "fixture", branch: nil, head: nil, changedFileCount: 0, changedFilesTruncated: false))
        core.contextResult = .success(CoreResult(data: context, warnings: []))
        let store = ReportStore(root: root.appendingPathComponent("store"))
        let model = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, reportStore: store)
        await model.refreshNow()
        #expect(model.currentSourceLabel == "Codex · Xcode · This Mac")
        let ref = try #require(model.currentRef)
        #expect(model.attachments(for: ref).count == 5)
        let first = try #require(model.attachments(for: ref).first)
        model.setSelected(first, false)
        for (name, color) in [("clip1.png", NSColor.green), ("clip2.png", NSColor.yellow)] {
            try store.addData(TypedAttachmentTests.png(color), name: name, to: ref, source: .clipboard)
        }
        model.attachmentsVersion += 1
        await model.copySelectedContext() // same entry point as Quick Peek; no Details navigation
        #expect(model.activeHandoff?.fileCount == 6)
        let snapshot = try #require(model.activeHandoff?.text)
        model.suspendHandoffs()
        #expect(model.activeHandoff?.text == snapshot)
        let restarted = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, reportStore: ReportStore(root: store.root))
        await restarted.refreshNow()
        #expect(restarted.activeHandoff?.text == snapshot)
        await model.openPackPreview()
        guard case .ready(let preview)? = model.packPreview else { Issue.record("Missing preview"); return }
        model.setSelected(first, true)
        try ClipboardService(pasteboard: board).copy("sentinel")
        await model.copyPreviewedPack()
        #expect(board.string(forType: .string) == "sentinel")
        model.setSelected(first, false)
        await model.copyPreviewedPack()
        #expect(board.string(forType: .string) == preview.text)
        try Data("Changed original".utf8).write(to: root.appendingPathComponent("REPORT.md"))
        #expect(try store.prepareResults(data) == 0)
        #expect(model.activeHandoff?.text == snapshot || model.activeHandoff?.text == preview.text)
    }

    @Test func bothAgentsShareHistoryWithoutSwitchingPinnedSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let codex = try show(root: root)
        let claude = try show(root: root, provider: "claude_code", key: "claude-session")
        let core = FakeCore(projects: [project(root.path, sessions: 2, last: codex.session.lastEventAt)])
        core.sessionsByProject[root.path] = [claude.session, codex.session]
        for data in [claude, codex] { core.turnsBySession[data.session.sessionKey] = [data.turn] }
        core.showResult = { key, _ in .success(CoreResult(data: key == "claude-session" ? claude : codex, warnings: [])) }
        let model = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil)
        await model.refreshNow()
        for data in [claude, codex] {
            model.open(.local(sessionKey: data.session.sessionKey, turn: 1))
            await model.refreshNow()
            #expect(model.selectedSessionKey == data.session.sessionKey)
            #expect(model.allSessions.count == 2)
        }
        model.providerFilter = .codex
        #expect(model.sessionsByProject.flatMap(\.sessions).map(\.sessionKey) == [codex.session.sessionKey])
        #expect(sessionSummary("legacy", project: root.path, last: "now").provider == .claudeCode)
    }
}
