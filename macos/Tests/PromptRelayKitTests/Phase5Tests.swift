import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// Phase 5: Bearly at rest (R8), typed attachments and mockups (R10, R11),
/// suggestions from what Claude did, the file hand-off, and the clipboard
/// image history (ADR-014).
@MainActor
final class RelayRestingTests: XCTestCase {
    let moods: [MascotState.Mood] = [.idle, .curious, .pleased, .concerned]
    let gazes: [CGPoint] = [.zero, CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: -1), CGPoint(x: 0, y: 1),
                            CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1), CGPoint(x: -1, y: 1), CGPoint(x: 1, y: 1)]

    func testEveryPoseStaysInsideTheEarAndTheHeadStillMoves() {
        for mood in moods {
            for gaze in gazes {
                for lift in [CGFloat(0), RestingPose.hop] {
                    let pose = RestingPose(head: gaze, mood: mood, lift: lift)
                    let points = RestingPose.silhouette(dx: pose.dx, dy: pose.dy, turn: pose.turn, lift: 0,
                                                        earLift: mood == .curious ? 0.025 : 0)
                    for p in points {
                        XCTAssertGreaterThanOrEqual(p.x, 7 - 0.01, "clear of the visible side (\(mood), \(gaze), hop \(lift))")
                        XCTAssertLessThanOrEqual(p.x, 37 + 0.01, "clear of the camera housing (\(mood), \(gaze))")
                        XCTAssertGreaterThanOrEqual(p.y, 1 - 0.01, "below the top of the screen (\(mood), \(gaze), hop \(lift))")
                        XCTAssertLessThanOrEqual(p.y, 31 + 0.01, "above the bottom of the ear")
                    }
                    // Following the pointer: at least half the budget. During the copy hop
                    // the head is also on its way to the centre; it still moves.
                    if lift == 0, gaze != .zero { XCTAssertGreaterThanOrEqual(pose.k, 0.5, "the head keeps moving (\(mood), \(gaze))") }
                    if lift > 0 { XCTAssertGreaterThan(pose.k, 0.2, "the hop is smaller, never gone (\(mood), \(gaze))") }
                }
            }
        }
    }

    func testTheBudgetIsUsedInFullWhereItFits() {
        for gaze in [CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 0, y: -1)] {
            let pose = RestingPose(head: gaze, mood: .idle)
            XCTAssertEqual(pose.k, 1, "\(gaze): no limit needed")
        }
        let left = RestingPose(head: CGPoint(x: -1, y: 0), mood: .idle)
        XCTAssertEqual(left.dx, -RestingPose.maxShift)
        XCTAssertEqual(left.turn, -RestingPose.maxTurn)
        let worst = RestingPose(head: CGPoint(x: -1, y: -1), mood: .curious)
        XCTAssertLessThan(worst.k, 1, "diagonal up with raised ears is limited")
        XCTAssertGreaterThan(worst.k, 0.5, "… but not switched off")
    }

    /// The real SwiftUI view, rendered: no opaque pixel of Bearly outside the
    /// ear's visible area or over the camera housing, in any extreme pose.
    func testRenderedRelayIsNeverClippedAndNeverOverTheCamera() throws {
        let scale: CGFloat = 4
        for gaze in gazes {
            for mood in [MascotState.Mood.idle, .curious] {
                let state = MascotState()
                state.gaze = gaze; state.head = gaze; state.mood = mood
                // Phase 7.2: the real layers (the drawing Bearly uses on screen).
                let image = try XCTUnwrap(RelayRender.image(state, canvas: CGSize(width: 64, height: 40),
                                                            origin: CGPoint(x: RestingPose.origin.x, y: 2), scale: scale))
                let alpha = try alphaMap(image)
                for y in 0..<image.height {
                    for x in 0..<image.width where alpha[y * image.width + x] > 24 {
                        let px = CGFloat(x) / scale, py = CGFloat(y) / scale
                        XCTAssertGreaterThanOrEqual(px, 6, "pixel left of the visible side at \(px),\(py) (\(gaze), \(mood))")
                        XCTAssertLessThan(px, 38, "pixel over the camera housing at \(px),\(py) (\(gaze), \(mood))")
                        XCTAssertGreaterThanOrEqual(py, 0.5, "pixel above the screen at \(px),\(py) (\(gaze), \(mood))")
                        XCTAssertLessThan(py, 32, "pixel below the ear at \(px),\(py)")
                    }
                }
            }
        }
    }

    func testReduceMotionKeepsTheHeadStillButStillShowsFeelings() throws {
        let state = MascotState()
        state.gaze = CGPoint(x: -1, y: -1); state.head = CGPoint(x: -1, y: -1); state.mood = .pleased
        let still = try XCTUnwrap(RelayRender.image(state, reduceMotion: true))
        let neutralState = MascotState(); neutralState.mood = .pleased
        let neutral = try XCTUnwrap(RelayRender.image(neutralState, reduceMotion: true))
        XCTAssertEqual(try alphaMap(still), try alphaMap(neutral),
                       "under Reduce Motion the pointer moves nothing")
    }

    func testBreathingRunsOnTheRenderServerOnlyWhenActive() {
        let view = RelayLayerView(state: MascotState())
        view.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        view.layout()
        view.setBreathing(true)
        let breath = view.layer?.sublayers?.first
        XCTAssertNotNil(breath?.animation(forKey: RelayLayerView.breathKey), "a Core Animation, not redraws")
        XCTAssertEqual(breath?.anchorPoint.y, 0, "breathes from the bottom edge")
        view.setBreathing(false)
        XCTAssertNil(breath?.animation(forKey: RelayLayerView.breathKey))
    }

    private func alphaMap(_ image: CGImage) throws -> [UInt8] {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Row 0 of the buffer is the top of the image.
        return (0..<(w * h)).map { data[$0 * 4 + 3] }
    }
}

