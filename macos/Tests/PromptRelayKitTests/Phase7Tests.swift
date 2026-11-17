import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// Phase 7: tooltips inside the visible island, Clipboard image hit-testing,
/// View Full Task, Markdown Source, Standard / Full context, Evidence Check,
/// Artifact Completeness, Review Checklist, Import AI Result, Export Bundle.
@MainActor
final class Phase7Tests: XCTestCase {
    var suite: String!
    var defaults: MemorySettingsStore!
    var board: NSPasteboard!
    var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        suite = "PromptRelayTests.p7.\(UUID().uuidString)"
        defaults = TestDefaults.named(suite)
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP7-\(UUID().uuidString)"))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-p7-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        removeTestDefaults(suite)
        try? FileManager.default.removeItem(at: root)
        Island.palette = IslandTheme.warmCocoa.palette
    }

    func makeModel() async -> AppModel {
        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-31T10:00:00.000000Z")])
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults,
                         reportStore: ReportStore(root: root))
        await m.refreshNow()
        return m
    }

    @discardableResult
    func importReport(_ m: AppModel, _ text: String, task: String = "Задача", files: [(String, Data)] = []) throws -> ReportRef {
        _ = m.importReport(text: text, task: task, projectPath: "/a", sessionLabel: nil)
        let ref = try XCTUnwrap(m.currentRef)
        let dir = root.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in files {
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            try XCTUnwrap(m.reportStore).addFile(from: url, to: ref, source: .you, displayPath: name)
        }
        m.attachmentsVersion += 1
        return ref
    }

    // MARK: Tooltips

    /// The placement keeps a tip of any size inside the black part of the
    /// island: below the band, inside the flared sides, clear of the rounded
    /// bottom corners, and never over its own control.
    func testTipPlacementStaysInsideTheVisibleIslandForEveryAnchor() {
        let island = CGSize(width: 520, height: 300), band: CGFloat = 32
        let safe = TipPlacement.safeArea(island: island, band: band)
        for tip in [CGSize(width: 60, height: 16), CGSize(width: 220, height: 44), CGSize(width: 600, height: 400)] {
            for x in stride(from: 0, through: island.width, by: 20) {
                for y in stride(from: band, through: island.height - 20, by: 12) {
                    let anchor = CGRect(x: x, y: y, width: 26, height: 20)
                    let f = TipPlacement.frame(anchor: anchor, tip: tip, island: island, band: band)
                    XCTAssertTrue(safe.insetBy(dx: -0.5, dy: -0.5).contains(f), "\(f) outside \(safe), anchor \(anchor)")
                    if f.maxY > island.height - TipPlacement.bottomRadius {
                        XCTAssertGreaterThanOrEqual(f.minX, TipPlacement.bottomRadius - 0.5, "clear of the bottom-left corner")
                        XCTAssertLessThanOrEqual(f.maxX, island.width - TipPlacement.bottomRadius + 0.5, "clear of the bottom-right corner")
                    }
                    let fitsBelow = anchor.maxY + 4 + tip.height <= safe.maxY
                    let fitsAbove = anchor.minY - 4 - tip.height >= safe.minY
                    if fitsBelow || fitsAbove {
                        XCTAssertFalse(f.intersects(anchor.insetBy(dx: 1, dy: 1)), "never over its own control \(anchor)")
                    }
                }
            }
        }
    }

    /// Every control with a tip, on every surface, in the real view tree:
    /// the drawn tip (its measured frame) stays inside the visible island.
    func testEveryRealTooltipIsDrawnInsideTheIsland() async throws {
        let m = await makeModel()
        try importReport(m, ReportFixture.report(sections: 6), files: [("a.md", Data("# A\n".utf8)), ("b.png", Phase6Tests.png(seed: 2))])
        var checked = 0
        for surface in [NotchPresentation.Surface.peek, .expanded] {
            for maxContent: CGFloat in [268, 448] {
                let routes: [AppModel.IslandRoute] = surface == .peek ? [.home] : [.home, .history, .clipboard, .settings, .reader, .taskReader, .evidence, .packagePreview, .importReport]
                for route in routes {
                    m.route = route
                    let tips = IslandTooltips()
                    let host = IslandHost(model: m, surface: surface, maxContentHeight: maxContent, tips: tips)
                    defer { host.close() }
                    let island = CGSize(width: host.width, height: host.height)
                    let safe = TipPlacement.safeArea(island: island, band: 32)
                    let controls = tips.controls.filter { safe.intersects($0.value.anchor) }
                    if [.home, .history, .clipboard].contains(route) { XCTAssertFalse(controls.isEmpty, "\(surface) \(route): controls with tips") }
                    for (owner, control) in controls {
                        tips.show(owner, text: control.text, anchor: control.anchor)
                        host.settle()
                        let f = try XCTUnwrap(host.presentation.layoutFrames["tooltip"], "\(route) \(control.text)")
                        XCTAssertTrue(TipPlacement.safeArea(island: CGSize(width: host.width, height: host.height), band: 32).insetBy(dx: -1, dy: -1).contains(f),
                                      "\(surface) \(route) \(maxContent): “\(control.text)” at \(f), island \(island)")
                        checked += 1
                    }
                    tips.hideAll()
                }
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 30, "the check covered the real controls")
    }

    func testNoAppKitTooltipsInTheSources() throws {
        // `.help` opens AppKit's own tooltip window, which can cover other
        // apps beside the island (the probe in docs/PHASE7.md shows it).
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources").standardized
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains(".help("), "\(file.lastPathComponent) uses .help")
            XCTAssertFalse(text.contains("toolTip ="), "\(file.lastPathComponent) sets an AppKit toolTip")
        }
    }
}

