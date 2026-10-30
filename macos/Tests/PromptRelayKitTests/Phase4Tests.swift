import AppKit
import CryptoKit
import XCTest
@testable import PromptRelayKit

/// A realistic Claude Code final report: headings, nested lists, a table,
/// TypeScript / Python / JSON / Swift code (with backticks inside), Cyrillic,
/// emoji with skin tones and ZWJ, CRLF, tabs, a long URL and special
/// characters. Deterministic, so tests can compare byte for byte.
enum ReportFixture {
    static func section(_ i: Int) -> String {
        """
        ## \(i). Изменения в модуле `relay-\(i)` 🚀\r
        \r
        Что сделано:\r
        - Добавлен парсер\n  - вложенный пункт с `inline code` и **жирным**\n    - ещё глубже: 👩🏽‍💻 → ✅\n1. Нумерованный пункт\n2. Второй\n
        | Файл | Строк | Статус |
        |---|---:|:---:|
        | `src/a\(i).ts` | \(i * 7) | ✅ |
        | `Sources/B\(i).swift` | 42 | ⚠️ |

        ```typescript
        export function relay\(i)(input: string): string {
          return `${input} → ${"\\u{1F680}"}`; // template literal with ``backticks``
        }
        ```

        ```python
        def relay_\(i)(x: dict) -> str:
            return f"{x!r}\\t«{x.get('ключ', None)}»"
        ```

        ```json
        {"section": \(i), "ok": true, "emoji": "🧪", "escaped": "\\"quoted\\" \\\\ backslash"}
        ```

        ````swift
        let fence = "```"   // a fence inside a fence
        ````

        > Claude сообщает: тесты прошли. (Это утверждение Claude, а не проверка.)

        Ссылка: https://example.com/very/long/path/\(String(repeating: "segment-", count: 12))end?query=%E2%9C%85&x=\(i)
        Спецсимволы: <>&"' \\ \t tab — en–dash … ellipsis © ® ™ ½ ∑ ≠ ≤ 𝔘𝔫𝔦𝔠𝔬𝔡𝔢

        """
    }

    static func report(sections: Int) -> String {
        "# Итоговый отчёт Claude Code\n\nКоротко: всё сделано по ТЗ.\n\n" + (1...sections).map(section).joined()
    }
}

// MARK: - Real Core, long report

/// The real Python Core in a temp data dir: a long report goes through the
/// hook (twice, like a duplicate delivery), the app reads and copies it.
@MainActor
final class LongReportIntegrationTests: XCTestCase {
    func runHook(_ payload: [String: Any], home: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-S", "-B", Repo.cli, "hook"]
        process.environment = ["HOME": NSHomeDirectory(), "PROMPT_RELAY_HOME": home.path, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty, "the hook never writes stdout")
    }