@MainActor
final class TypedAttachmentTests: XCTestCase {
    var root: URL!
    var src: URL!
    var store: ReportStore!
    let ref = ReportRef.local(sessionKey: "s1", turn: 2)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pr5-\(UUID().uuidString)")
        src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        store = ReportStore(root: root.appendingPathComponent("app"))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func file(_ name: String, _ data: Data) throws -> URL {
        let url = src.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    static func png(_ color: NSColor = .systemTeal) -> Data {
        let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { r in color.setFill(); r.fill(); return true }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    static func pdf() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil); ctx.setFillColor(NSColor.red.cgColor); ctx.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
        ctx.endPDFPage(); ctx.closePDF()
        return data as Data
    }

    func testFilesAreTypedByContent() throws {
        let md = try store.addFile(from: try file("PHASE5_PROPOSAL.md", Data("# Plan\nПривет".utf8)), to: ref, source: .claude,
                                   displayPath: "docs/PHASE5_PROPOSAL.md")
        XCTAssertEqual(md.effectiveKind, .document)
        XCTAssertEqual(md.effectiveSource, .claude)
        XCTAssertEqual(md.originalPath, "docs/PHASE5_PROPOSAL.md")
        XCTAssertEqual(try store.addFile(from: try file("notes.pdf", Self.pdf()), to: ref).effectiveKind, .pdf)
        XCTAssertEqual(try store.addFile(from: try file("shot.png", Self.png()), to: ref).effectiveKind, .image)
        // A JPEG named .png is an image of its real type; a PNG named .md is an image, not a document.
        XCTAssertEqual(try store.addFile(from: try file("odd.md", Self.png(.systemPink)), to: ref).effectiveKind, .image)
        XCTAssertThrowsError(try store.addFile(from: try file("broken.png", Data("not an image".utf8)), to: ref)) {
            XCTAssertEqual($0 as? ReportStoreError, .damagedImage("broken.png"))
        }
        XCTAssertThrowsError(try store.addFile(from: try file("tool.bin", Data([0, 1, 2, 3])), to: ref)) {
            XCTAssertEqual($0 as? ReportStoreError, .unsupported("tool.bin"))
        }
        let big = String(repeating: "a", count: ReportStore.maxDocumentBytes + 1)
        XCTAssertThrowsError(try store.addFile(from: try file("big.txt", Data(big.utf8)), to: ref), "a text over 1 MB is not kept")
        XCTAssertThrowsError(try store.addFile(from: src.appendingPathComponent("gone.md"), to: ref)) {
            XCTAssertEqual($0 as? ReportStoreError, .unreadable("gone.md"), "a missing file is named, never shown as stored")
        }
        XCTAssertEqual(store.attachments(for: ref).count, 4)
    }