// MARK: - Clipboard image hit-testing

@MainActor
final class Phase7ClipboardHitTests: XCTestCase {
    /// A wide screenshot, so `.fill` overflows its 96 × 64 thumbnail.
    static func wide(_ color: NSColor) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 160, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill(); NSRect(x: 0, y: 0, width: 800, height: 160).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// Five wide screenshots: the thumbnails sit side by side, none over
    /// another, each with its own frame.
    func testFiveWideThumbnailsDoNotOverlap() async throws {
        _ = NSApplication.shared
        let suite = "PromptRelayTests.p7c.\(UUID().uuidString)"
        let defaults = TestDefaults.named(suite)!
        let board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP7c-\(UUID().uuidString)"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pr-p7c-\(UUID().uuidString)")
        defer { board.releaseGlobally(); removeTestDefaults(suite); try? FileManager.default.removeItem(at: folder) }
        let history = ClipboardImageHistory(folder: folder, pasteboard: board)
        history.setEnabled(true)
        defer { history.setEnabled(false) }
        for color in [NSColor.red, .green, .blue, .yellow, .purple] {
            board.clearContents(); board.setData(Self.wide(color), forType: .png); history.poll()
        }
        XCTAssertEqual(history.items.count, 5)
        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-31T10:00:00.000000Z")])
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults)
        await m.refreshNow()
        m.clipboardImages = history
        m.route = .clipboard
        m.clipboardTab = .images
        let host = IslandHost(model: m)
        defer { host.close() }
        let frames = try history.items.map { try XCTUnwrap(host.presentation.layoutFrames["clipboard.thumb.\($0.id)"]) }
        for (i, a) in frames.enumerated() {
            XCTAssertEqual(a.size, CGSize(width: 96, height: 64), "the hit area is the visible thumbnail")
            for b in frames[(i + 1)...] { XCTAssertFalse(a.intersects(b), "thumbnails \(a) and \(b) overlap") }
        }
    }

    /// `.clipped()` does not limit hit-testing: every `.fill` image must
    /// also get a content shape, or its overflow takes the neighbour's clicks
    /// (proved with `scripts/probes/thumbnail-hit.swift`).
    func testEveryFillImageHasAContentShape() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources").standardized
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var sites = 0
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("contentMode: .fill") {
                sites += 1
                let after = lines[i..<min(lines.count, i + 18)].joined(separator: "\n")
                XCTAssertTrue(after.contains(".contentShape("), "\(file.lastPathComponent):\(i + 1) has no content shape")
            }
        }
        XCTAssertEqual(sites, 4, "Phase 10 added the in-memory snapshot thumbnail in KindIcon")
    }
}

