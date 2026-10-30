import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import PromptRelayKit

/// Images kept with a report and handed to other apps: what is stored, what
/// is refused, how removal works, and what exactly goes on the pasteboard.
@MainActor
final class AttachmentHandoffTests: XCTestCase {
    var root: URL!
    var src: URL!
    var board: NSPasteboard!
    var suite: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-handoff-\(UUID().uuidString)")
        src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayHandoff-\(UUID().uuidString)"))
        suite = "PromptRelayTests.handoff.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("app").path)
        try? FileManager.default.removeItem(at: root)
    }

    var store: ReportStore { ReportStore(root: root.appendingPathComponent("app")) }

    func image(_ name: String, color: NSColor = .systemTeal, type: NSBitmapImageRep.FileType = .png) throws -> URL {
        let drawing = NSImage(size: NSSize(width: 24, height: 16), flipped: false) { color.setFill(); $0.fill(); return true }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(drawing.tiffRepresentation)))
        let url = src.appendingPathComponent(name)
        try XCTUnwrap(rep.representation(using: type, properties: [:])).write(to: url)
        return url
    }

    // MARK: Store

    func testOnlyRealImagesAreKeptTypedByTheirContent() throws {
        let local = ReportRef.local(sessionKey: "s", turn: 1)
        let damaged = src.appendingPathComponent("broken.png")
        try Data("not a png at all".utf8).write(to: damaged)
        XCTAssertThrowsError(try store.addAttachment(from: damaged, to: local)) {
            XCTAssertEqual($0 as? ReportStoreError, .damagedImage("broken.png"))
        }
        let notes = src.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: notes)
        XCTAssertThrowsError(try store.addAttachment(from: notes, to: local)) {
            XCTAssertEqual($0 as? ReportStoreError, .notAnImage("notes.txt"))
        }
        // A JPEG named .png is stored as what it is.
        let disguised = try image("photo.png", type: .jpeg)
        let a = try store.addAttachment(from: disguised, to: local)
        XCTAssertEqual(a.mimeType, "image/jpeg")
        XCTAssertTrue(a.storedFilename.hasSuffix(".jpeg"))
        XCTAssertEqual(a.originalFilename, "photo.png", "the original name is kept")
    }

    func testAFileWithoutReadPermissionIsReportedAsSuch() throws {
        let locked = try image("locked.png")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path) }
        XCTAssertThrowsError(try store.addAttachment(from: locked, to: .imported(id: "i"))) {
            XCTAssertEqual($0 as? ReportStoreError, .noPermission("locked.png"))
        }
        XCTAssertEqual(AppModel.message(for: .noPermission("locked.png"), file: "locked.png"), "locked.png could not be read: no permission")
    }

    func testTheOriginalIsNeverChangedAndRecordsSurviveARestart() throws {
        let original = try image("shot.png")
        let before = try Data(contentsOf: original)
        let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
        let local = ReportRef.local(sessionKey: "s", turn: 1), imported = ReportRef.imported(id: "cloud")
        let first = try store.addAttachment(from: original, to: local)
        XCTAssertEqual(try store.addAttachment(from: original, to: local).id, first.id, "the same image twice: kept once")
        let other = try store.addAttachment(from: original, to: imported)
        XCTAssertNotEqual(other.id, first.id, "a local answer and a cloud import keep their own records")
        XCTAssertEqual(try Data(contentsOf: original), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: original.path)[.modificationDate] as? Date,
                       attributes[.modificationDate] as? Date)
        // A new store over the same folder: what a restart sees.
        let reopened = ReportStore(root: root.appendingPathComponent("app"))
        XCTAssertEqual(reopened.attachments(for: local).map(\.id), [first.id])
        XCTAssertEqual(reopened.attachments(for: imported).map(\.id), [other.id])
        XCTAssertNotNil(reopened.fileURL(for: first))
    }

    func testRemovingUnlinksOneImageAndKeepsFilesOthersUse() throws {
        let s = store
        let ref = ReportRef.imported(id: "r")
        let a = try s.addAttachment(from: try image("a.png", color: .red), to: ref)
        let b = try s.addAttachment(from: try image("b.png", color: .blue), to: ref)
        // Another record that shares a's stored file (an older or edited index).
        let twin = ReportAttachment(id: "twin", reportKey: ReportRef.imported(id: "other").key, originalFilename: "a.png",
                                    storedFilename: a.storedFilename, mimeType: a.mimeType, byteCount: a.byteCount,
                                    sha256: a.sha256, addedAt: a.addedAt, provenance: a.provenance)
        let index = root.appendingPathComponent("app/attachments.json")
        try JSONEncoder().encode(s.allAttachments() + [twin]).write(to: index)

        try s.removeAttachment(a.id)
        XCTAssertEqual(s.attachments(for: ref).map(\.id), [b.id], "only that image is unlinked")
        XCTAssertNotNil(s.fileURL(for: twin), "the file another record uses stays")
        XCTAssertNotNil(s.fileURL(for: b))
        try s.removeAttachment("twin")
        XCTAssertNil(s.fileURL(for: twin), "the last user gone: the file goes too")
        XCTAssertEqual(ReportStore(root: root.appendingPathComponent("app")).attachments(for: ref).map(\.id), [b.id],
                       "the removal is persistent")
    }

    func testAStoredNameNeverResolvesOutsideTheFolder() throws {
        let s = store
        _ = try s.addAttachment(from: try image("a.png"), to: .imported(id: "r"))
        for bad in ["../../secret.png", "/etc/hosts", ".hidden", "", "a:b.png"] {
            let rogue = ReportAttachment(id: "x", reportKey: "k", originalFilename: "x.png", storedFilename: bad, mimeType: "image/png",
                                         byteCount: 1, sha256: "s", addedAt: "t", provenance: "p")
            XCTAssertNil(s.fileURL(for: rogue), bad)
        }
    }

    func testRemovalFailureIsShownAndTheTextIsUntouched() async throws {
        let model = AppModel(core: FakeCore(projects: []), clipboard: ClipboardService(pasteboard: board), dataDirectory: nil,
                             stateDefaults: UserDefaults(suiteName: suite), reportStore: store)
        await model.refreshNow()
        let text = "# Отчёт\n\n```swift\nlet x = 1\n```\n"
        _ = model.importReport(text: text, task: nil, projectPath: nil, sessionLabel: nil)
        let ref = try XCTUnwrap(model.currentRef)
        model.addAttachments([try image("one.png", color: .red), try image("two.png", color: .green)], to: ref)
        let attachments = model.attachments(for: ref)
        XCTAssertEqual(attachments.map(\.originalFilename), ["one.png", "two.png"])

        let index = root.appendingPathComponent("app/attachments.json")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: index.path)   // the index cannot be saved
        model.removeAttachment(attachments[0])
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: index.path)
        XCTAssertEqual(model.attachmentMessage, "one.png could not be removed. Try again.")
        XCTAssertEqual(model.attachments(for: ref).count, 2, "nothing half-removed")

        model.removeAttachment(attachments[0])
        XCTAssertNil(model.attachmentMessage)
        XCTAssertEqual(model.attachments(for: ref).map(\.originalFilename), ["two.png"])
        XCTAssertEqual(model.selectedImport?.text, text, "the report's text never changes")
    }

    // MARK: Pasteboard

    func testCopyImageGivesImageDataAndTheFileUnderItsOriginalName() async throws {
        let model = AppModel(core: FakeCore(projects: []), clipboard: ClipboardService(pasteboard: board), dataDirectory: nil,
                             stateDefaults: UserDefaults(suiteName: suite), reportStore: store)
        _ = model.importReport(text: "Report", task: nil, projectPath: nil, sessionLabel: nil)
        let ref = try XCTUnwrap(model.currentRef)
        model.addAttachments([try image("Снимок экрана 1.png"), try image("two.png", color: .red)], to: ref)
        let attachments = model.attachments(for: ref)

        model.copyAttachment(attachments[0])
        XCTAssertEqual(model.copyFeedback, .copied(.image, characters: 0))
        let item = try XCTUnwrap(board.pasteboardItems?.first)
        XCTAssertEqual(board.pasteboardItems?.count, 1)
        XCTAssertNotNil(item.data(forType: NSPasteboard.PasteboardType(UTType.png.identifier)), "PNG data")
        XCTAssertNotNil(item.data(forType: .tiff), "TIFF for apps that read only that")
        let file = try XCTUnwrap(item.string(forType: .fileURL).flatMap(URL.init(string:)))
        XCTAssertEqual(file.lastPathComponent, "Снимок экрана 1.png", "the original name, not the private one")
        XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: try XCTUnwrap(model.attachmentURL(attachments[0]))))

        model.copyAttachmentFiles(attachments)
        XCTAssertEqual(model.copyFeedback, .copied(.files, characters: 2))
        let urls = try XCTUnwrap(board.readObjects(forClasses: [NSURL.self]) as? [URL])
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Снимок экрана 1.png", "two.png"], "files, like ⌘C in Finder")
        XCTAssertTrue(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        await model.copyResponseWithImages()
        let items = try XCTUnwrap(board.pasteboardItems)
        XCTAssertEqual(items.count, 3, "the text, then one item per image")
        XCTAssertEqual(items[0].string(forType: .string), "Report", "the text item is the complete text, alone")
        XCTAssertNil(items[0].data(forType: NSPasteboard.PasteboardType(UTType.png.identifier)))
        XCTAssertNotNil(items[1].data(forType: NSPasteboard.PasteboardType(UTType.png.identifier)))
        XCTAssertEqual(items[2].string(forType: .fileURL).flatMap(URL.init(string:))?.lastPathComponent, "two.png")
    }

    func testHandoffNamesAreSafeAndUnique() {
        var used = Set<String>()
        XCTAssertEqual(ReportStore.uniqueName("a.png", used: &used), "a.png")
        XCTAssertEqual(ReportStore.uniqueName("A.png", used: &used), "A 2.png")
        XCTAssertEqual(ReportStore.safeFilename("../x/y.png", fallback: "f.png"), "f.png", "no path, no hidden file")
        XCTAssertEqual(ReportStore.safeFilename("a/b:c.png", fallback: "f.png"), "a-b-c.png")
        XCTAssertEqual(ReportStore.safeFilename(".hidden", fallback: "f.png"), "f.png")
        XCTAssertEqual(ReportStore.safeFilename("  ", fallback: "f.png"), "f.png")
    }

    // MARK: Review Pack

    func testALocalPackListsImagesBeforeNotCheckedWithoutTouchingTheResponse() throws {
        // The response itself contains the anchor heading: only the Core's own counts.
        let response = "Done.\n\n## Not checked\nAll green (Claude says).\n"
        let core = "# Copy for ChatGPT: x\n\n## Claude final response\n[Reported by Claude] x\n\n```markdown\n\(response)\n```\n\n"
            + "## Git state\n- x\n\n## Not checked\n- [Not verified] y\n\n## Request for review\nPlease review.\n"
        let a = ReportAttachment(id: "a", reportKey: "k", originalFilename: "screen.png", storedFilename: "a.png", mimeType: "image/png",
                                 byteCount: 2048, sha256: "s", addedAt: "t", provenance: "p")
        let pack = ReviewPack.render(local: core, attachments: [a])
        XCTAssertEqual(ReviewPackReader.response(in: pack).map { Data($0.utf8) }, Data(response.utf8), "the response is untouched")
        let section = try XCTUnwrap(pack.range(of: "## Attachments (1 file, sent separately)"))
        let tests = try XCTUnwrap(pack.range(of: "\n## Not checked\n- [Not verified]"))
        XCTAssertLessThan(section.lowerBound, tests.lowerBound, "listed before Not checked, after the response")
        XCTAssertGreaterThan(section.lowerBound, try XCTUnwrap(pack.range(of: "## Git state")).lowerBound)
        XCTAssertTrue(pack.contains("part of this review only if they are attached to this message"), "no claim that they were sent")
        XCTAssertFalse(pack.contains("a.png"), "no private file name or path")
        XCTAssertEqual(ReviewPack.render(local: core, attachments: []), core)
    }
}
