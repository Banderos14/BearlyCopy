import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// Phase 13: Context Packs through the real Core of this checkout, a real
/// ReportStore and a private pasteboard (never the user's clipboard or data).
@MainActor
final class Phase13Tests: XCTestCase {
    var tmp: URL!
    var home: URL!
    var project: URL!
    var projectB: URL!
    var pasteboard: NSPasteboard!
    var store: ReportStore!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory.path.withCString { realpath($0, nil) }.map { String(cString: $0) }!
        tmp = URL(fileURLWithPath: base).appendingPathComponent("pr-p13-\(UUID().uuidString)")
        home = tmp.appendingPathComponent("data")
        project = tmp.appendingPathComponent("project-a")
        projectB = tmp.appendingPathComponent("project-b")
        for dir in [project!, projectB!] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        pasteboard = NSPasteboard(name: NSPasteboard.Name("PromptRelayP13-\(UUID().uuidString)"))
        store = ReportStore(root: tmp.appendingPathComponent("app"))
        try cli(["enable", project.path])
        try cli(["enable", projectB.path])
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Helpers

    func locator() -> CoreLocator {
        CoreLocator(processEnvironment: ["HOME": NSHomeDirectory(), "PROMPT_RELAY_HOME": home.path, "PROMPT_RELAY_CLI": Repo.cli],
                    bundleResourceURL: nil, defaults: { _ in nil })
    }