// MARK: - View Full Task

final class FullTaskTests: XCTestCase {
    func ref(_ preview: String, chars: Int, truncated: Bool, text: String? = nil) throws -> TextRef {
        var json: [String: Any] = ["preview": preview, "truncated": truncated, "char_count": chars, "utf8_bytes": chars,
                                   "prompt_id": "p1", "received_at": "2026-10-31T10:00:00Z"]
        if let text { json["text"] = text }
        return try JSONDecoder().decode(TextRef.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// A long pasted Markdown request: the whole stored text, every
    /// character, once `show` has loaded it; nothing shortened.
    func testLongMarkdownRequestIsWholeAndVerbatim() throws {
        let long = "<pasted_content>\n# Plan\n\n" + String(repeating: "- пункт с `кодом` и **жирным**\n", count: 400) + "```swift\nlet x = 1\n```\n</pasted_content>\r\nСделай это."
        let request = try ref(String(long.prefix(200)), chars: long.unicodeScalars.count, truncated: true)
        let task = FullTask.local(request: request, fullText: long, requestOrigin: .user, link: .promptID, earlier: nil)
        XCTAssertEqual(task.original, long, "Markdown Source and the copy are the stored text exactly")
        XCTAssertTrue(task.complete)
        XCTAssertEqual(task.origin, .linked)
        XCTAssertEqual(task.characters, long.unicodeScalars.count)
        XCTAssertFalse(task.display!.contains("pasted_content"), "Formatted hides only the paste wrapper")
        XCTAssertTrue(task.display!.contains("Сделай это."))
        XCTAssertTrue(task.canCopy)
    }

    func testOnlyThePreviewAtHandIsMarkedIncomplete() throws {
        let request = try ref(String(repeating: "a", count: 200), chars: 5_000, truncated: true)
        let task = FullTask.local(request: request, fullText: nil, requestOrigin: .user, link: .promptID, earlier: nil)
        XCTAssertFalse(task.complete)
        XCTAssertTrue(task.notes.contains { $0.hasPrefix("Incomplete here: only the first 200 of \(5_000.formatted()) characters") }, "\(task.notes)")
        let short = try ref("Коротко", chars: 7, truncated: false)
        XCTAssertTrue(FullTask.local(request: short, fullText: nil, requestOrigin: .user, link: .promptID, earlier: nil).complete,
                      "a preview that is the whole text is complete")
    }

    /// A message Claude Code wrote is never offered as the user's task.
    func testAutomaticTurnIsNotTheUsersTask() throws {
        let request = try ref("<task-notification>done</task-notification>", chars: 43, truncated: false)
        let earlier = try JSONDecoder().decode(EarlierRequest.self, from: Data(#"{"turn":1,"preview":"Implement Phase 7","truncated":false,"char_count":17,"utf8_bytes":17,"prompt_id":"p1","received_at":"2026-10-31T10:00:00Z"}"#.utf8))
        let task = FullTask.local(request: request, fullText: nil, requestOrigin: .automated, link: .promptID, earlier: earlier)
        XCTAssertEqual(task.origin, .automated)
        XCTAssertFalse(task.canCopy, "Copy Original Task is off")
        XCTAssertNil(task.display, "shown as stored text only, never formatted as a request")
        XCTAssertEqual(task.earlierRequest, "Implement Phase 7")
        XCTAssertTrue(task.notes[0].contains("you did not write this message"))
    }

    func testOrderLinkAndImportsSayWhereTheTaskCameFrom() throws {
        let request = try ref("Do it", chars: 5, truncated: false)
        let inferred = FullTask.local(request: request, fullText: "Do it", requestOrigin: .user, link: .sequence, earlier: nil)
        XCTAssertEqual(inferred.origin, .inferred)
        XCTAssertTrue(inferred.notes[0].contains("by order only"))
        let imported = FullTask.imported(task: "Задача из ChatGPT")
        XCTAssertEqual(imported.original, "Задача из ChatGPT")
        XCTAssertTrue(imported.notes[0].contains("Entered by you when importing"))
        XCTAssertFalse(FullTask.imported(task: nil).canCopy)
        XCTAssertFalse(FullTask.local(request: nil, fullText: nil, requestOrigin: nil, link: .none, earlier: nil).canCopy)
    }

    func testLabelsArePhase7Names() {
        XCTAssertEqual(Labels.markdownSource, "Markdown Source")
        XCTAssertEqual(Labels.importAIResult, "Import AI Result")
        XCTAssertEqual(ReportSource.cloudManualImport.label, "Imported by you")
        XCTAssertEqual(ReportSource(rawValue: "cloudManualImport"), .cloudManualImport, "older imports still decode")
        XCTAssertEqual(AppModel.IslandRoute.taskReader.title, "Full Task")
    }
}

// MARK: - Standard / Full context

@MainActor
final class SmartContextTests: XCTestCase {
    var board: NSPasteboard!
    var defaults: MemorySettingsStore!
    var suite: String!

    override func setUp() async throws {
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP7s-\(UUID().uuidString)"))
        suite = "PromptRelayTests.p7s.\(UUID().uuidString)"
        defaults = TestDefaults.named(suite)
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        removeTestDefaults(suite)
    }

    static let packText = """
    # Copy with Context: Claude Code result for an independent check
    ## Session
    - Turn: 1 of 1
    ## Original user request
    ```text
    ## not a heading inside a fence
    ```
    ## Claude final response
    ````markdown
    ```swift
    ## also not a heading
    ```
    ````
    ## Observed during this turn [Confirmed locally]
    ## Not checked
    """

    func core() throws -> FakeCore {
        let core = FakeCore(projects: [project("/p", sessions: 1, last: "2026-10-31T00:00:00.000000Z")])
        core.sessionsByProject["/p"] = [sessionSummary("s", project: "/p", last: "2026-10-31T00:00:00.000000Z")]
        core.turnsBySession["s"] = [turn(1, request: "Do it")]
        core.showResult = { key, i in .success(CoreResult(data: ShowData(session: try! core.session(key), turn: turn(i, text: "answer")), warnings: [])) }
        let json = try JSONEncoder().encode(Self.packText)
        let context = try JSONDecoder().decode(ContextData.self, from: Data("""
        {"session":\(String(data: try JSONEncoder.sessionJSON("s"), encoding: .utf8)!),
         "turn":{"index":1,"status":"stop_received","link":"prompt_id","request":null,"final_response":null,"response_event_count":1,"background_tasks":null,"error":null,"candidate_request_turns":[]},
         "exported_at":"2026-10-31T00:00:00.000000Z","text":\(String(data: json, encoding: .utf8)!),
         "sensitive_findings":[],
         "git":{"available":false,"reason":"not a git repository","branch":null,"head":null,"changed_file_count":0,"changed_files_truncated":false}}
        """.utf8))
        core.contextResult = .success(CoreResult(data: context, warnings: []))
        return core
    }

    /// Phase 7.2: always Full; an older saved "Standard" is ignored.
    func testCopyAndPreviewAreAlwaysFull() async throws {
        defaults.set("standard", forKey: "contextDetail.v1")
        let core = try core()
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults)
        await m.refreshNow()
        XCTAssertEqual(m.contextDetail, .full)
        await m.copySelectedContext()
        XCTAssertEqual(core.contextDetails.last, .full, "Copy asks the Core for Full")
        await m.openPackPreview()
        guard case .ready(let pack)? = m.packPreview else { return XCTFail("preview built") }
        XCTAssertEqual(pack.detail, .full)
        await m.copyPreviewedPack()
        XCTAssertEqual(board.string(forType: .string), pack.text, "Copy uses exactly the previewed snapshot")
        XCTAssertEqual(core.contextDetails, [.full, .full], "built once for Preview, not again for its Copy")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("condition not met in time") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testSectionsComeFromTheTextAndSkipFencedLines() {
        let sections = PackSection.sections(in: Self.packText)
        XCTAssertEqual(sections.map(\.title), ["Session", "Original user request", "Claude final response",
                                               "Observed during this turn [Confirmed locally]", "Not checked"])
        XCTAssertEqual(sections.map(\.short), ["Session", "Request", "Answer", "Evidence & commands", "Limitations"])
        let ns = Self.packText as NSString
        for s in sections { XCTAssertEqual(ns.substring(with: NSRange(location: s.offset, length: 3)), "## ") }
    }
}

// MARK: - Evidence Check, Artifact Completeness, Review Checklist

final class EvidenceTests: XCTestCase {
    func detail(_ commands: [[String: Any]], files: [String] = []) throws -> ObservedDetail {
        let json: [String: Any] = ["commands": commands, "files_changed": files.map { ["path": $0, "tools": ["Edit"], "count": 1] },
                                   "shown_files": [], "artifacts": [], "notifications": 0]
        return try JSONDecoder().decode(ObservedDetail.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func cmd(_ command: String, kind: String, exit: Int) -> [String: Any] {
        ["at": "2026-10-31T10:00:00Z", "command": command, "kind": kind, "outcome": exit == 0 ? "ok" : "failed", "exit_code": exit,
         "duration_ms": 100, "compound": false, "background": false, "after_stop": false]
    }

    func counts(files: Int = 0, nonzero: Int = 0) throws -> ObservedCounts {
        try JSONDecoder().decode(ObservedCounts.self, from: Data("""
        {"tool_events":12,"runs_exit_zero":1,"runs_nonzero":0,"runs_unknown":0,"files_changed":\(files),"background_started":0,"commands_nonzero":\(nonzero)}
        """.utf8))
    }

    /// The owner's example: 12 commands, one exit 1, a claim of passing tests.
    func testObservedFactsAndClaimsStayApart() throws {
        var input = EvidenceCheck.Input()
        input.observed = try counts(files: 2, nonzero: 1)
        input.detail = try detail((0..<10).map { cmd("ls \($0)", kind: "other", exit: 0) }
                                  + [cmd("swift test", kind: "test", exit: 0), cmd("make lint", kind: "build", exit: 1)])
        input.answer = "All tests pass, the app works."
        let e = EvidenceCheck.make(input)
        let observed = e.items(.observed).map(\.text)
        XCTAssertTrue(observed.contains("12 commands observed"))
        XCTAssertTrue(observed.contains("1 command returned exit 1"))
        XCTAssertTrue(observed.contains("1 test command exited 0"))
        XCTAssertTrue(e.items(.reported).map(\.text).contains("The answer says tests pass"))
        XCTAssertTrue(e.items(.notVerified).contains { $0.text.hasPrefix("Claimed test success") })
        XCTAssertFalse(e.items(.observed).contains { $0.text.lowercased().contains("pass") }, "a claim is never an observed fact")
        XCTAssertTrue(e.items(.unavailable).map(\.text).contains("CI not connected"))
    }

    func testImportsAndMissingCaptureAreUnavailableNotGuessed() {
        var input = EvidenceCheck.Input()
        input.imported = true
        input.answer = "Build succeeded."
        let e = EvidenceCheck.make(input)
        XCTAssertTrue(e.items(.observed).isEmpty, "nothing observed for an import")
        XCTAssertTrue(e.items(.unavailable).first!.text.hasPrefix("Imported by you"))
        XCTAssertTrue(e.items(.notVerified).contains { $0.text == "Claimed build success: no successful build command was observed" })
        XCTAssertFalse(EvidenceCheck.Claims.find(in: "I rebuilt the build script").visual, "“ui” only as a word")
    }

    func state(_ title: String, _ status: MockupState.Status, attachment: String? = nil) -> MockupState {
        MockupState(id: UUID().uuidString, title: title, summary: nil, interactive: [], status: status, attachmentID: attachment,
                    failure: nil, selected: true)
    }

    /// Seven declared states, six images: the missing one is named.
    func testMockupSixOfSevenStates() {
        var states = (1...6).map { state("State \($0)", .captured, attachment: "a\($0)") }
        states.append(state("Error", .namedOnly))
        let mockup = ReportMaterial(id: "m", reportKey: "k", kind: .mockup, title: "Notch", url: nil, audience: nil, sourcePath: nil,
                                    version: nil, addedAt: "", provenance: "", selected: true, states: states)
        let c = ArtifactCompleteness.make(attachments: [], unreadable: [], materials: [mockup])
        XCTAssertEqual(c.lines.first?.text, "6/7 states captured · 1 missing · Live review required")
        XCTAssertEqual(c.lines.first?.missing, ["Error"])
        let unknown = ReportMaterial(id: "u", reportKey: "k", kind: .mockup, title: "X", url: nil, audience: nil, sourcePath: nil,
                                     version: nil, addedAt: "", provenance: "", selected: true, states: [])
        XCTAssertEqual(ArtifactCompleteness.make(attachments: [], unreadable: [], materials: [unknown]).lines.first?.text,
                       "number of states unknown · Live review required", "no invented total")
        let link = ReportMaterial(id: "l", reportKey: "k", kind: .link, title: "Artifact", url: "https://claude.ai/artifact/x", audience: "owner",
                                  sourcePath: nil, version: nil, addedAt: "", provenance: "", selected: true, states: [])
        XCTAssertTrue(ArtifactCompleteness.make(attachments: [], unreadable: [], materials: [link]).lines[0].text.contains("content was not received"))
    }

    func testChecklistComesFromFactsAndStaysSmall() throws {
        var input = EvidenceCheck.Input()
        input.observed = try counts(files: 1, nonzero: 1)
        input.detail = try detail([cmd("swift build", kind: "build", exit: 1)], files: ["macos/View.swift"])
        input.answer = "Done: the animation of the island is smooth and the build succeeded."
        let e = EvidenceCheck.make(input)
        let list = ReviewChecklist.make(evidence: e, completeness: ArtifactCompleteness(lines: []), changedPaths: ["macos/View.swift"],
                                        answer: input.answer, handoffFiles: 2, imported: false, isLatest: true)
        XCTAssertEqual(list.items.map(\.id), ["ui", "motion", "build", "ci", "paste"])
        XCTAssertLessThanOrEqual(list.items.count, ReviewChecklist.limit)
        let none = ReviewChecklist.make(evidence: EvidenceCheck.make(EvidenceCheck.Input()), completeness: ArtifactCompleteness(lines: []),
                                        changedPaths: [], answer: "Renamed a variable.", handoffFiles: 0, imported: false, isLatest: true)
        XCTAssertTrue(none.items.isEmpty, "nothing invented")
    }
}

@MainActor
final class ReviewCheckMarkTests: XCTestCase {
    func testTicksAreTheUsersAndRememberedPerAnswer() async throws {
        let suite = "PromptRelayTests.p7r.\(UUID().uuidString)"
        let defaults = TestDefaults.named(suite)!
        let board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP7r-\(UUID().uuidString)"))
        defer { board.releaseGlobally(); removeTestDefaults(suite) }
        let core = FakeCore(projects: [project("/p", sessions: 1, last: "2026-10-31T00:00:00.000000Z")])
        core.sessionsByProject["/p"] = [sessionSummary("s", project: "/p", last: "2026-10-31T00:00:00.000000Z", lastTurn: 2)]
        core.turnsBySession["s"] = [turn(1), turn(2)]
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults)
        await m.refreshNow()
        XCTAssertFalse(m.isReviewChecked("ui"), "never ticked by BearlyCopy")
        m.setReviewChecked("ui", true)
        XCTAssertTrue(m.isReviewChecked("ui"))
        m.selectTurn(1)
        XCTAssertFalse(m.isReviewChecked("ui"), "another answer has its own ticks")
        m.selectTurn(2)
        let again = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults)
        await again.refreshNow()
        XCTAssertTrue(again.isReviewChecked("ui"), "remembered")
    }
}

// MARK: - Export Bundle

@MainActor
final class ExportBundleTests: XCTestCase {
    func testBundleHasThePackageTheChosenSnapshotsAndAManifest() async throws {
        let suite = "PromptRelayTests.p7e.\(UUID().uuidString)"
        let defaults = TestDefaults.named(suite)!
        let board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP7e-\(UUID().uuidString)"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-p7e-\(UUID().uuidString)")
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { board.releaseGlobally(); removeTestDefaults(suite); try? FileManager.default.removeItem(at: root) }
        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-31T10:00:00.000000Z")])
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults,
                         reportStore: ReportStore(root: root.appendingPathComponent("store")))
        await m.refreshNow()
        _ = m.importReport(text: "Ответ ✅\n```\ncode\n```", task: "Задача", projectPath: "/a", sessionLabel: "ChatGPT")
        let ref = try XCTUnwrap(m.currentRef)
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for (name, data) in [("plan.md", Data("# План\n".utf8)), ("shot.png", Phase6Tests.png(seed: 3)), ("gone.txt", Data("x".utf8))] {
            try data.write(to: src.appendingPathComponent(name))
            try XCTUnwrap(m.reportStore).addFile(from: src.appendingPathComponent(name), to: ref, source: .you, displayPath: name)
        }
        m.attachmentsVersion += 1
        // One stored snapshot disappears: it is listed as missing, not claimed.
        let gone = try XCTUnwrap(m.attachments(for: ref).first { $0.originalFilename == "gone.txt" })
        try FileManager.default.removeItem(at: try XCTUnwrap(m.attachmentURL(gone)))

        let first = await m.writeBundle(ref, into: out)
        let folder = try XCTUnwrap(first)
        guard case .success(let pack) = await m.buildPack(ref) else { return XCTFail("pack") }
        let written = try String(contentsOf: folder.appendingPathComponent("context.md"), encoding: .utf8)
        XCTAssertEqual(written.replacingOccurrences(of: #"Exported by BearlyCopy at [^\n]*"#, with: "", options: .regularExpression),
                       pack.text.replacingOccurrences(of: #"Exported by BearlyCopy at [^\n]*"#, with: "", options: .regularExpression),
                       "the same package as Copy with Context")
        XCTAssertTrue(written.contains("Ответ ✅\n```\ncode\n```"), "the answer verbatim")
        let original = try Data(contentsOf: src.appendingPathComponent("plan.md"))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("files/plan.md")), original, "snapshot byte for byte")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as! [String: Any]
        let files = manifest["files"] as! [[String: Any]]
        XCTAssertEqual(Set(files.map { "\($0["name"]!)=\($0["status"]!)" }), ["files/plan.md=included", "files/shot.png=included", "files/gone.txt=missing"])
        XCTAssertEqual(manifest["source"] as? String, "imported by you")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("files/gone.txt").path))
        // A second export never overwrites the first.
        let again = await m.writeBundle(ref, into: out)
        let second = try XCTUnwrap(again)
        XCTAssertNotEqual(second, folder)
    }
}