    func testLongReportIsCapturedPreviewedAndCopiedUnchanged() async throws {
        let base = FileManager.default.temporaryDirectory.path.withCString { realpath($0, nil) }.map { String(cString: $0) }!
        let tmp = URL(fileURLWithPath: base).appendingPathComponent("pr-long-\(UUID().uuidString)")
        let project = tmp.appendingPathComponent("project")
        let home = tmp.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let locator = CoreLocator(processEnvironment: ["HOME": NSHomeDirectory(), "PROMPT_RELAY_HOME": home.path, "PROMPT_RELAY_CLI": Repo.cli],
                                  bundleResourceURL: nil, defaults: { _ in nil })
        let core = CoreClient.live(locator: locator)
        _ = try await core.setCapture(true, path: project.path)

        let report = ReportFixture.report(sections: 140)
        XCTAssertGreaterThan(report.count, 100_000)
        let task = "Сделай отчёт по модулю relay и запусти тесты.\nДеталь на второй строке."
        let common: [String: Any] = ["session_id": "long-1", "prompt_id": "pid-long-1", "cwd": project.path,
                                     "transcript_path": "/tmp/x.jsonl", "permission_mode": "default"]
        try runHook(common.merging(["hook_event_name": "UserPromptSubmit", "prompt": task]) { $1 }, home: home)
        let stop = common.merging(["hook_event_name": "Stop", "stop_hook_active": false, "last_assistant_message": report,
                                   "background_tasks": [Any](), "session_crons": [Any]()]) { $1 }
        try runHook(stop, home: home)
        try runHook(stop, home: home)                 // duplicate delivery

        let board = NSPasteboard(name: NSPasteboard.Name("PromptRelayLong-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let model = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil)
        await model.refreshNow()
        let deadline = Date().addingTimeInterval(20)
        while model.selectedResponseText == nil, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }

        XCTAssertEqual(model.turns.value?.count, 1, "the duplicate Stop does not create a second turn")
        XCTAssertEqual(model.selectedTurn?.link, .promptID, "the task is linked by prompt_id")
        XCTAssertEqual(model.selectedTurn?.request?.preview.hasPrefix("Сделай отчёт"), true)
        XCTAssertEqual(model.selectedResponseText, report, "the full text, not the preview")
        XCTAssertLessThan(model.selectedTurn?.finalResponse?.preview.count ?? .max, 300, "the list carries only a preview")

        await model.copySelectedResponse()
        let copied = try XCTUnwrap(board.string(forType: .string))
        XCTAssertEqual(Array(copied.unicodeScalars), Array(report.unicodeScalars), "copied byte for byte, CRLF and all")
        XCTAssertEqual(model.copyHistory.first?.kind, .response)

        await model.copySelectedContext()
        let pack = try XCTUnwrap(board.string(forType: .string))
        XCTAssertTrue(pack.hasPrefix("# Review Pack:"))
        XCTAssertTrue(pack.contains("- Source: Claude Code on this Mac, captured by the Prompt Relay hooks [Confirmed locally]"))
        XCTAssertEqual(pack.components(separatedBy: report).count - 1, 1, "the complete report, once, unchanged")
        XCTAssertTrue(pack.contains(task), "the linked task")
        XCTAssertTrue(pack.contains("[Not verified]"), "Claude's claims are not presented as verified")

        // The reader shows everything: every block of the report is parsed, nothing dropped.
        let blocks = Markdown.parse(report)
        let codeText = blocks.compactMap { if case .code(_, let t) = $0 { return t } else { return nil } }.joined()
        XCTAssertTrue(codeText.contains("let fence = \"```\""), "a fence inside a longer fence stays inside the block")
        XCTAssertEqual(blocks.filter { if case .code = $0 { return true } else { return false } }.count, 140 * 4)
    }
}

// MARK: - Imports, attachments, Review Pack

@MainActor
final class ReportStoreTests: XCTestCase {
    var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-store-\(UUID().uuidString)")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func png(_ name: String, color: NSColor = .systemTeal) throws -> URL {
        let image = NSImage(size: NSSize(width: 24, height: 16), flipped: false) { rect in color.setFill(); rect.fill(); return true }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let url = root.appendingPathComponent("src").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    func testImportKeepsTextExactlyDeduplicatesAndIsPrivate() throws {
        let store = ReportStore(root: root)
        let text = ReportFixture.report(sections: 120) + "\u{0}NUL\u{2028}LS\r\n"
        let first = try store.importReport(text: text, task: "Задача", projectPath: nil, projectName: nil, sessionLabel: "session_01")
        XCTAssertFalse(first.isDuplicate)
        let again = try store.importReport(text: text, task: "Задача", projectPath: nil, projectName: nil, sessionLabel: nil)
        XCTAssertTrue(again.isDuplicate)
        XCTAssertEqual(again.report.id, first.report.id)
        XCTAssertEqual(store.imports().count, 1)
        let reread = try XCTUnwrap(ReportStore(root: root).imports().first)
        XCTAssertEqual(Array(reread.text.unicodeScalars), Array(text.unicodeScalars), "verbatim after a restart")
        XCTAssertEqual(reread.source, .cloudManualImport)
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("imports/\(first.report.id).json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertThrowsError(try store.importReport(text: "", task: nil, projectPath: nil, projectName: nil, sessionLabel: nil))
    }

    func testAttachmentsAreCopiedCheckedAndRemovedWithTheirImport() throws {
        let store = ReportStore(root: root)
        let report = try store.importReport(text: "report", task: nil, projectPath: nil, projectName: nil, sessionLabel: nil).report
        let source = try png("Экран 1.png")
        let a = try store.addAttachment(from: source, to: report.ref)
        XCTAssertEqual(a.originalFilename, "Экран 1.png")
        XCTAssertEqual(a.mimeType, "image/png")
        XCTAssertEqual(a.sha256, SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try store.addAttachment(from: source, to: report.ref).id, a.id, "the same image is kept once")
        let copy = try XCTUnwrap(store.fileURL(for: a))
        XCTAssertTrue(copy.path.hasPrefix(root.path), "a private copy, not a link to the original")
        try FileManager.default.removeItem(at: source)
        XCTAssertNotNil(store.fileURL(for: a), "removing the original does not lose the attachment")

        let text = root.appendingPathComponent("notes.txt")
        try "x".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.addAttachment(from: text, to: report.ref)) {
            XCTAssertEqual($0 as? ReportStoreError, .notAnImage("notes.txt"))
        }
        store.deleteImport(report.id)
        XCTAssertTrue(store.attachments(for: report.ref).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    func testImportedReviewPackIsHonestAndComplete() throws {
        let text = ReportFixture.report(sections: 3)
        let report = ImportedReport(id: "i1", importedAt: "2026-10-29T18:00:00.000Z", text: text, task: nil,
                                    projectPath: "/Users/me/secret-path/app", projectName: "app", sessionLabel: nil, digest: "d")
        let attachment = ReportAttachment(id: "a", reportKey: report.ref.key, originalFilename: "notch.png", storedFilename: "a.png",
                                          mimeType: "image/png", byteCount: 2048, sha256: "s", addedAt: "t", provenance: "p")
        let pack = ReviewPack.render(imported: report, attachments: [attachment], exportedAt: "2026-10-29T18:05:00.000Z")
        XCTAssertTrue(pack.hasPrefix("# Review Pack:"))
        XCTAssertTrue(pack.contains("Source: Claude Code cloud session, imported manually"))
        XCTAssertTrue(pack.contains("[Unavailable] The request was not supplied"), "a missing task is labeled, never invented")
        XCTAssertEqual(pack.components(separatedBy: text).count - 1, 1, "the full report once")
        XCTAssertTrue(pack.contains(ReviewPack.fence(text) + "markdown\n" + text + "\n" + ReviewPack.fence(text)))
        XCTAssertGreaterThan(ReviewPack.fence(text).count, 4, "longer than the ```` fence inside the report")
        XCTAssertTrue(pack.contains("- notch.png — image/png"))
        XCTAssertFalse(pack.contains("/Users/me"), "no local paths")
        XCTAssertTrue(pack.contains("[Not verified]"))
        XCTAssertTrue(pack.contains("Please review this result independently."))
    }

    func testSecretScannerMatchesTheCore() throws {
        let samples = [
            "export OPENAI_API_KEY=sk-proj-" + String(repeating: "a", count: 30),
            "ok line\r\nghp_" + String(repeating: "B", count: 36) + "\nplain",
            "-----BEGIN RSA PRIVATE KEY-----\nAKIA1234567890ABCDEF",
            "password: \"hunter2hunter2\"\rno secret here",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
            "Нет секретов 🚀 sk-ant-short",
        ]
        let script = """
        import json, sys
        sys.path.insert(0, sys.argv[1])
        from prompt_relay.sensitive import scan
        print(json.dumps([[[f.kind, f.line] for f in scan(s, "r")] for s in json.loads(sys.stdin.read())]))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", script, Repo.root.appendingPathComponent("plugin").path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: samples))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let python = try XCTUnwrap(JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [[[Any]]])
        for (sample, expected) in zip(samples, python) {
            let swift = SecretScanner.scan(sample, section: "r").map { [$0.kind, $0.line] as [AnyHashable] }
            XCTAssertEqual(swift, expected.map { [$0[0] as! String, $0[1] as! Int] as [AnyHashable] }, sample)
        }
    }
}

// MARK: - The model: imports, copies, pins, search, attachments

@MainActor
final class ReportWorkflowTests: XCTestCase {
    var suite: String!
    var defaults: UserDefaults!
    var board: NSPasteboard!
    var root: URL!

    override func setUp() async throws {
        suite = "PromptRelayTests.p4.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP4-\(UUID().uuidString)"))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-p4-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func core() -> FakeCore {
        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-29T16:13:51.000000Z"),
                                       project("/b", sessions: 1, last: "2026-10-29T15:00:00.000000Z")])
        core.sessionsByProject["/a"] = [sessionSummary("sa", project: "/a", last: "2026-10-29T16:13:51.000000Z", lastTurn: 2)]
        core.sessionsByProject["/b"] = [sessionSummary("sb", project: "/b", last: "2026-10-29T15:00:00.000000Z")]
        core.turnsBySession["sa"] = [turn(1, preview: "Первый ответ про парсер", chars: 23, request: "Почини парсер"),
                                     turn(2, preview: "Второй ответ", chars: 12, request: "Добавь тесты")]
        core.turnsBySession["sb"] = [turn(1, preview: "Ответ проекта B", chars: 15, request: "Задача B", link: "sequence")]
        core.showResult = { [core] key, i in
            let text = "FULL \(key)#\(i) " + ReportFixture.section(i)
            return .success(CoreResult(data: ShowData(session: try! core.session(key), turn: turn(i, chars: text.unicodeScalars.count, text: text)),
                                       warnings: []))
        }
        return core
    }

    func model(_ core: FakeCore) -> AppModel {
        AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults,
                 reportStore: ReportStore(root: root))
    }

    func settle() async { try? await Task.sleep(nanoseconds: 120_000_000) }

    func testImportedReportIsShownCopiedAndReviewPackedLikeALocalOne() async throws {
        let m = model(core())
        await m.refreshNow()
        let text = ReportFixture.report(sections: 2)
        XCTAssertEqual(m.importReport(text: text, task: "Сделай X", projectPath: "/b", sessionLabel: "cse_123"), .added)
        XCTAssertEqual(m.importReport(text: text, task: "Сделай X", projectPath: "/b", sessionLabel: nil), .alreadyImported)
        XCTAssertEqual(m.imports.count, 1)
        let report = try XCTUnwrap(m.selectedImport)
        XCTAssertEqual(report.projectName, "b")
        XCTAssertEqual(m.currentRef, .imported(id: report.id))
        XCTAssertFalse(m.followsLatest, "an import on screen is not replaced by the next local answer")

        await m.copySelectedResponse()
        XCTAssertEqual(board.string(forType: .string), text)
        await m.copySelectedContext()
        let pack = try XCTUnwrap(board.string(forType: .string))
        XCTAssertTrue(pack.contains("imported manually"))
        XCTAssertTrue(pack.contains("Сделай X"))
        XCTAssertEqual(m.copyHistory.map(\.kind), [.reviewPack, .response])

        m.openProject("/a")                                 // back to local: the import is no longer shown
        XCTAssertNil(m.selectedImport)
        await settle()
        XCTAssertEqual(m.currentRef, .local(sessionKey: "sa", turn: 2))
    }

    func testImportedSecretsWaitForConfirmationAndAreNotKeptInRecentCopies() async throws {
        let m = model(core())
        await m.refreshNow()
        m.importReport(text: "Use OPENAI_API_KEY=sk-proj-\(String(repeating: "x", count: 30))", task: nil, projectPath: nil, sessionLabel: nil)
        board.clearContents()
        await m.copySelectedContext()
        XCTAssertNotNil(m.pendingSensitiveContext)
        XCTAssertNil(board.string(forType: .string), "nothing copied before the user decides")
        m.confirmSensitiveContextCopy()
        XCTAssertTrue(board.string(forType: .string)?.contains("sk-proj-") ?? false)
        XCTAssertTrue(m.copyHistory.isEmpty, "a pack with possible secrets is not kept for one-click re-copy")
    }

    func testRecentCopiesKeepFiveReferencesAcrossRestartsAndCopyAgainFetchesTheText() async throws {
        let c = core()
        let m = model(c)
        await m.refreshNow()
        for _ in 0..<2 { await m.copyResponse(sessionKey: "sa", turn: 1) }
        await m.copyResponse(sessionKey: "sa", turn: 2)
        await m.copyReviewPack(.local(sessionKey: "sa", turn: 2))   // context fails in the fake: not recorded
        for i in 0..<5 { m.importReport(text: "import \(i)", task: nil, projectPath: nil, sessionLabel: nil); await m.copySelectedResponse() }
        XCTAssertEqual(m.copyHistory.count, AppModel.copyHistoryLimit)
        XCTAssertEqual(Set(m.copyHistory.map(\.ref)).count, 5, "the same copy again moves to the top, not twice")
        let stored = try XCTUnwrap(defaults.data(forKey: AppModel.copiesKey))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("import 4"), "references only, no text")

        let restarted = model(c)
        await restarted.refreshNow()
        XCTAssertEqual(restarted.copyHistory, m.copyHistory)
        let last = try XCTUnwrap(restarted.copyHistory.first)
        board.clearContents()
        await restarted.copyAgain(last)
        XCTAssertEqual(board.string(forType: .string), "import 4")

        guard case .imported(let id) = last.ref else { return XCTFail() }
        restarted.deleteImport(id)
        XCTAssertFalse(restarted.isAvailable(last.ref))
        await restarted.copyAgain(last)
        XCTAssertEqual(restarted.copyFeedback, .failed("This report is no longer in Prompt Relay's history."))
    }

    func testPinsPersistAndSearchFindsImportsInFullAndLocalPreviews() async throws {
        let c = core()
        let m = model(c)
        await m.refreshNow()
        m.importReport(text: "Long cloud report\n" + String(repeating: "filler ", count: 500) + "уникальное_слово", task: nil,
                       projectPath: nil, sessionLabel: nil)
        let importRef = try XCTUnwrap(m.currentRef)
        m.togglePin(importRef)
        m.togglePin(.local(sessionKey: "sb", turn: 1))
        XCTAssertEqual(model(c).pinned, [.local(sessionKey: "sb", turn: 1), importRef])

        let callsBefore = c.turnsCalls
        let deep = await m.search("УНИКАЛЬНОЕ_слово")
        XCTAssertEqual(deep.map(\.ref), [importRef], "imports are searched in full, case-insensitive")
        let local = await m.search("парсер")
        XCTAssertEqual(local.map(\.ref), [.local(sessionKey: "sa", turn: 1)])
        XCTAssertEqual(local.first?.source, .localClaudeCode)
        _ = await m.search("тесты")
        XCTAssertEqual(c.turnsCalls, callsBefore + 2, "turns load once per session, then come from the cache")
    }

    func testProjectsNeverMixReports() async throws {
        let m = model(core())
        await m.refreshNow()
        m.openProject("/b")
        await settle()
        XCTAssertEqual(m.selectedSessionKey, "sb")
        await m.copySelectedResponse()
        XCTAssertTrue(board.string(forType: .string)?.hasPrefix("FULL sb#1 ") ?? false)
        XCTAssertEqual(m.selectedTurn?.link, .sequence, "an inferred task stays labeled as inferred")
        m.openProject("/a")
        await settle()
        await m.copySelectedResponse()
        XCTAssertTrue(board.string(forType: .string)?.hasPrefix("FULL sa#2 ") ?? false)
    }

    func testAttachmentsTravelWithTheirReportOnly() async throws {
        let m = model(core())
        await m.refreshNow()
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
        let src = root.appendingPathComponent("in/shot.png")
        try FileManager.default.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: src)
        m.addAttachments([src, root.appendingPathComponent("missing.png")])
        XCTAssertEqual(m.attachments(for: m.currentRef).count, 1)
        XCTAssertEqual(m.attachmentMessage, "missing.png could not be read")
        m.openProject("/b")
        await settle()
        XCTAssertTrue(m.attachments(for: m.currentRef).isEmpty, "another report has none")

        m.openProject("/a")
        await settle()
        await m.copyResponseWithImages()
        XCTAssertEqual(board.pasteboardItems?.count, 2, "one text item and one image item")
        XCTAssertTrue(board.string(forType: .string)?.hasPrefix("FULL sa#2 ") ?? false, "the text is complete and first")
        XCTAssertNotNil(board.pasteboardItems?.last?.data(forType: .png))
    }
}

// MARK: - Defects found in the real-session audit (2026-10-30)

@MainActor
final class AuditRegressionTests: XCTestCase {
    var board: NSPasteboard!

    override func setUp() async throws {
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayAuditReg-\(UUID().uuidString)"))
    }

    override func tearDown() async throws { board.releaseGlobally() }

    /// Real case: after Claude answered in prompt-relay and the user sent the
    /// next prompt, the session's last turn was "awaiting response", so the
    /// newest answer fell back to an older session in another project, and
    /// the island would have switched to it.
    func testANewPendingPromptDoesNotHideThePreviousAnswer() async throws {
        let core = FakeCore(projects: [project("/old", sessions: 1, last: "2026-10-29T16:00:00.000000Z"),
                                       project("/work", sessions: 1, last: "2026-10-30T08:00:10.000000Z")])
        core.sessionsByProject["/old"] = [sessionSummary("old", project: "/old", last: "2026-10-29T16:00:00.000000Z")]
        core.sessionsByProject["/work"] = [sessionSummary("work", project: "/work", last: "2026-10-30T08:00:10.000000Z",
                                                          lastTurn: 2, status: "awaiting_response")]
        core.turnsBySession["old"] = [turn(1, preview: "old answer", chars: 10)]
        let answered = turn(1, preview: "the answer", chars: 10, at: "2026-10-29T21:30:00.000000Z")
        core.turnsBySession["work"] = [answered, turn(2, status: "awaiting_response", preview: nil)]
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil)
        m.tracksReadyAnswers = true
        await m.refreshNow()
        XCTAssertEqual(m.readyAnswer?.sessionKey, "work", "the previous answer of the active session")
        XCTAssertEqual(m.readyAnswer?.turnIndex, 1)
        XCTAssertEqual(m.selectedProjectPath, "/work", "the island stays on it while the next prompt runs")
        XCTAssertEqual(m.selectedTurnIndex, 1)
    }

    /// Recent Copies named the folder Claude ran in (a subfolder), not the project.
    func testRecentCopiesNameTheEnabledProject() async throws {
        let core = FakeCore(projects: [project("/Users/me/code/app", sessions: 1, last: "2026-10-29T16:13:51.000000Z")])
        core.sessionsByProject["/Users/me/code/app"] = [sessionSummary("s", project: "/Users/me/code/app/Sources/Feature",
                                                                       last: "2026-10-29T16:13:51.000000Z")]
        core.turnsBySession["s"] = [turn(1, preview: "x", chars: 1)]
        core.showResult = { [core] key, i in .success(CoreResult(data: ShowData(session: try! core.session(key), turn: turn(i, text: "x")), warnings: [])) }
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil)
        await m.refreshNow()
        await m.copyResponse(sessionKey: "s", turn: 1)
        XCTAssertEqual(m.copyHistory.first?.projectName, "app")
        XCTAssertEqual(m.copyHistory.first?.label, "Session s · #1")
    }

    /// A code block inside a list item kept the list's indent on every line.
    func testCodeInsideAListItemLosesOnlyTheListIndent() {
        let source = "- Disable it:\n  ```bash\n  prompt-relay disable /x\n    nested indent stays\n  ```\n"
        let code = Markdown.parse(source).compactMap { if case .code(_, let t) = $0 { return t } else { return nil } }
        XCTAssertEqual(code, ["prompt-relay disable /x\n  nested indent stays"])
        XCTAssertTrue(MarkdownCoverage.missingLines(source).isEmpty)
    }

    /// Every line of a long report shows in the Formatted reader.
    func testFormattedReaderDropsNoLineOfALongReport() {
        XCTAssertEqual(MarkdownCoverage.missingLines(ReportFixture.report(sections: 60)), [])
    }
}
