import AppKit
import Foundation
import Testing
@testable import PromptRelayKit

/// Phase 17: result files are attached and selected when the final answer
/// arrives — no Add. Real temporary files and a real `ReportStore`; the Core
/// is a double (its `show` output is built here).
@Suite(.serialized)
@MainActor
struct Phase17AttachmentTests {
    nonisolated static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// A project folder with a store beside it (outside the project).
    @MainActor final class Project {
        let base: URL
        let root: URL
        let store: ReportStore
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("pr17-" + UUID().uuidString).resolvingSymlinksInPath()
            root = base.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = ReportStore(root: base.appendingPathComponent("store"))
        }

        @discardableResult
        func write(_ relative: String, _ data: Data, modified: Date? = nil, in folder: URL? = nil) throws -> URL {
            let url = (folder ?? root).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
            return url
        }
        @discardableResult
        func write(_ relative: String, _ text: String, modified: Date? = nil, in folder: URL? = nil) throws -> URL {
            try write(relative, Data(text.utf8), modified: modified, in: folder)
        }
    }

    static let schema = #"{"$schema":"https://json-schema.org/draft/2020-12/schema","title":"BearlyCopy JSON API v1","type":"object"}"#
    static let longAgo = Date(timeIntervalSinceNow: -30 * 86_400)

    /// The Core's `show` for one final answer. `written`: files a tool was
    /// seen writing; `shown`: files the agent sent to the user.
    static func show(_ project: Project, cwd: URL? = nil, session: String = "s17", turn index: Int = 1, answer: String,
                     written: [URL] = [], shown: [URL] = [], requestAt: Date = Date(timeIntervalSinceNow: -120),
                     answeredAt: Date = Date(timeIntervalSinceNow: 1)) throws -> ShowData {
        let cwd = cwd ?? project.root
        let observed: [String: Any] = ["commands": [], "files_changed": written.map { ["path": $0.path, "tools": ["Write"], "count": 1] as [String: Any] },
                                       "shown_files": shown.map(\.path), "artifacts": [], "notifications": 0]
        func text(_ value: String, at: Date) -> [String: Any] {
            ["text": value, "preview": value, "truncated": false, "char_count": value.count, "utf8_bytes": value.utf8.count,
             "prompt_id": "p\(index)", "received_at": iso(at)]
        }
        let sessionJSON: [String: Any] = [
            "session_id": session, "session_key": session, "project": ["path": cwd.path, "name": cwd.lastPathComponent],
            "logical_project": ["path": cwd.path, "name": cwd.lastPathComponent, "basis": "git_root"],
            "first_event_at": iso(requestAt), "last_event_at": iso(answeredAt), "event_count": 3, "turn_count": index, "cwds": [cwd.path],
            "last_turn": ["index": index, "status": "stop_received", "completion": "answer", "answered_at": iso(answeredAt)],
            "integrity": ["corrupt_lines": 0, "unsupported_lines": 0, "foreign_lines": 0], "answered_count": index,
            "source": ["provider": "claude_code", "host": "desktop", "capture": "hooks", "capabilities": ["prompt", "final_response"]]]
        let turnJSON: [String: Any] = ["index": index, "status": "stop_received", "link": "prompt_id", "completion": "answer",
                                       "request": text("Do the task", at: requestAt), "final_response": text(answer, at: answeredAt),
                                       "response_event_count": 1, "candidate_request_turns": [], "observed_detail": observed]
        return try JSONDecoder().decode(ShowData.self, from: JSONSerialization.data(withJSONObject: ["session": sessionJSON, "turn": turnJSON]))
    }

    static func model(_ shows: [ShowData], store: ReportStore, defaults: MemorySettingsStore? = nil) async -> (AppModel, FakeCore) {
        let core = FakeCore(projects: [])
        var byProject: [String: [SessionSummary]] = [:]
        for data in shows {
            byProject[data.session.project.path ?? "", default: []].append(data.session)
            core.turnsBySession[data.session.sessionKey] = [data.turn]
        }
        core.sessionsByProject = byProject
        core.projectsList = byProject.map { project($0.key, sessions: $0.value.count, last: $0.value.first?.lastEventAt) }
        core.showResult = { key, i in
            shows.first { $0.session.sessionKey == key && $0.turn.index == i }.map { .success(CoreResult(data: $0, warnings: [])) }
                ?? .failure(.api(code: "not_found", message: "none"))
        }
        let board = NSPasteboard(name: .init("PromptRelay17A-\(UUID().uuidString)"))
        let model = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil,
                             stateDefaults: defaults, reportStore: store)
        await model.refreshNow()
        await model.arrivalPreparationSettled()
        return (model, core)
    }

    static func ref(_ data: ShowData) -> ReportRef { .local(sessionKey: data.session.sessionKey, turn: data.turn.index) }

    // MARK: The owner's case

    /// `api-v1.schema.json`, named in the final answer and present in the
    /// project, stayed under "From this turn" with an Add button: `.json`
    /// was not a prepared type, and a file not changed in the turn was only
    /// ever offered.
    @Test func theSchemaNamedInTheAnswerIsAttachedAndSelectedWithoutAdd() async throws {
        let p = try Project()
        let file = try p.write("docs/api/api-v1.schema.json", Self.schema, modified: Self.longAgo)
        let data = try Self.show(p, answer: "The contract is in docs/api/api-v1.schema.json — it already includes settings.capture.")
        let (model, _) = await Self.model([data], store: p.store)
        let attached = p.store.attachments(for: Self.ref(data))
        #expect(attached.map(\.originalFilename) == ["api-v1.schema.json"])
        let schema = try #require(attached.first)
        #expect(schema.isSelected, "selected for Copy with Context and drag")
        #expect(schema.autoPrepared == true && schema.effectiveSource == .named)
        #expect(schema.originalPath == "docs/api/api-v1.schema.json")
        #expect(schema.effectiveKind == .document)
        #expect(try Data(contentsOf: #require(p.store.fileURL(for: schema))) == Data(contentsOf: file), "the repository's bytes, verbatim")
        #expect(model.suggestions.isEmpty, "nothing left to Add")
        #expect(model.materialSummary(for: model.currentRef).documents == 1)
        // Provenance: named, never "written by the agent".
        #expect(AppModel.attachmentStatus(schema) == "Attached automatically · named in the answer, not seen written")
        #expect(schema.provenance.contains("Named in the answer") && schema.provenance.contains("not seen being written"))
        #expect(!ReviewPack.origin(schema).lowercased().contains("created"))
    }

    @Test func writtenAndNamedIsAnObservedResultAndDeliveredFilesToo() async throws {
        let p = try Project()
        let written = try p.write("out/schema.json", Self.schema)
        let sent = try p.write("out/summary.md", "# Summary")
        let data = try Self.show(p, answer: "Wrote out/schema.json.", written: [written], shown: [sent])
        _ = await Self.model([data], store: p.store)
        let attached = p.store.attachments(for: Self.ref(data))
        #expect(Set(attached.map(\.originalFilename)) == ["schema.json", "summary.md"])
        #expect(attached.allSatisfy { $0.effectiveSource == .agentResult && $0.isSelected && $0.autoPrepared == true })
        #expect(attached.allSatisfy { AppModel.attachmentStatus($0) == "Attached automatically · written this turn" })
    }

    @Test func jsonMarkdownHTMLPDFAndImagesArePrepared() async throws {
        let p = try Project()
        try p.write("a.json", Self.schema)
        try p.write("b.md", "# Report")
        try p.write("c.html", "<!doctype html><title>Report</title>")
        try p.write("d.pdf", TypedAttachmentTests.pdf())
        try p.write("e.png", TypedAttachmentTests.png(.red))
        try p.write("f.csv", "a,b\n1,2\n")
        let data = try Self.show(p, answer: "Results: a.json, b.md, c.html, d.pdf, e.png and f.csv.")
        _ = await Self.model([data], store: p.store)
        let attached = p.store.attachments(for: Self.ref(data))
        #expect(Set(attached.map(\.originalFilename)) == ["a.json", "b.md", "c.html", "d.pdf", "e.png", "f.csv"])
        #expect(attached.first { $0.originalFilename == "d.pdf" }?.effectiveKind == .pdf)
        #expect(attached.first { $0.originalFilename == "e.png" }?.effectiveKind == .image)
        #expect(attached.allSatisfy { $0.effectiveSource == .namedVerified }, "changed during the turn: named and verified locally")
    }

    // MARK: Identity

    @Test func sameNameInTwoFoldersStaysTwoFilesAndIdenticalBytesStayOne() async throws {
        let p = try Project()
        try p.write("api/report.md", "# API")
        try p.write("ui/report.md", "# UI")
        try p.write("copy/one.json", Self.schema)
        try p.write("copy/two.json", Self.schema)
        let data = try Self.show(p, answer: "See api/report.md, ui/report.md, copy/one.json and copy/two.json.")
        let (model, _) = await Self.model([data], store: p.store)
        let attached = p.store.attachments(for: Self.ref(data))
        #expect(attached.filter { $0.originalFilename == "report.md" }.compactMap(\.originalPath).sorted() == ["api/report.md", "ui/report.md"])
        #expect(attached.filter { $0.sha256 == ReportStore.sha256(Data(Self.schema.utf8)) }.count == 1, "identical bytes: one record, one export item")
        #expect(attached.count == 3)
        #expect(model.suggestions.isEmpty, "the second path of the same bytes is not offered again")
        #expect(Set(attached.map(\.id)).count == attached.count && Set(attached.map(\.storedFilename)).count == attached.count)
    }

    /// The same file name in two worktrees: only the answer's own worktree
    /// is read, and nothing outside it — not by `..`, not by a symlink.
    @Test func neverCrossesIntoAnotherWorktreeOrOutOfTheProject() async throws {
        let p = try Project()
        let other = p.base.appendingPathComponent("repo-other-worktree")
        try p.write("notes.md", "# OTHER worktree", in: other)
        try p.write("notes.md", "# this worktree")
        try p.write("outside.md", "# outside", in: p.base)
        try FileManager.default.createSymbolicLink(at: p.root.appendingPathComponent("link.md"), withDestinationURL: other.appendingPathComponent("notes.md"))
        try FileManager.default.createSymbolicLink(at: p.root.appendingPathComponent("linked"), withDestinationURL: other)
        let data = try Self.show(p, answer: "See notes.md, ../outside.md, \(other.path)/notes.md, link.md and linked/notes.md.")
        _ = await Self.model([data], store: p.store)
        let attached = p.store.attachments(for: Self.ref(data))
        #expect(attached.count == 1)
        let only = try #require(attached.first)
        #expect(try String(contentsOf: #require(p.store.fileURL(for: only)), encoding: .utf8) == "# this worktree")
        for path in ["../outside.md", other.path + "/notes.md", "link.md", "linked/notes.md"] {
            #expect(ResultAttachments.load(path: path, root: p.root.path, remaining: 1 << 20) == .failure(.init(skip: .outsideProject)), "\(path)")
        }
    }

    // MARK: Safety

    @Test func sensitiveFilesAreNeverPreparedAndSaySo() async throws {
        let p = try Project()
        let env = try p.write(".env", "API_KEY=abcdefgh12345678")
        let creds = try p.write("credentials.json", #"{"user":"x"}"#)
        let leaky = try p.write("config.json", #"{"api_key": "sk-ant-REDACTED"}"#)
        let key = try p.write("deploy/service-account.json", #"{"type":"service_account"}"#)
        let fine = try p.write("ok.json", #"{"ok":true}"#)
        let data = try Self.show(p, answer: "Wrote .env, credentials.json, config.json, deploy/service-account.json and ok.json.",
                                 written: [env, creds, leaky, key, fine])
        let (model, _) = await Self.model([data], store: p.store)
        #expect(p.store.attachments(for: Self.ref(data)).map(\.originalFilename) == ["ok.json"])
        func status(_ name: String) -> String? { model.suggestions.first { $0.title == name }?.statusLine }
        #expect(status("credentials.json") == "Excluded for safety — hidden or credential-like name")
        #expect(status("service-account.json") == "Excluded for safety — hidden or credential-like name")
        #expect(status("config.json") == "Excluded for safety — it seems to contain a secret")
        #expect(model.suggestions.first { $0.title == "config.json" }?.isWarning == true)
        #expect(ResultAttachments.load(path: ".env", root: p.root.path, remaining: 1 << 20) == .failure(.init(skip: .sensitiveName)))
        // Nothing of them was copied anywhere.
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: p.store.root.appendingPathComponent("attachments").path)) ?? []
        #expect(kept.count == 1)
    }

    @Test func missingOversizedAndUnsupportedFilesSayWhy() async throws {
        let p = try Project()
        let gone = p.root.appendingPathComponent("gone.md")
        let big = try p.write("big.json", Data(repeating: UInt8(ascii: "1"), count: ReportStore.maxDocumentBytes + 10))
        let code = try p.write("tool.swift", "let x = 1")
        let empty = try p.write("empty.md", Data())
        let data = try Self.show(p, answer: "Wrote gone.md, big.json, tool.swift and empty.md.", written: [gone, big, code, empty])
        let (model, _) = await Self.model([data], store: p.store)
        #expect(p.store.attachments(for: Self.ref(data)).isEmpty)
        func suggestion(_ name: String) -> AppModel.Suggestion? { model.suggestions.first { $0.title == name } }
        #expect(suggestion("gone.md")?.statusLine.contains("no longer exists") == true)
        #expect(suggestion("gone.md")?.attachable == false)
        #expect(suggestion("big.json")?.statusLine == "Not attachable — too large")
        #expect(suggestion("tool.swift")?.statusLine.hasPrefix("Not attachable") == true)
        #expect(suggestion("empty.md")?.statusLine == "Not attachable — the file is empty")
        #expect(model.attachmentMessage == nil, "skipped files are explained on their rows, not as an error banner")
    }

    @Test func manyNamedExistingFilesAreNotAllAttached() async throws {
        let p = try Project()
        let names = (1...9).map { "doc\($0).md" }
        for name in names { try p.write(name, "# \(name)", modified: Self.longAgo) }
        let data = try Self.show(p, answer: "I read " + names.joined(separator: ", ") + ".")
        let (model, _) = await Self.model([data], store: p.store)
        #expect(p.store.attachments(for: Self.ref(data)).count == ResultAttachments.maxNamedExisting)
        let rest = model.suggestions
        #expect(rest.count == 9 - ResultAttachments.maxNamedExisting)
        #expect(rest.allSatisfy { $0.statusLine.hasPrefix("Named but not verified") && $0.attachable })
        // Add still works for one of them, as the user's own choice.
        #expect(model.accept(try #require(rest.first)) == .added(try #require(rest.first).title))
        #expect(AppModel.attachmentStatus(try #require(p.store.attachments(for: Self.ref(data)).last)) == "Attached by you · named in the answer")
    }

    // MARK: Freshness

    @Test func aFileChangedAfterTheAnswerIsOfferedNotSnapshotted() async throws {
        let p = try Project()
        let file = try p.write("result.json", #"{"v":2}"#)                       // modified now
        let data = try Self.show(p, answer: "Wrote result.json.", written: [file],
                                 requestAt: Date(timeIntervalSinceNow: -3600), answeredAt: Date(timeIntervalSinceNow: -1800))
        let (model, _) = await Self.model([data], store: p.store)
        #expect(p.store.attachments(for: Self.ref(data)).isEmpty, "newer bytes are never passed off as the answer's")
        let suggestion = try #require(model.suggestions.first)
        #expect(suggestion.statusLine == "Not attached automatically — changed after this answer — Add takes the current version")
        #expect(suggestion.attachable)
    }

    @Test func aSnapshotKeepsTheAnswersBytesAndSaysWhenTheOriginalChanged() async throws {
        let p = try Project()
        let file = try p.write("result.json", #"{"v":1}"#)
        let data = try Self.show(p, answer: "Wrote result.json.", written: [file])
        let (model, _) = await Self.model([data], store: p.store)
        let snapshot = try #require(p.store.attachments(for: Self.ref(data)).first)
        #expect(snapshot.sha256 == ReportStore.sha256(Data(#"{"v":1}"#.utf8)))
        #expect(Wording.date(snapshot.addedAt) != nil, "capture time recorded")
        #expect(model.snapshotDrift(snapshot) == .same)
        try p.write("result.json", #"{"v":2,"later":true}"#)                    // later work changes the original
        #expect(model.snapshotDrift(snapshot) == .changed)
        #expect(try Data(contentsOf: #require(p.store.fileURL(for: snapshot))) == Data(#"{"v":1}"#.utf8), "the hand-off still carries the snapshot")
        #expect(p.store.data(for: snapshot) == Data(#"{"v":1}"#.utf8))
        await model.refreshNow()
        #expect(p.store.attachments(for: Self.ref(data)).count == 1, "and a refresh does not swap in the newer bytes")
        try FileManager.default.removeItem(at: file)
        #expect(model.snapshotDrift(snapshot) == .missing)
    }

    /// Two conversations finish while another report is shown: both get
    /// their files snapshotted at arrival, not when first opened.
    @Test func everyNewFinalIsPreparedOnArrivalNotOnlyTheOneShown() async throws {
        let p = try Project()
        let first = try p.write("first.md", "# first")
        let a = try Self.show(p, session: "a", answer: "Wrote first.md.", written: [first])
        let (model, core) = await Self.model([a], store: p.store)
        model.clock = Date.init
        // The user pins conversation a; b and c finish elsewhere.
        model.stayOnThisConversation()
        let other = p.base.appendingPathComponent("other-project")
        let bFile = try p.write("b.json", #"{"b":1}"#, in: other)
        let cFile = try p.write("c.md", "# c", in: other)
        let b = try Self.show(p, cwd: other, session: "b", answer: "Wrote b.json.", written: [bFile], answeredAt: Date(timeIntervalSinceNow: 2))
        let c = try Self.show(p, cwd: other, session: "c", answer: "Wrote c.md.", written: [cFile], answeredAt: Date(timeIntervalSinceNow: 3))
        core.sessionsByProject[other.path] = [c.session, b.session]
        core.turnsBySession["b"] = [b.turn]; core.turnsBySession["c"] = [c.turn]
        core.projectsList.append(project(other.path, sessions: 2, last: c.session.lastEventAt))
        let all = [a, b, c]
        core.showResult = { key, i in .success(CoreResult(data: all.first { $0.session.sessionKey == key && $0.turn.index == i }!, warnings: [])) }
        await model.refreshNow()
        await model.arrivalPreparationSettled()
        #expect(model.selectedSessionKey == "a", "still on the pinned conversation")
        #expect(p.store.attachments(for: Self.ref(b)).map(\.originalFilename) == ["b.json"])
        #expect(p.store.attachments(for: Self.ref(c)).map(\.originalFilename) == ["c.md"])
        // Later work rewrites b.json before b is ever opened: the snapshot is the answer's.
        try p.write("b.json", #"{"b":2}"#, in: other)
        let kept = try #require(p.store.attachments(for: Self.ref(b)).first)
        #expect(p.store.data(for: kept) == Data(#"{"b":1}"#.utf8))
    }

    // MARK: The user's choices, repeats, restarts

    @Test func deselectionRemovalRepeatedStopsAndRestartsNeverUndoTheUsersChoice() async throws {
        let p = try Project()
        let keep = try p.write("keep.md", "# keep"), drop = try p.write("drop.json", #"{"d":1}"#), remove = try p.write("remove.md", "# remove")
        let data = try Self.show(p, answer: "Wrote keep.md, drop.json and remove.md.", written: [keep, drop, remove])
        let (model, _) = await Self.model([data], store: p.store)
        let ref = Self.ref(data)
        #expect(p.store.attachments(for: ref).count == 3)
        try p.store.setSelected(#require(p.store.attachments(for: ref).first { $0.originalFilename == "drop.json" }).id, false)
        try p.store.removeAttachment(#require(p.store.attachments(for: ref).first { $0.originalFilename == "remove.md" }).id)
        // The same Stop delivered again, refreshes, and the answer reloaded.
        for _ in 1...3 {
            #expect(try p.store.prepareResults(data) == 0)
            await model.refreshNow()
            await model.arrivalPreparationSettled()
        }
        func state(_ store: ReportStore) -> [String: Bool] {
            Dictionary(uniqueKeysWithValues: store.attachments(for: ref).map { ($0.originalFilename, $0.isSelected) })
        }
        #expect(state(p.store) == ["keep.md": true, "drop.json": false])
        // Restart: a new store and a new model over the same folder.
        let restarted = ReportStore(root: p.store.root)
        let (again, _) = await Self.model([data], store: restarted)
        #expect(state(restarted) == ["keep.md": true, "drop.json": false], "deselected stays deselected, removed stays removed")
        #expect(again.suggestions.map(\.title) == ["remove.md"], "the removed file is offered again, never re-added by itself")
        #expect(restarted.attachments(for: ref).allSatisfy { $0.autoPrepared == true })
    }

    /// Two copies of the app (or the arrival task and the report being
    /// opened) prepare the same answer: one record per file.
    @Test func concurrentPreparationOfOneAnswerKeepsOneRecordPerFile() async throws {
        let p = try Project()
        let files = try (1...4).map { try p.write("r\($0).json", #"{"n":\#($0)}"#) }
        let data = try Self.show(p, answer: "Wrote r1.json, r2.json, r3.json and r4.json.", written: files)
        let one = p.store, two = ReportStore(root: p.store.root)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<12 {
                group.addTask { @MainActor in
                    await Task.yield()
                    _ = try? (i.isMultiple(of: 2) ? one : two).prepareResults(data)
                }
            }
        }
        let fresh = ReportStore(root: p.store.root)
        let attached = fresh.attachments(for: Self.ref(data))
        #expect(attached.map(\.originalFilename).sorted() == ["r1.json", "r2.json", "r3.json", "r4.json"])
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: p.store.root.appendingPathComponent("attachments").path)
        #expect(onDisk.filter { $0.hasSuffix(".json") && $0 != "index.json" }.count == 4, "no orphan copies")
    }

    // MARK: Settings

    @Test func preparationAndSelectionFollowTheirSettings() async throws {
        let p = try Project()
        let file = try p.write("a.json", Self.schema)
        let data = try Self.show(p, answer: "Wrote a.json.", written: [file])
        // Prepared but not ticked.
        let unticked = MemorySettingsStore(["attachments.autoSelectPrepared": false])
        let (m1, _) = await Self.model([data], store: p.store, defaults: unticked)
        #expect(!m1.autoSelectPreparedAttachments && m1.autoSelectResultAttachments)
        #expect(p.store.attachments(for: Self.ref(data)).map(\.isSelected) == [false])
        #expect(m1.materialSummary(for: m1.currentRef).isEmpty)
        // Preparation off: nothing is copied; the file is offered.
        let q = try Project()
        let qFile = try q.write("a.json", Self.schema)
        let qData = try Self.show(q, answer: "Wrote a.json.", written: [qFile])
        let off = MemorySettingsStore(["attachments.autoSelectResults": false])
        let (m2, _) = await Self.model([qData], store: q.store, defaults: off)
        #expect(q.store.attachments(for: Self.ref(qData)).isEmpty)
        #expect(m2.suggestions.map(\.title) == ["a.json"])
        #expect(m2.suggestions.first?.statusLine.hasSuffix("not attached yet") == true)
    }
}
