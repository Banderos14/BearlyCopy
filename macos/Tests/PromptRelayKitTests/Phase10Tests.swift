import AppKit
import Foundation
import Testing
@testable import PromptRelayKit

/// Phase 10: window snapshots in memory only; a minimal notch indicator.
@Suite(.serialized)
@MainActor
struct Phase10SnapshotTests {
    private func board() -> NSPasteboard { NSPasteboard(name: .init("PromptRelay10-\(UUID().uuidString)")) }
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private func ago(_ s: TimeInterval) -> String { Self.iso.string(from: Date(timeIntervalSinceNow: -s)) }
    private func tempRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("pr10-" + UUID().uuidString) }

    /// Every file under the store's root, recursively (to prove nothing was written).
    private func files(under root: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { ($0 as? URL).flatMap { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true ? $0.lastPathComponent : nil } }
    }

    @Test func aSnapshotIsListedSelectedAndNeverWritten() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ReportStore(root: root)
        let ref = ReportRef.local(sessionKey: "s", turn: 2)
        let png = TypedAttachmentTests.png(.red)
        let a = try store.addEphemeralImage(png, name: "Final window.png", to: ref, source: .windowCapture)
        #expect(a.isInMemory && a.isSelected && a.effectiveKind == .image)
        #expect(store.attachments(for: ref).map(\.id) == [a.id])
        #expect(store.data(for: a) == png && store.isAvailable(a))
        #expect(store.fileURL(for: a) == nil, "never a file")
        // The same bytes again (a redelivered hook) are kept once.
        #expect(try store.addEphemeralImage(png, name: "again.png", to: ref, source: .windowCapture).id == a.id)
        // Persistent work next to it never writes the snapshot into the index.
        let doc = root.appendingPathComponent("../pr10-doc-\(UUID().uuidString).md").standardizedFileURL
        try Data("# hi".utf8).write(to: doc); defer { try? FileManager.default.removeItem(at: doc) }
        _ = try store.addFile(from: doc, to: ref)
        try store.setSelected(a.id, false)
        #expect(store.attachments(for: ref).first { $0.id == a.id }?.isSelected == false)
        let index = try String(contentsOf: root.appendingPathComponent("attachments.json"), encoding: .utf8)
        #expect(!index.contains(a.id), "the index holds only persistent records")
        #expect(files(under: root).filter { $0.hasSuffix(".png") }.isEmpty, "no image file anywhere under the data dir")
        // Hand-off copies (drag/Finder) are never made for it.
        #expect(try store.handoffFiles(for: [a]).isEmpty)
        // A new store (an app restart) does not know it.
        #expect(ReportStore(root: root).attachments(for: ref).allSatisfy { !$0.isInMemory })
        try store.removeAttachment(a.id)
        #expect(!store.isAvailable(a) && store.attachments(for: ref).count == 1)
    }

    @Test func limitsDropTheOldestByCountBytesAndAge() throws {
        let store = ReportStore(root: tempRoot())
        var now = Date()
        store.clock = { now }
        store.ephemeralLimits = .init(maxCount: 2, maxTotalBytes: 10_000_000, maxAge: 60)
        let ref = ReportRef.local(sessionKey: "s", turn: 1)
        let a = try store.addEphemeralImage(TypedAttachmentTests.png(.red), name: "a.png", to: ref, source: .windowSnapshot)
        let b = try store.addEphemeralImage(TypedAttachmentTests.png(.green), name: "b.png", to: ref, source: .windowSnapshot)
        let c = try store.addEphemeralImage(TypedAttachmentTests.png(.blue), name: "c.png", to: ref, source: .windowSnapshot)
        #expect(store.attachments(for: ref).map(\.id) == [b.id, c.id], "count limit: the oldest goes")
        #expect(!store.isAvailable(a))
        now = now.addingTimeInterval(61)
        #expect(store.attachments(for: ref).isEmpty, "age limit")
        #expect(store.ephemeralBytes == 0)
        store.ephemeralLimits = .init(maxCount: 10, maxTotalBytes: 10, maxAge: 60)
        #expect(throws: ReportStoreError.self) { try store.addEphemeralImage(TypedAttachmentTests.png(.red), name: "big.png", to: ref, source: .windowSnapshot) }
        #expect(throws: ReportStoreError.self) { try store.addEphemeralImage(Data("not an image".utf8), name: "x.png", to: ref, source: .windowSnapshot) }
    }

    @Test func pixelSizeIsCappedKeepingTheAspect() {
        let small = WindowCapture.pixelSize(points: CGSize(width: 800, height: 600), scale: 2)
        #expect(small.width == 1600 && small.height == 1200)
        let huge = WindowCapture.pixelSize(points: CGSize(width: 3008, height: 1692), scale: 2)
        #expect(huge.width == 3200 && huge.height == 1800)
    }

    @Test func copyImageAndCopyWithImagesUseDataNotFiles() throws {
        let b = board(); defer { b.releaseGlobally() }
        let clipboard = ClipboardService(pasteboard: b)
        let png = TypedAttachmentTests.png(.red)
        try clipboard.copyImage(ClipboardImage(data: png))
        #expect(b.data(forType: .png) == png)
        #expect(b.string(forType: .fileURL) == nil, "no file URL for an in-memory image")
        try clipboard.copy("verbatim\n text", imageItems: [ClipboardImage(data: png)])
        #expect(b.string(forType: .string) == "verbatim\n text")
        #expect(b.pasteboardItems?.count == 2)
        #expect(b.pasteboardItems?[1].data(forType: .png) == png && b.pasteboardItems?[1].string(forType: .fileURL) == nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pr10-\(UUID().uuidString).md")
        try Data("x".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        try clipboard.copyFiles([file], images: [ClipboardImage(data: png)])
        #expect(b.pasteboardItems?.count == 2)
        let urls = (b.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        #expect(urls.map(\.standardizedFileURL) == [file.standardizedFileURL])
    }

    final class FakeCapture: WindowCapturing {
        var result: Result<WindowCapture.Shot, Error>?
        var hasSource = false
        var sourceCaptures = 0
        var color: NSColor = .blue
        func captureWindow(completion: @escaping @MainActor (Result<WindowCapture.Shot, Error>?) -> Void) { completion(result) }
        func pickWindow(completion: @escaping @MainActor (Result<PickedWindow, Error>?) -> Void) {
            hasSource = true; completion(.success(PickedWindow(handle: "h1", label: "window")))
        }
        func capture(_ window: PickedWindow) async throws -> WindowCapture.Shot {
            sourceCaptures += 1
            guard hasSource else { throw WindowCaptureError.noSource }
            return .init(png: TypedAttachmentTests.png(color), label: "Window")
        }
        func forget(_ window: PickedWindow) { hasSource = false }
    }

    private func codex(_ turns: Int, _ at: String) -> SessionSummary {
        Phase93Tests.session("codex", provider: "codex", host: "xcode", project: "/a", last: at, answeredAt: at, turns: turns)
    }

    /// Final Answer → snapshot in memory → selected → Quick Peek Copy with
    /// Context → hand-off step 2 puts the image on the clipboard as data.
    @Test func autoSnapshotReachesTheHandoffWithoutDetailsOrFiles() async throws {
        let suite = "PromptRelay10h.\(UUID().uuidString)"
        let defaults = try #require(TestDefaults.named(suite))
        let root = tempRoot()
        let b = board(); defer { b.releaseGlobally(); removeTestDefaults(suite); try? FileManager.default.removeItem(at: root) }
        let core = FakeCore(projects: [project("/a", sessions: 1, last: ago(300))])
        core.showResult = { [unowned core] key, i in
            .success(CoreResult(data: ShowData(session: try! core.session(key), turn: turn(i, text: "answer \(i)")), warnings: []))
        }
        core.sessionsByProject["/a"] = [codex(1, ago(300))]
        core.turnsBySession["codex"] = [turn(1, at: ago(300))]
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: b), dataDirectory: nil, stateDefaults: defaults,
                         reportStore: ReportStore(root: root))
        let fake = FakeCapture()
        m.windowCapture = fake
        m.captureSettle = .immediate
        m.captureNow = { Date().addingTimeInterval(-60) }
        m.autoScreenshotsInHandoff = true                     // Phase 14: selected only when the user says so
        await m.refreshNow()
        m.autoCaptureFinalWindow = true
        m.chooseAutoCaptureWindow()
        core.sessionsByProject["/a"] = [codex(2, ago(10))]
        core.turnsBySession["codex"] = [turn(1, at: ago(300)), turn(2, at: ago(10))]
        await m.refreshNow()
        await m.waitForAutoCaptures()
        // The same answer refreshed again (redelivery, FSEvents) is not captured twice.
        fake.color = .green
        await m.refreshNow()
        await m.refreshNow()
        await m.waitForAutoCaptures()
        let ref = ReportRef.local(sessionKey: "codex", turn: 2)
        let shots = m.attachments(for: ref)
        #expect(fake.sourceCaptures == 1 && shots.count == 1 && shots[0].isInMemory && shots[0].isSelected)
        #expect(m.isAttachmentAvailable(shots[0]))
        #expect(files(under: root).filter { $0.hasSuffix(".png") }.isEmpty)
        // Drag carries image data, not a file.
        guard case .image(let img)? = m.dragPayloads(for: shots).first else { Issue.record("expected image data"); return }
        #expect(img.file == nil)
        #expect(m.handoffAttachments(for: ref).map(\.id) == [shots[0].id])
        // Unchecked: not in the hand-off.
        m.setSelected(shots[0], false)
        #expect(m.handoffAttachments(for: ref).isEmpty)
        m.setSelected(shots[0], true)
        m.removeAttachment(shots[0])
        #expect(m.attachments(for: ref).isEmpty)
    }

    @Test func copyAttachmentOfAnExpiredSnapshotFailsHonestly() async throws {
        let root = tempRoot()
        let b = board(); defer { b.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let core = FakeCore(projects: [project("/repo", sessions: 1, last: ago(60))])
        core.sessionsByProject["/repo"] = [sessionSummary("s", project: "/repo", last: ago(60))]
        core.turnsBySession["s"] = [turn(1, at: ago(60))]
        let store = ReportStore(root: root)
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: b), dataDirectory: nil, reportStore: store)
        await m.refreshNow()
        let fake = FakeCapture()
        fake.result = .success(.init(png: TypedAttachmentTests.png(.red), label: "Window"))
        m.windowCapture = fake
        m.captureFinalWindow()
        let shot = try #require(m.attachments(for: m.currentRef).first)
        b.clearContents(); b.setString("user text", forType: .string)
        m.copyAttachment(shot)
        #expect(b.data(forType: .png) != nil)
        store.clearEphemeral()
        b.clearContents(); b.setString("user text", forType: .string)
        m.copyAttachment(shot)
        #expect(b.string(forType: .string) == "user text", "a failed copy leaves the clipboard alone")
    }
}