    func cli(_ args: [String], stdin: Data? = nil, env extra: [String: String] = [:]) throws {
        let location = try locator().locate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: location.python)
        p.arguments = ["-I", "-S", location.cli] + args
        p.environment = ["HOME": tmp.appendingPathComponent("home").path, "PROMPT_RELAY_HOME": home.path, "PATH": "/usr/bin:/bin"]
            .merging(extra) { _, new in new }
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        if let stdin { input.fileHandleForWriting.write(stdin) }
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, args.joined(separator: " "))
    }

    func claude(_ sid: String, _ pid: String, _ prompt: String, _ answer: String, project: URL? = nil, env: [String: String] = [:]) throws {
        let cwd = (project ?? self.project).path
        try cli(["hook"], stdin: try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit", "session_id": sid, "prompt_id": pid, "cwd": cwd, "prompt": prompt]), env: env)
        try cli(["hook"], stdin: try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Stop", "session_id": sid, "prompt_id": pid, "cwd": cwd, "stop_hook_active": false,
            "last_assistant_message": answer]), env: env)
    }

    func codex(_ sid: String, _ prompt: String, _ answer: String) throws {
        let env = ["PROMPT_RELAY_PROVIDER": "codex", "PROMPT_RELAY_HOST": "terminal"]
        try cli(["hook"], stdin: try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit", "session_id": sid, "turn_id": "t1", "cwd": project.path, "prompt": prompt]), env: env)
        try cli(["hook"], stdin: try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Stop", "session_id": sid, "turn_id": "t1", "cwd": project.path, "last_assistant_message": answer]), env: env)
    }

    func makeModel() async -> AppModel {
        let model = AppModel(core: CoreClient.live(locator: locator()), clipboard: ClipboardService(pasteboard: pasteboard),
                             dataDirectory: home, reportStore: store)
        await model.refreshNow()
        await model.loadInbox()
        return model
    }

    func refs(_ model: AppModel) -> [ReportRef] { (model.inbox.value ?? []).reversed().map(\.ref) }

    // MARK: Scenarios

    /// Scenarios 2, 6, 8: the app's document equals the Core's own for local
    /// results, and every answer is inside it byte for byte.
    func testClaudeAndCodexPackMatchesTheCoreAndKeepsTextsVerbatim() async throws {
        let claudeAnswer = "## Plan\n```swift\nlet x = 1\n```\nCafé e\u{301} 🚀\r\nend  "
        try claude("c1", "p1", "Design the cache", claudeAnswer)
        try codex("x1", "Implement the cache", "Implemented. Tests pass.")
        let model = await makeModel()
        let refs = refs(model)
        XCTAssertEqual(refs.count, 2)
        refs.forEach { model.addToPack($0) }
        await model.prepareContextPack()
        let pack = try XCTUnwrap(model.contextPack.pack, "\(model.contextPack)")
        let core = try await CoreClient.live(locator: locator()).contextPack(refs.map {
            guard case .local(let k, let t) = $0 else { return .external }
            return .local(sessionKey: k, turn: t)
        }).data
        // Same frame; only the time differs between the two builds.
        XCTAssertEqual(pack.text.replacingOccurrences(of: pack.builtAt, with: "T"), core.text.replacingOccurrences(of: core.exportedAt, with: "T"))
        XCTAssertTrue(pack.text.unicodeScalars.elementsEqual(pack.text.unicodeScalars))
        XCTAssertNotNil(pack.text.range(of: claudeAnswer))
        XCTAssertTrue(pack.text.contains("## Result 1 of 2 — Claude Code"))
        XCTAssertTrue(pack.text.contains("## Result 2 of 2 — Codex"))
        XCTAssertEqual(pack.manifest.results.map(\.provider), ["claude_code", "codex"])
        XCTAssertFalse(pack.manifest.json().contains(project.path))
        XCTAssertFalse(pack.manifest.json().contains("Design the cache"))
    }

    /// Scenarios 3–5: two profiles with the same native id and title stay two
    /// results; a second project is allowed and flagged.
    func testProfilesWithTheSameSessionIDAndProjectsStayApart() async throws {
        try claude("same", "p1", "Same title", "Personal answer")
        try claude("same", "p1", "Same title", "Work answer",
                   env: ["CLAUDE_CONFIG_DIR": tmp.appendingPathComponent("home/.claude-work").path])
        try claude("b", "p1", "Other project", "B answer", project: projectB)
        let model = await makeModel()
        refs(model).forEach { model.addToPack($0) }
        XCTAssertEqual(model.packRefs.count, 3)
        XCTAssertTrue(model.packMixesProjects)
        await model.prepareContextPack()
        let pack = try XCTUnwrap(model.contextPack.pack)
        XCTAssertEqual(pack.items.count, 3)
        XCTAssertEqual(Set(pack.items.map(\.entry.profile)), ["Default", "claude-work"])
        XCTAssertTrue(pack.text.contains("2 different projects (project-a, project-b)"))
        let sections = pack.text.components(separatedBy: "\n## Result ")
        XCTAssertEqual(sections.filter { $0.contains("Personal answer") }.count, 1)
        XCTAssertFalse(sections.contains { $0.contains("Personal answer") && $0.contains("Work answer") })
    }

    func testAResultIsAddedOnceAndAtMostTwenty() async {
        let model = AppModel(core: FakeCore(projects: []), clipboard: ClipboardService(pasteboard: pasteboard), dataDirectory: nil)
        XCTAssertTrue(model.addToPack(.local(sessionKey: "a", turn: 1)))
        XCTAssertFalse(model.addToPack(.local(sessionKey: "a", turn: 1)))
        for i in 2...20 { model.addToPack(.local(sessionKey: "a", turn: i)) }
        XCTAssertEqual(model.packRefs.count, 20)
        XCTAssertFalse(model.addToPack(.local(sessionKey: "a", turn: 21)))
        XCTAssertNotNil(model.packMessage)
        model.movePackItem(.local(sessionKey: "a", turn: 2), by: -1)
        XCTAssertEqual(model.packRefs.prefix(2), [.local(sessionKey: "a", turn: 2), .local(sessionKey: "a", turn: 1)])
        model.removeFromPack(.local(sessionKey: "a", turn: 5))
        XCTAssertEqual(model.packRefs.count, 19)
        XCTAssertFalse(model.packRefs.contains(.local(sessionKey: "a", turn: 5)))
    }

    /// Scenarios 9–12, 17: files, an in-memory snapshot and a missing file;
    /// text then files; nothing written for the snapshot; history records
    /// what the user did and never "delivered".
    func testTextThenFilesSnapshotsStayInMemoryAndMissingIsNotOffered() async throws {
        try claude("s1", "p1", "Make the report", "Report done.")
        try claude("s2", "p1", "Review it", "Looks fine.")
        let model = await makeModel()
        let refs = refs(model)
        refs.forEach { model.addToPack($0) }
        let doc = tmp.appendingPathComponent("notes.md"); try Data("# notes".utf8).write(to: doc)
        let gone = tmp.appendingPathComponent("gone.md"); try Data("bye".utf8).write(to: gone)
        try store.addFile(from: doc, to: refs[0], source: .you, displayPath: "notes.md")
        let lost = try store.addFile(from: gone, to: refs[1], source: .you, displayPath: "gone.md")
        let shot = try store.addEphemeralImage(TypedAttachmentTests.png(), name: "Window.png", to: refs[1], source: .windowSnapshot)
        try FileManager.default.removeItem(at: try XCTUnwrap(store.fileURL(for: lost)))
        model.attachmentsVersion += 1

        await model.prepareContextPack()
        let pack = try XCTUnwrap(model.contextPack.pack)
        XCTAssertEqual(pack.attachments.map(\.availability), [.file, .missing, .memoryOnly])
        XCTAssertEqual(pack.sendable.count, 2)
        XCTAssertTrue(pack.text.contains("gone.md — not available: the stored copy is missing; it is not part of this pack"))
        XCTAssertTrue(pack.text.contains("temporary window snapshot, held in memory only"))

        model.copyContextPackText()
        XCTAssertEqual(pasteboard.string(forType: .string).map { Array($0.unicodeScalars) }, Array(pack.text.unicodeScalars))
        XCTAssertNotNil(model.packProgress.textCopiedAt)

        model.copyContextPackFiles()
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        XCTAssertEqual(urls.map(\.lastPathComponent), ["notes.md"])
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2, "one file and the snapshot as image data")
        XCTAssertEqual(pasteboard.pasteboardItems?.last?.data(forType: .png), shot.isInMemory ? store.data(for: shot) : nil)
        let written = FileManager.default.enumerator(at: store.root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        XCTAssertFalse(written.contains { $0.lastPathComponent.hasPrefix("Window") }, "no PNG for the snapshot: \(written)")

        let payloads = model.contextPackDragPayloads()
        XCTAssertEqual(payloads.count, 2)
        XCTAssertTrue(payloads.contains { if case .image = $0 { return true } else { return false } })

        let record = try XCTUnwrap(model.handoffHistory.first)
        XCTAssertEqual(record.steps.map(\.event), [.prepared, .copiedText, .copiedFiles, .dragStarted])
        let saved = try String(contentsOf: AppModel.handoffHistoryURL(store))
        XCTAssertFalse(saved.contains("Report done."), "no answer text in the history")
        XCTAssertFalse(saved.contains("delivered"))

        let folder = try XCTUnwrap(model.writeContextPack(into: tmp))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("context-pack.md")), pack.text)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("files").path).sorted()
        XCTAssertEqual(files, ["Window.png", "notes.md"], "export is the one explicit place a snapshot becomes a file")
        let manifest = try String(contentsOf: folder.appendingPathComponent("manifest.json"))
        XCTAssertTrue(manifest.contains("\"availability\" : \"memory_only\""))
        XCTAssertFalse(manifest.contains(tmp.path))
        XCTAssertEqual(model.handoffHistory.first?.lastEvent, .exported)
    }

    /// Scenario 18: the draft and the history survive a restart; the text
    /// is prepared again (it is never stored). Delete keeps the results.
    func testRestartKeepsDraftAndHistoryNotTheText() async throws {
        try claude("s1", "p1", "Task", "Answer")
        let first = await makeModel()
        first.addToPack(refs(first)[0])
        first.packInstructions = "Check it."
        first.packDestination = .chatGPT
        await first.prepareContextPack()
        XCTAssertNotNil(first.contextPack.pack)

        let second = await makeModel()
        XCTAssertEqual(second.packRefs, first.packRefs)
        XCTAssertEqual(second.packInstructions, "Check it.")
        XCTAssertEqual(second.packDestination, .chatGPT)
        XCTAssertNil(second.contextPack.pack)
        XCTAssertEqual(second.handoffHistory.count, 1)
        second.reprepare(try XCTUnwrap(second.handoffHistory.first))
        XCTAssertEqual(second.packRefs, first.packRefs)
        second.deleteHandoffRecord(second.handoffHistory[0].id)
        XCTAssertTrue(second.handoffHistory.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppModel.handoffHistoryURL(store).path))
        await second.loadInbox()
        XCTAssertEqual(second.inbox.value?.count, 1, "deleting a record never deletes a result")
    }

    func testChangesMakeThePreparedPackStaleAndInstructionsAreTheUsers() async throws {
        try claude("s1", "p1", "Task one", "One")
        try claude("s2", "p1", "Task two", "Two")
        let model = await makeModel()
        refs(model).forEach { model.addToPack($0) }
        model.packInstructions = "Найди ошибки.\n````\nfence\n````"
        await model.prepareContextPack()
        let pack = try XCTUnwrap(model.contextPack.pack)
        XCTAssertTrue(pack.text.contains("[Supplied by you] Written by the user for the receiving AI. Not part of any agent's result."))
        XCTAssertTrue(pack.text.contains("`````text\n" + model.packInstructions + "\n`````"))
        XCTAssertFalse(model.packIsStale, "regression: a pack ending in the instructions' fence is not stale")
        model.copyContextPackText()
        XCTAssertNotNil(pasteboard.string(forType: .string))
        pasteboard.clearContents()
        model.packIncludesManifest = true
        XCTAssertTrue(model.packIsStale)
        model.packIncludesManifest = false
        model.movePackItem(model.packRefs[1], by: -1)
        XCTAssertTrue(model.packIsStale)
        model.copyContextPackText()
        XCTAssertNil(pasteboard.string(forType: .string), "a stale pack is never copied")
    }

    func testLikelySecretsWaitForTheUsersYes() async throws {
        try claude("s1", "p1", "Task", "token ghp_" + String(repeating: "a", count: 36))
        let model = await makeModel()
        model.addToPack(refs(model)[0])
        await model.prepareContextPack()
        model.copyContextPackText()
        XCTAssertTrue(model.packAwaitsSensitiveConfirmation)
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertNil(model.writeContextPack(into: tmp), "not exported with likely secrets")
        model.copyContextPackText(confirmed: true)
        XCTAssertNotNil(pasteboard.string(forType: .string))
    }

    /// v0.5.0 item 7: an unchecked attachment never leaves; a document the
    /// user added with a likely secret holds Copy Files, Drag and Export
    /// until the same yes as the text; the answer stays verbatim.
    func testUncheckedAndSecretAttachmentsAreNotHandedOverSilently() async throws {
        let answer = "Done.\r\n```\nkeep  \n```\n"
        try claude("s1", "p1", "Task", answer)
        let model = await makeModel()
        let ref = refs(model)[0]
        model.addToPack(ref)
        let hidden = tmp.appendingPathComponent("private-notes.md"); try Data("# hidden".utf8).write(to: hidden)
        let leaky = tmp.appendingPathComponent("setup.md")
        try Data("export API_KEY=sk-ant-api03-\(String(repeating: "x", count: 40))\n".utf8).write(to: leaky)
        let off = try store.addFile(from: hidden, to: ref, source: .you, displayPath: "private-notes.md")
        try store.setSelected(off.id, false)
        try store.addFile(from: leaky, to: ref, source: .you, displayPath: "setup.md")
        model.attachmentsVersion += 1
        await model.prepareContextPack()
        let pack = try XCTUnwrap(model.contextPack.pack)
        XCTAssertNotNil(pack.text.range(of: answer), "the answer is verbatim")
        XCTAssertFalse(pack.text.contains("private-notes"))
        XCTAssertFalse(pack.manifest.json().contains("private-notes"))
        XCTAssertEqual(pack.attachments.map(\.name), ["setup.md"])
        XCTAssertTrue(pack.items[0].findings.contains { $0.section == "attachment setup.md" }, "\(pack.items[0].findings)")

        model.copyContextPackFiles()
        XCTAssertTrue(model.packAwaitsSensitiveConfirmation)
        XCTAssertNil(pasteboard.pasteboardItems?.first, "no files before the yes")
        XCTAssertTrue(model.contextPackDragPayloads().isEmpty, "no drag before the yes")
        XCTAssertNil(model.writeContextPack(into: tmp), "never exported with likely secrets")

        model.copyContextPackText(confirmed: true)
        model.copyContextPackFiles()
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        XCTAssertEqual(urls.map(\.lastPathComponent), ["setup.md"])
        XCTAssertEqual(model.contextPackDragPayloads().count, 1)
    }

    /// An imported report fills its own slot; the Core numbers around it.
    func testImportedReportKeepsItsPlaceAndLabels() async throws {
        try claude("a1", "p1", "Task A", "Answer A")
        try claude("a1", "p2", "Task A2", "Answer A2")
        let report = try store.importReport(text: "Pasted cloud answer", task: "Cloud task", projectPath: nil, projectName: "web",
                                            sessionLabel: nil, assistant: "chatgpt").report
        let model = await makeModel()
        let local = refs(model)
        model.addToPack(local[0]); model.addToPack(report.ref); model.addToPack(local[1])
        await model.prepareContextPack()
        let pack = try XCTUnwrap(model.contextPack.pack, "\(model.contextPack)")
        XCTAssertTrue(pack.text.contains("## Result 2 of 3 — Imported by you"))
        XCTAssertTrue(pack.text.contains("Pasted cloud answer"))
        XCTAssertTrue(pack.text.contains("same reading as Result 1"))
        XCTAssertEqual(pack.manifest.results.map(\.kind), ["local_capture", "user_import", "local_capture"])
        XCTAssertEqual(pack.manifest.results.map(\.position), [1, 2, 3])
    }

    /// Scenarios 13–14: the pack's Drag starts on the first press in a
    /// non-key island, carries files and snapshot data, and works again
    /// after a cancelled drag. Sessions are recorded, not started.
    func testPackDragStartsOnFirstPressAndAgainAfterCancel() async throws {
        try claude("s1", "p1", "Task", "Answer")
        let model = await makeModel()
        let ref = refs(model)[0]
        model.addToPack(ref)
        let doc = tmp.appendingPathComponent("notes.md"); try Data("# n".utf8).write(to: doc)
        try store.addFile(from: doc, to: ref, source: .you, displayPath: "notes.md")
        _ = try store.addEphemeralImage(TypedAttachmentTests.png(), name: "Window.png", to: ref, source: .windowSnapshot)
        model.attachmentsVersion += 1
        await model.prepareContextPack()
        _ = NSApplication.shared
        let panel = NotchPanel()
        panel.install(root: FileDragButton(title: "Drag", help: "", payloads: { model.contextPackDragPayloads() }).frame(width: 120, height: 40))
        panel.setFrame(NSRect(x: 200, y: 200, width: 120, height: 40), display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.resignKey()
        let drag = try XCTUnwrap(Phase122Tests.find(FileDragSource.DragView.self, in: panel.contentView))
        var offered: [[NSDraggingItem]] = []
        drag.beginSession = { items, _ in offered.append(items) }
        let p = drag.convert(NSPoint(x: drag.bounds.midX, y: drag.bounds.midY), to: nil)
        func send(_ type: NSEvent.EventType, _ point: NSPoint) {
            panel.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        send(.leftMouseDown, p); send(.leftMouseDragged, NSPoint(x: p.x + 10, y: p.y))
        XCTAssertEqual(offered.count, 1, "first press while the panel is not key")
        XCTAssertEqual(offered.first?.count, 2)
        XCTAssertTrue(offered[0].contains { $0.item is NSURL }, "the document as a file URL")
        XCTAssertTrue(offered[0].contains { ($0.item as? NSPasteboardItem)?.data(forType: .png) != nil && ($0.item as? NSPasteboardItem)?.string(forType: .fileURL) == nil },
                      "the snapshot as image data without a file")
        drag.sessionEnded()   // Esc: no operation
        send(.leftMouseUp, p)
        send(.leftMouseDown, p); send(.leftMouseDragged, NSPoint(x: p.x + 10, y: p.y))
        XCTAssertEqual(offered.count, 2, "a new drag after the cancelled one")
        XCTAssertEqual(model.handoffHistory.first?.steps.filter { $0.event == .dragStarted }.count, 2)
    }

    /// Offscreen: the real island draws the Inbox with a selection, the pack
    /// view (prepared), its Preview and the Handoff History at a 14-inch
    /// MacBook's height. PNGs go to PROMPT_RELAY_SNAPSHOT_DIR when set.
    func testPackSurfacesRenderInTheIsland() async throws {
        try claude("s1", "p1", "Design the cache", "Design: LRU.")
        try codex("x1", "Implement the cache", "Implemented.")
        try claude("b1", "p1", "Other project", "B", project: projectB)
        let model = await makeModel()
        refs(model).prefix(2).forEach { model.addToPack($0) }
        model.packInstructions = "Check the implementation and find bugs."
        await model.prepareContextPack()
        model.copyContextPackText()
        XCTAssertNotNil(model.packProgress.textCopiedAt)
        _ = NSApplication.shared
        let p = NotchPresentation()
        p.notchSize = CGSize(width: 185, height: 32)
        p.islandWidth = NotchLayout.expandedWidth
        p.isExpanded = true
        p.surface = .expanded
        p.maxContentHeight = (982 * NotchLayout.maxScreenShare).rounded() - 32
        let dir = ProcessInfo.processInfo.environment["PROMPT_RELAY_SNAPSHOT_DIR"]
        for route in [AppModel.IslandRoute.inbox, .contextPack, .contextPackPreview, .handoffHistory] {
            model.route = route
            let view = NotchRootView(model: model, presentation: p, interaction: NotchInteraction(scheduler: MainQueueScheduler()),
                                     actions: SurfaceActions(quit: {}), settings: nil)
            let size = NSSize(width: NotchLayout.expandedWidth, height: 32 + p.maxContentHeight)
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(white: 0.86)))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            if let dir { try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/phase13-\(route.rawValue).png")) }
            XCTAssertGreaterThan(rep.pixelsWide, 0)
            window.close()
        }
        XCTAssertEqual(model.route, .handoffHistory)
    }

    // MARK: Composer and limits

    func testComposerShiftsOnlyGeneratedHeadings() {
        XCTAssertEqual(ContextPackComposer.shiftOutsideFences("## A\n```\n## inside\n```\n# B"), "### A\n```\n## inside\n```\n## B")
        XCTAssertEqual(ContextPackComposer.instructionsSection(nil)[0], "## Review request")
        XCTAssertEqual(ContextPackComposer.instructionsSection("   \n")[0], "## Review request")
        XCTAssertEqual(HandoffDestination.codex.support(.imageData), .unsupported)
        XCTAssertEqual(HandoffDestination.chatGPT.support(.imageData), .unverified, "never claimed without a real check")
    }

    /// Scenario 16: the clipboard limit is about chats, not the pasteboard.
    func testFourMegabytesCopyAndReadBackQuickly() throws {
        let text = String(repeating: "Line of a long pack with ünïcode 🚀\n", count: 110_000)
        let start = Date()
        try ClipboardService(pasteboard: pasteboard).copy(text)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertGreaterThan(CharacterCount.of(text), ContextPackFormat.maxClipboardCharacters)
    }
}