    func testSameBytesAreKeptOnceAndTheSnapshotDoesNotFollowTheOriginal() throws {
        let url = try file("plan.md", Data("v1".utf8))
        let a = try store.addFile(from: url, to: ref)
        let b = try store.addFile(from: url, to: ref)
        XCTAssertEqual(a.id, b.id)
        try Data("v2".utf8).write(to: url)
        XCTAssertEqual(store.originalChanged(a, original: url), true, "changed since attached")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.fileURL(for: a))), Data("v1".utf8), "the snapshot stays")
    }

    func testRecordsWrittenBeforePhase5AreImagesAndSelected() throws {
        let old = #"[{"id":"x","reportKey":"k","originalFilename":"a.png","storedFilename":"x.png","mimeType":"image/png","byteCount":3,"sha256":"s","addedAt":"t","provenance":"Added by you from a file on this Mac"}]"#
        let decoded = try JSONDecoder().decode([ReportAttachment].self, from: Data(old.utf8))
        XCTAssertEqual(decoded.first?.effectiveKind, .image)
        XCTAssertEqual(decoded.first?.effectiveSource, .you)
        XCTAssertEqual(decoded.first?.isSelected, true)
    }

    func mockup(states: [String]) throws -> ReportMaterial {
        try store.addMaterial(ReportMaterial(id: "m1", reportKey: ref.key, kind: .mockup, title: "BearlyCopy Phase 5 Island",
                                             url: "https://claude.ai/artifact/abc", audience: "owner", sourcePath: "…/scratchpad/island.html",
                                             version: nil, addedAt: "t", provenance: "Published by Claude in this turn (Artifact tool)",
                                             selected: true,
                                             states: states.map { MockupState(id: $0, title: $0.capitalized, summary: "\($0) state",
                                                                              interactive: $0 == "resting" ? ["gaze sliders"] : [],
                                                                              status: .namedOnly, attachmentID: nil, failure: nil,
                                                                              selected: true) }))
    }

    func testMockupStatesHaveHonestStatuses() throws {
        var m = try mockup(states: ["resting", "quick-peek", "details"])
        m = try store.setStateImage(from: try file("resting.png", Self.png()), mockupID: m.id, stateID: "resting")
        XCTAssertEqual(m.states[0].status, .captured)
        XCTAssertThrowsError(try store.setStateImage(from: try file("bad.png", Data("x".utf8)), mockupID: m.id, stateID: "details"))
        m = try XCTUnwrap(store.materials(for: ref).first)
        XCTAssertEqual(m.states.map(\.status), [.captured, .namedOnly, .failed])
        XCTAssertNotNil(m.states[2].failure)
        // Replacing a state's image removes the old one.
        let first = try XCTUnwrap(m.states[0].attachmentID)
        m = try store.setStateImage(from: try file("resting2.png", Self.png(.systemOrange)), mockupID: m.id, stateID: "resting")
        XCTAssertNotEqual(m.states[0].attachmentID, first)
        XCTAssertFalse(store.allAttachments().contains { $0.id == first })
        // Removing the mockup removes its state images.
        try store.removeMaterial(m.id)
        XCTAssertTrue(store.allAttachments().filter { $0.mockupID == "m1" }.isEmpty)
    }

    func testTheAttachmentsSectionListsWhatIsAvailableAndWhatIsNot() throws {
        var m = try mockup(states: ["resting", "quick-peek", "details", "clipboard"])
        m = try store.setStateImage(from: try file("a.png", Self.png()), mockupID: m.id, stateID: "resting")
        m = try store.setStateImage(from: try file("b.png", Self.png(.systemPink)), mockupID: m.id, stateID: "quick-peek")
        m.states[3].selected = false
        try store.updateMaterial(m)
        m = try XCTUnwrap(store.materials(for: ref).first)
        let doc = try store.addFile(from: try file("PHASE5_PROPOSAL.md", Data("# Plan".utf8)), to: ref, source: .claude,
                                    displayPath: "docs/PHASE5_PROPOSAL.md")
        let files = store.attachments(for: ref)
        let names = Dictionary(uniqueKeysWithValues: [(m.states[0].attachmentID!, "bearlycopy-phase-5-island-01-resting.png"),
                                                      (m.states[1].attachmentID!, "bearlycopy-phase-5-island-02-quick-peek.png")])
        let section = ReviewPack.attachmentsSection(files, materials: [m], names: names)
        XCTAssertTrue(section.hasPrefix("## Attachments (3 files, sent separately)"), section)
        XCTAssertTrue(section.contains("part of this review only if they are attached"), "never claims they were sent")
        XCTAssertTrue(section.contains("- PHASE5_PROPOSAL.md (docs/PHASE5_PROPOSAL.md) — MD"))
        XCTAssertTrue(section.contains("Visual mockup, review required"))
        XCTAssertTrue(section.contains("private; you probably cannot open it"), "a private link is not presented as available")
        XCTAssertTrue(section.contains("| 1 | bearlycopy-phase-5-island-01-resting.png | Resting | resting state | gaze sliders |"))
        XCTAssertTrue(section.contains("state \"Details\": known by name only; no image"))
        XCTAssertTrue(section.contains("state \"Clipboard\": excluded by you"))
        XCTAssertTrue(section.contains("cannot be judged from still images"))
        XCTAssertFalse(section.contains(doc.storedFilename), "no private file names")
    }

    func testHandoffNamesAndOrder() async throws {
        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-29T16:13:51.000000Z")])
        let model = AppModel(core: core, clipboard: ClipboardService(pasteboard: NSPasteboard(name: .init("pr5-\(UUID().uuidString)"))),
                             dataDirectory: nil, reportStore: store)
        var m = try mockup(states: ["resting", "quick-peek"])
        m = try store.setStateImage(from: try file("x.png", Self.png()), mockupID: m.id, stateID: "quick-peek")
        m = try store.setStateImage(from: try file("y.png", Self.png(.systemPink)), mockupID: m.id, stateID: "resting")
        _ = try store.addFile(from: try file("shot.png", Self.png(.systemPurple)), to: ref)
        _ = try store.addFile(from: try file("PLAN.md", Data("p".utf8)), to: ref)
        let ordered = model.handoffAttachments(for: ref)
        let names = model.handoffNames(for: ref)
        XCTAssertEqual(ordered.map { names[$0.id] ?? $0.originalFilename },
                       ["PLAN.md", "bearlycopy-phase-5-island-01-resting.png", "bearlycopy-phase-5-island-02-quick-peek.png", "shot.png"],
                       "documents, then states in order, then images")
        let urls = try store.handoffFiles(for: ordered, names: names)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["PLAN.md", "bearlycopy-phase-5-island-01-resting.png",
                                                       "bearlycopy-phase-5-island-02-quick-peek.png", "shot.png"])
    }

    func testDeclaredStatesAreReadAsJSONOnly() throws {
        let html = """
        <title>X</title><script type="application/json" id="prompt-relay-states">
        {"version":1,"title":"Island","states":[{"id":"resting","title":"Resting","description":"d","interactive":["slider"]},
        {"id":"resting","title":"Dup"},{"id":"details","title":"Details"}]}
        </script><script>alert(1)</script>
        """
        let decl = try XCTUnwrap(MockupStates.declared(inHTML: html))
        XCTAssertEqual(decl.title, "Island")
        XCTAssertEqual(decl.states.map(\.id), ["resting", "details"], "duplicates dropped")
        XCTAssertNil(MockupStates.declared(inHTML: "<html>no declaration</html>"))
        XCTAssertNil(MockupStates.declared(inHTML: #"<script id="prompt-relay-states">{not json</script>"#))
    }
}

@MainActor
final class SuggestionTests: XCTestCase {
    func observed(shown: [String] = [], changed: [String] = [], artifacts: [ObservedArtifact] = []) throws -> ObservedDetail {
        let json: [String: Any] = [
            "commands": [], "notifications": 0, "shown_files": shown,
            "files_changed": changed.map { ["path": $0, "tools": ["Write"], "count": 1] },
            "artifacts": artifacts.map { ["title": $0.title as Any, "url": $0.url as Any, "audience": "owner", "source_path": $0.sourcePath as Any] },
        ]
        return try JSONDecoder().decode(ObservedDetail.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testOnlyWhatClaudeShowedOrNamedIsSuggested() throws {
        let root = "/Users/me/prompt-relay"
        let detail = try observed(shown: ["/tmp/x/red.png"],
                                  changed: ["\(root)/docs/PHASE5_PROPOSAL.md", "\(root)/macos/Sources/Other.swift", "\(root)/docs/STATUS.md"],
                                  artifacts: [ObservedArtifact(title: "Island", url: "https://claude.ai/artifact/a", audience: "owner",
                                                               path: nil, sourcePath: "/tmp/x/island.html", at: nil)])
        let answer = "Записал [docs/PHASE5_PROPOSAL.md](docs/PHASE5_PROPOSAL.md). Updated STATUS.mdx notes."
        let out = AppModel.suggestions(observed: detail, answer: answer, root: root, addedPaths: [], addedURLs: [],
                                       exists: { $0 != "/tmp/x/red.png" })
        XCTAssertEqual(out.map(\.title), ["red.png", "Island", "PHASE5_PROPOSAL.md"],
                       "shown, published and named; Other.swift and STATUS.md (only 'STATUS.mdx' is named) are not")
        XCTAssertFalse(out[0].exists, "a file that disappeared is marked, not offered as stored")
        let again = AppModel.suggestions(observed: detail, answer: answer, root: root, addedPaths: ["docs/PHASE5_PROPOSAL.md"],
                                         addedURLs: ["https://claude.ai/artifact/a"], exists: { _ in true })
        XCTAssertEqual(again.map(\.title), ["red.png"], "what was added is not suggested again")
    }

    /// Phase 5.11 e2e (real turn): `blue.png` was made by a Bash script, so no
    /// Edit/Write event names it; the answer does, and the file is in the project.
    func testNamedProjectFileMadeByAScriptIsSuggestedWithAnHonestReason() throws {
        let root = "/Users/me/e2e"
        let detail = try observed(changed: ["\(root)/calc.py", "\(root)/REPORT.md"])
        let answer = "5. I wrote `blue.png`, a valid 8×8 PNG.\n6. I wrote `REPORT.md`.\nSee also ../outside.png, /etc/x.png, missing.pdf and v1.2."
        let present: Set<String> = ["\(root)/blue.png", "\(root)/REPORT.md", "/Users/me/outside.png", "/etc/x.png"]
        let out = AppModel.suggestions(observed: detail, answer: answer, root: root, addedPaths: [], addedURLs: [],
                                       exists: present.contains)
        XCTAssertEqual(out.map(\.title), ["REPORT.md", "blue.png"], "outside the project and missing files are not offered")
        XCTAssertEqual(out[1].reason, "Named in the answer; in the project, not seen being written")
        XCTAssertEqual(AppModel.suggestions(observed: detail, answer: answer, root: root, addedPaths: ["blue.png"],
                                            addedURLs: [], exists: present.contains).map(\.title), ["REPORT.md"])
    }

    func testPathsAreShownWithoutTheUserName() {
        XCTAssertEqual(AppModel.displayPath("/Users/me/p/docs/a.md", root: "/Users/me/p"), "docs/a.md")
        XCTAssertEqual(AppModel.displayPath("/private/tmp/claude-501/x/scratchpad/island.html", root: "/Users/me/p"), "…/scratchpad/island.html")
    }
}

@MainActor
final class ClipboardImageHistoryTests: XCTestCase {
    var board: NSPasteboard!
    var folder: URL!

    override func setUp() async throws {
        board = NSPasteboard(name: NSPasteboard.Name("pr-clip-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pr-clip-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: folder)
    }

    func put(_ data: Data, type: NSPasteboard.PasteboardType = .png, extra: NSPasteboard.PasteboardType? = nil) {
        board.clearContents()
        let item = NSPasteboardItem()
        item.setData(data, forType: type)
        if let extra { item.setData(Data(), forType: extra) }
        board.writeObjects([item])
    }

    func testOffByDefaultAndNothingPolledWhileOff() {
        let history = ClipboardImageHistory(folder: folder, pasteboard: board)
        XCTAssertFalse(history.isEnabled)
        XCTAssertFalse(history.isPolling)
        put(TypedAttachmentTests.png())
        history.poll()   // even if asked, it was off: the change was before it was on
        history.setEnabled(true)
        XCTAssertTrue(history.isPolling)
        history.poll()
        XCTAssertTrue(history.items.isEmpty, "what was on the clipboard before turning it on is not taken")
        history.setEnabled(false)
        XCTAssertFalse(history.isPolling, "off: no timer")
    }

    func testOnlyImagesAreKeptAndPasswordsAndOwnCopiesAreSkipped() {
        let history = ClipboardImageHistory(folder: folder, pasteboard: board)
        history.setEnabled(true)
        board.clearContents(); board.setString("my password 123", forType: .string)
        history.poll()
        XCTAssertTrue(history.items.isEmpty, "text is never kept")
        put(TypedAttachmentTests.png(), extra: .init("org.nspasteboard.ConcealedType"))
        history.poll()
        XCTAssertTrue(history.items.isEmpty, "concealed items (password managers) are skipped")
        put(TypedAttachmentTests.png(.systemPink), extra: ClipboardImageHistory.ownType)
        history.poll()
        XCTAssertTrue(history.items.isEmpty, "BearlyCopy's own copies are skipped")
        put(TypedAttachmentTests.png(.systemGreen))
        history.poll()
        XCTAssertEqual(history.items.count, 1)
        put(TypedAttachmentTests.png(.systemGreen))
        history.poll()
        XCTAssertEqual(history.items.count, 1, "the same image again is not a duplicate")
        let tiff = NSImage(data: TypedAttachmentTests.png(.systemBlue))!.tiffRepresentation!
        put(tiff, type: .tiff)
        history.poll()
        XCTAssertEqual(history.items.count, 2, "a TIFF screenshot is kept (as PNG)")
        XCTAssertTrue(ReportStore.imageType(of: try! Data(contentsOf: history.url(for: history.items[0])))?.conforms(to: .png) ?? false)
        history.setEnabled(false)
    }

    func testAtMostTenExpiryAndDeletion() {
        let history = ClipboardImageHistory(folder: folder, pasteboard: board)
        history.setEnabled(true)
        let colors: [NSColor] = (0..<13).map { NSColor(hue: CGFloat($0) / 13, saturation: 1, brightness: 1, alpha: 1) }
        for c in colors { put(TypedAttachmentTests.png(c)); history.poll() }
        XCTAssertEqual(history.items.count, ClipboardImageHistory.limit)
        let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(files?.count, ClipboardImageHistory.limit, "older images are deleted from disk too")
        history.remove(history.items[0])
        XCTAssertEqual(history.items.count, ClipboardImageHistory.limit - 1)
        history.prune(now: Date().addingTimeInterval(history.retention + 1))
        XCTAssertTrue(history.items.isEmpty, "expired after the retention period")
        put(TypedAttachmentTests.png(.yellow)); history.poll()
        history.clearAll()
        XCTAssertTrue(history.items.isEmpty)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".png") })?.count, 0)
        history.setEnabled(false)
    }

    func testPromptRelaysOwnCopyIsMarked() throws {
        let service = ClipboardService(pasteboard: board)
        try service.copy("text")
        XCTAssertTrue(board.types?.contains(ClipboardImageHistory.ownType) ?? false)
        let history = ClipboardImageHistory(folder: folder, pasteboard: board)
        history.setEnabled(true)
        try service.copy("again")
        history.poll()
        XCTAssertTrue(history.items.isEmpty)
        history.setEnabled(false)
    }
}

/// Phase 5.11: a turn Claude Code started itself is never shown as the user's request.
final class RequestOriginTests: XCTestCase {
    func turn(_ extra: [String: Any]) throws -> Turn {
        var json: [String: Any] = [
            "index": 2, "status": "stop_received", "link": "prompt_id",
            "request": ["preview": "<system-reminder>A session finished</system-reminder>", "truncated": false,
                        "char_count": 52, "utf8_bytes": 52, "prompt_id": "p2", "received_at": "2026-10-30T14:07:24Z"],
            "final_response": NSNull(), "response_event_count": 1, "candidate_request_turns": [],
            "background_tasks": NSNull(), "error": NSNull(),
        ]
        json.merge(extra) { $1 }
        return try JSONDecoder().decode(Turn.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testAutomatedTurnShowsTheEarlierUserRequest() throws {
        let t = try turn(["request_origin": "automated",
                          "earlier_user_request": ["turn": 1, "preview": "Implement Phase 5", "truncated": false,
                                                   "char_count": 17, "utf8_bytes": 17, "prompt_id": "p1",
                                                   "received_at": "2026-10-30T14:05:51Z"]])
        XCTAssertEqual(t.requestOrigin, .automated)
        XCTAssertEqual(t.userRequestPreview, "Implement Phase 5")
        XCTAssertEqual(t.earlierUserRequest?.turn, 1)
    }

    func testAutomatedTurnWithoutEarlierRequestShowsNone() throws {
        let t = try turn(["request_origin": "automated", "earlier_user_request": NSNull()])
        XCTAssertNil(t.userRequestPreview)
    }

    func testUserAndOlderCoreKeepTheRequest() throws {
        XCTAssertEqual(try turn(["request_origin": "user_pasted"]).requestOrigin, .userPasted)
        let old = try turn([:])
        XCTAssertNil(old.requestOrigin)
        XCTAssertEqual(old.userRequestPreview, "<system-reminder>A session finished</system-reminder>")
        XCTAssertEqual(try turn(["request_origin": "from_the_future"]).requestOrigin, .unknown)
    }

    func testDisplayDropsAutomatedBlocksButKeepsTheText() throws {
        XCTAssertEqual(Wording.requestForDisplay("<system-reminder>\nLinked sessions\n</system-reminder>\n\nRun it").text, "Run it")
        XCTAssertEqual(Wording.requestForDisplay("Explain `<system-reminder>` tags").text, "Explain `<system-reminder>` tags")
        var request = try turn(["request_origin": "unknown"]).request
        XCTAssertEqual(request?.readablePreview, "<system-reminder>A session finished</system-reminder>",
                       "only automated blocks: the raw text is shown rather than nothing")
        request = try turn(["request": ["preview": "<system-reminder>cut off", "display_preview": "Run the e2e steps",
                                        "truncated": true, "char_count": 900, "utf8_bytes": 900]]).request
        XCTAssertEqual(request?.readablePreview, "Run the e2e steps", "the Core's cleaned start wins over a cut-off preview")
    }

    /// Real e2e (2026-10-30): a file named in the answer but made by a script
    /// was labelled "prepared by Claude in this turn [Confirmed locally]".
    func testNamedFileIsNotClaimedAsConfirmed() {
        var a = ReportAttachment(id: "a", reportKey: "k", originalFilename: "blue.png", storedFilename: "a.png", mimeType: "image/png",
                                 byteCount: 73, sha256: "s", addedAt: "t", provenance: "p")
        a.source = .named
        XCTAssertEqual(ReviewPack.origin(a), "named in the agent's answer and found in the project; not seen being written in this turn [Reported by agent]")
        a.source = .claude
        XCTAssertTrue(ReviewPack.origin(a).hasSuffix("[Confirmed locally]"))
    }

    func testFailedCommandCountDecodes() throws {
        let json = #"{"tool_events":6,"runs_exit_zero":1,"runs_nonzero":0,"runs_unknown":0,"files_changed":2,"background_started":0,"commands_nonzero":1}"#
        XCTAssertEqual(try JSONDecoder().decode(ObservedCounts.self, from: Data(json.utf8)).commandsNonzero, 1)
    }
}