@Suite(.serialized)
@MainActor
struct Phase10IndicatorTests {
    private func board() -> NSPasteboard { NSPasteboard(name: .init("PromptRelay10i-\(UUID().uuidString)")) }
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private func ago(_ s: TimeInterval) -> String { Self.iso.string(from: Date(timeIntervalSinceNow: -s)) }

    /// Several conversations finish; the island opens on Latest: the notch
    /// dot goes, the other conversations stay unread in Project and Session,
    /// and only a newer answer lights the dot again — also after a restart.
    @Test func openingTheIslandClearsTheNotchButNotPerProjectUnread() async throws {
        let suite = "PromptRelay10n.\(UUID().uuidString)"
        let defaults = try #require(TestDefaults.named(suite))
        let b = board(); defer { b.releaseGlobally(); removeTestDefaults(suite) }
        let core = FakeCore(projects: [project("/repo", sessions: 3, last: ago(600))])
        core.showResult = { [unowned core] key, i in
            .success(CoreResult(data: ShowData(session: try! core.session(key), turn: turn(i, text: "\(key)#\(i)")), warnings: []))
        }
        func s(_ key: String, _ turns: Int, _ at: String) -> SessionSummary {
            Phase93Tests.session(key, provider: "claude_code", host: "cli", project: "/repo", last: at, answeredAt: at, turns: turns)
        }
        let t0 = ago(600)
        core.sessionsByProject["/repo"] = [s("a", 1, t0), s("b", 1, t0), s("c", 1, t0)]
        for k in ["a", "b", "c"] { core.turnsBySession[k] = [turn(1, at: t0)] }
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: b), dataDirectory: nil, stateDefaults: defaults)
        await m.refreshNow()                                  // baseline
        core.sessionsByProject["/repo"] = [s("a", 2, ago(30)), s("b", 2, ago(40)), s("c", 2, ago(50))]
        let ta = ago(30), tb = ago(40), tc = ago(50)
        core.sessionsByProject["/repo"] = [s("a", 2, ta), s("b", 2, tb), s("c", 2, tc)]
        for (k, t) in [("a", ta), ("b", tb), ("c", tc)] { core.turnsBySession[k] = [turn(1, at: t0), turn(2, at: t)] }
        await m.refreshNow()
        guard case .ready(let n, _, _) = m.readyIndicator else { Issue.record("expected the dot"); return }
        #expect(n == 3)
        m.surfaceAppeared()
        await m.revealReadyAnswer()
        #expect(m.readyIndicator == .none, "opened: no lingering dot or count")
        #expect(m.newAnswerCount(inProject: "/repo") == 2, "the other two stay unread in Project and Session: \(m.newAnswerCount(inProject: "/repo")) \(String(describing: m.readyAnswer?.projectPath))")
        m.surfaceDisappeared()
        // Restart: still no dot for what was already looked at.
        let m2 = AppModel(core: core, clipboard: ClipboardService(pasteboard: b), dataDirectory: nil, stateDefaults: defaults)
        await m2.refreshNow()
        #expect(m2.readyIndicator == .none)
        // A newer final answer: the dot again.
        let t5 = ago(5)
        core.sessionsByProject["/repo"] = [s("b", 3, t5), s("a", 2, ta), s("c", 2, tc)]
        core.turnsBySession["b"] = [turn(1, at: t0), turn(2, at: tb), turn(3, at: t5)]
        await m2.refreshNow()
        guard case .ready = m2.readyIndicator else { Issue.record("a newer answer lights it"); return }
    }
}
