import AppKit
import Foundation
import ImageIO
import Testing
@testable import PromptRelayKit

/// Phase 16: the daily-driver release — the Relay bear app icon in every
/// build path, attachments that are never silently "not attached", and one
/// writer at a time for the attachment index across running copies (S8).
@Suite(.serialized)
@MainActor
struct Phase16IconTests {
    /// RGBA (0…255) of one pixel, y down.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return px.map(Int.init)
    }

    @Test func iconIsRelayOnATileWithTransparentCorners() throws {
        let image = try #require(AppIcon.render(pixels: 1024))
        #expect(image.width == 1024 && image.height == 1024)
        #expect(image.colorSpace?.name == CGColorSpace.sRGB)
        // Outside the rounded tile: transparent (macOS draws the icon's own shadow area).
        #expect(pixel(image, 4, 4)[3] == 0)
        #expect(pixel(image, 1019, 1019)[3] == 0)
        // The bear's head (fur) at the centre-left cheek and its muzzle below the nose: Relay's own colours.
        let fur = pixel(image, 300, 560)
        #expect(abs(fur[0] - 204) < 12 && abs(fur[1] - 158) < 12 && abs(fur[2] - 115) < 12, "fur \(fur)")
        let muzzle = pixel(image, 420, 640)
        #expect(muzzle[0] > 220 && muzzle[1] > 195, "muzzle \(muzzle)")
        // The tile between ear and edge: dark and opaque.
        let tile = pixel(image, 512, 150)
        #expect(tile[3] == 255 && tile[0] < 90, "tile \(tile)")
    }

    @Test func everyIconsetSizeRenders() throws {
        #expect(AppIcon.iconsetEntries.count == 10)
        for entry in AppIcon.iconsetEntries {
            let image = try #require(AppIcon.render(pixels: entry.pixels))
            #expect(image.width == entry.pixels)
            // Something opaque in the middle at every size (legible at 16 px).
            #expect(pixel(image, entry.pixels / 2, entry.pixels / 2)[3] == 255, "\(entry.name)")
        }
    }

    /// The committed icon is what `AppIcon` draws now: nobody changed the bear
    /// without regenerating it (scripts/make-app-icon.sh), and it was not
    /// made by enlarging a screenshot.
    @Test func committedIcnsMatchesTheDrawing() throws {
        let url = Repo.root.appendingPathComponent("macos/Resources/AppIcon.icns")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        var sizes = Set<Int>()
        for i in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            sizes.insert(image.width)
            let fresh = try #require(AppIcon.render(pixels: image.width))
            var worst = 0
            for (x, y) in [(0.5, 0.5), (0.3, 0.55), (0.69, 0.31), (0.12, 0.5), (0.5, 0.15), (0.41, 0.47)] {
                let a = pixel(image, Int(x * Double(image.width)), Int(y * Double(image.height)))
                let b = pixel(fresh, Int(x * Double(image.width)), Int(y * Double(image.height)))
                worst = max(worst, zip(a, b).map { abs($0 - $1) }.max() ?? 0)
            }
            #expect(worst <= 3, "AppIcon.icns \(image.width) px differs from AppIcon.render by \(worst) — run scripts/make-app-icon.sh")
        }
        #expect(sizes.isSuperset(of: [16, 32, 64, 128, 256, 512, 1024]), "sizes \(sizes.sorted())")
    }

    /// Both build paths bundle the same icon and name it in Info.plist.
    @Test func bothBuildPathsBundleTheIcon() throws {
        let plist = try String(contentsOf: Repo.root.appendingPathComponent("macos/Xcode/Info.plist"), encoding: .utf8)
        #expect(plist.contains("<key>CFBundleIconFile</key>\n\t<string>AppIcon</string>"))
        let project = try String(contentsOf: Repo.root.appendingPathComponent("macos/Xcode/PromptRelay.xcodeproj/project.pbxproj"), encoding: .utf8)
        #expect(project.contains("path = ../Resources/AppIcon.icns"))
        #expect(project.contains("AppIcon.icns in Resources */,"))
        #expect(project.contains("/* Resources */,"), "the target has a Resources build phase")
        for script in ["scripts/build-macos-app.sh", "scripts/release-build.sh"] {
            let text = try String(contentsOf: Repo.root.appendingPathComponent(script), encoding: .utf8)
            #expect(text.contains("cp macos/Resources/AppIcon.icns \"$app/Contents/Resources/AppIcon.icns\""), "\(script)")
            #expect(text.contains("<key>CFBundleIconFile</key><string>AppIcon</string>"), "\(script)")
        }
    }

    @Test func menuBarMarkIsATemplateSilhouette() throws {
        let image = AppIcon.menuBarImage()
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        var opaque = 0, clear = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh {
            let a = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
            if a > 0.5 { opaque += 1 } else { clear += 1 }
        } }
        #expect(opaque > rep.pixelsWide * rep.pixelsHigh / 4, "a solid head and ears")
        // The eyes are cut out: the centre of the left eye is clear.
        let eye = rep.colorAt(x: Int(0.335 * 1.06 * Double(rep.pixelsWide)) - Int(0.03 * Double(rep.pixelsWide)),
                              y: Int(0.47 * Double(rep.pixelsHigh)))?.alphaComponent ?? 1
        #expect(eye < 0.5)
        #expect(clear > 0)
    }
}

@Suite(.serialized)
@MainActor
struct Phase16AttachmentTests {
    private func show(root: URL, cwd: URL, files: [URL], answer: String) throws -> ShowData {
        let observed: [String: Any] = ["commands": [], "files_changed": files.map { ["path": $0.path, "tools": ["Write"], "count": 1] as [String: Any] },
                                       "shown_files": [], "artifacts": [], "notifications": 0]
        let session: [String: Any] = ["session_id": "s16", "session_key": "s16", "project": ["path": cwd.path, "name": "p"],
                                      "logical_project": ["path": root.path, "name": "p", "basis": "git_root"],
                                      "first_event_at": "2026-11-08T10:00:00Z", "last_event_at": "2026-11-08T10:01:00Z", "event_count": 2,
                                      "turn_count": 1, "cwds": [cwd.path], "last_turn": ["index": 1, "status": "stop_received"],
                                      "integrity": ["corrupt_lines": 0, "unsupported_lines": 0, "foreign_lines": 0]]
        func text(_ v: String) -> [String: Any] { ["text": v, "preview": v, "truncated": false, "char_count": v.count, "utf8_bytes": v.utf8.count,
                                                   "prompt_id": "p1", "received_at": "2026-11-08T10:01:00Z"] }
        let turn: [String: Any] = ["index": 1, "status": "stop_received", "link": "prompt_id", "request": text("Do it"),
                                   "final_response": text(answer), "response_event_count": 1, "candidate_request_turns": [],
                                   "observed_detail": observed]
        return try JSONDecoder().decode(ShowData.self, from: JSONSerialization.data(withJSONObject: ["session": session, "turn": turn]))
    }

    private func model(_ data: ShowData, root: URL, store: ReportStore) async -> AppModel {
        let core = FakeCore(projects: [project(root.path, sessions: 1, last: data.session.lastEventAt)])
        core.sessionsByProject[root.path] = [data.session]
        core.turnsBySession[data.session.sessionKey] = [data.turn]
        core.showResult = { _, _ in .success(CoreResult(data: data, warnings: [])) }
        let board = NSPasteboard(name: .init(UUID().uuidString))
        let model = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, reportStore: store)
        await model.refreshNow()
        return model
    }

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr16-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The owner's report: a file under "From this turn" whose bytes were
    /// already attached (under another name) stayed listed, and Add did
    /// nothing visible. Now Add says so and the file is selected.
    @Test func addingAFileAlreadyAttachedSaysSoAndSelectsIt() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = root.appendingPathComponent("docs/REPORT.md")
        try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# Отчёт ✅".utf8).write(to: report)
        let data = try show(root: root, cwd: root, files: [report], answer: "See docs/REPORT.md")
        let store = ReportStore(root: root.appendingPathComponent("store"))
        let m = await model(data, root: root, store: store)
        let ref = try #require(m.currentRef)
        // Auto-prepared on arrival; the user removed it, then attached the same
        // file through Files… (stored under its file name) and deselected it.
        for a in store.attachments(for: ref) { try store.removeAttachment(a.id) }
        let earlier = try store.addFile(from: report, to: ref, source: .you, displayPath: "REPORT.md")
        try store.setSelected(earlier.id, false)
        m.attachmentsVersion += 1
        let suggestion = try #require(m.suggestions.first { $0.title == "REPORT.md" })
        let outcome = m.accept(suggestion)
        #expect(outcome == .alreadyAttached("REPORT.md"))
        #expect(m.attachmentNotice?.contains("already attached") == true)
        #expect(m.attachmentMessage == nil)
        #expect(store.attachments(for: ref).count == 1, "no duplicate record")
        #expect(store.attachments(for: ref).first?.isSelected == true, "Add means: include it")
    }

    @Test func addConfirmsStorageAndSaysWhereItGoes() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("notes.txt")
        try Data("Заметки 🐻".utf8).write(to: notes)
        let data = try show(root: root, cwd: root, files: [notes], answer: "Wrote notes.txt")
        let store = ReportStore(root: root.appendingPathComponent("store"))
        let m = await model(data, root: root, store: store)
        let ref = try #require(m.currentRef)
        // Auto-prepare does not take .txt? It does; remove it so Add has work to do.
        for a in store.attachments(for: ref) { try store.removeAttachment(a.id) }
        m.attachmentsVersion += 1
        let suggestion = try #require(m.suggestions.first { $0.title == "notes.txt" })
        #expect(suggestion.attachable)
        #expect(m.accept(suggestion) == .added("notes.txt"))
        #expect(m.attachmentNotice == "Attached notes.txt — selected for Copy with Context and drag.")
        #expect(m.attachmentNoticeKey == ref.key)
        let stored = try #require(store.attachments(for: ref).first)
        #expect(stored.isSelected && stored.originalPath == "notes.txt")
        let copy = try #require(store.fileURL(for: stored))
        #expect(try Data(contentsOf: copy) == Data("Заметки 🐻".utf8), "a verbatim copy")
        #expect(!m.suggestions.contains { $0.title == "notes.txt" }, "listed once it is attached")
    }

    @Test func unsupportedAndMissingFilesAreMarkedNotAttachableAndAddAllReports() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pbx = root.appendingPathComponent("App.pbxproj"), gone = root.appendingPathComponent("gone.md")
        let ok = root.appendingPathComponent("ok.swift")
        try Data("// pbx".utf8).write(to: pbx)
        try Data("let a = 1".utf8).write(to: ok)
        let data = try show(root: root, cwd: root, files: [pbx, gone, ok], answer: "Changed App.pbxproj, gone.md and ok.swift")
        let store = ReportStore(root: root.appendingPathComponent("store"))
        let m = await model(data, root: root, store: store)
        let list = m.suggestions
        let p = try #require(list.first { $0.title == "App.pbxproj" })
        #expect(!p.attachable && p.notAttachableReason?.contains("Not attachable") == true)
        let g = try #require(list.first { $0.title == "gone.md" })
        #expect(!g.attachable && g.notAttachableReason?.contains("no longer exists") == true)
        let outcomes = m.acceptAll(list)
        #expect(outcomes.filter { !$0.isFailure }.count == 1)
        let message = try #require(m.attachmentMessage)
        #expect(message.hasPrefix("Attached 1 of 3."))
        #expect(message.contains("App.pbxproj was not attached") && message.contains("gone.md was not attached"))
        #expect(m.attachmentNotice == nil)
    }

    @Test func oversizedTextDocumentSaysTooLargeNotUnsupported() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = root.appendingPathComponent("big.md")
        try Data(repeating: UInt8(ascii: "a"), count: ReportStore.maxDocumentBytes + 1).write(to: big)
        let store = ReportStore(root: root.appendingPathComponent("store"))
        #expect(throws: ReportStoreError.documentTooLarge("big.md")) {
            try store.addFile(from: big, to: .local(sessionKey: "k", turn: 1))
        }
        #expect(AppModel.reason(for: .documentTooLarge("big.md")).contains("1 MB"))
    }

    /// Names in the answer resolve in the folder the agent ran in first
    /// (`<repo>/macos`), not only at the project root.
    @Test func namedFilesResolveInTheAgentsOwnFolderFirst() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("macos")
        let inCwd = cwd.appendingPathComponent("Docs/GUIDE.md")
        try FileManager.default.createDirectory(at: inCwd.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("guide".utf8).write(to: inCwd)
        let data = try show(root: root, cwd: cwd, files: [], answer: "Read Docs/GUIDE.md")
        let store = ReportStore(root: root.appendingPathComponent("store"))
        let m = await model(data, root: root, store: store)
        for a in store.attachments(for: try #require(m.currentRef)) { try store.removeAttachment(a.id) }
        m.attachmentsVersion += 1
        let found = try #require(m.suggestions.first { $0.title == "GUIDE.md" })
        #expect(found.path == inCwd.path)
        #expect(AppModel.displayRoot(cwd: cwd.path, logical: root.path) == root.path)
        #expect(AppModel.displayRoot(cwd: "/elsewhere/wt", logical: root.path) == "/elsewhere/wt", "a separate worktree is its own root")
    }
}

/// S8: two running copies (Debug + Release) both write the attachment index.
@Suite(.serialized)
@MainActor
struct Phase16StoreLockTests {
    /// A second process holds the store lock and writes its own record; our
    /// add, started meanwhile, waits and keeps both. Without the lock the
    /// other process's write (from its earlier read) drops ours.
    @Test func anotherProcessesIndexWriteIsNeverLost() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr16-lock-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReportStore(root: root.appendingPathComponent("app"))
        let ref = ReportRef.local(sessionKey: "k", turn: 1)
        try store.addData(TypedAttachmentTests.png(.red), name: "seed.png", to: ref, source: .you)
        let script = """
        import fcntl, json, sys, time
        root = sys.argv[1]
        lock = open(root + "/.store.lock", "a")
        fcntl.flock(lock, fcntl.LOCK_EX)
        index = json.load(open(root + "/attachments.json"))
        print("locked", flush=True)
        time.sleep(0.8)
        other = dict(index[0]); other["id"] = "other-process"
        index.append(other)
        json.dump(index, open(root + "/attachments.json", "w"))
        fcntl.flock(lock, fcntl.LOCK_UN)
        """
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-I", "-c", script, store.root.path]
        let out = Pipe()
        child.standardOutput = out
        try child.run()
        let line = out.fileHandleForReading.availableData
        #expect(String(decoding: line, as: UTF8.self).hasPrefix("locked"))
        let started = Date()
        try store.addData(TypedAttachmentTests.png(.blue), name: "mine.png", to: ref, source: .you)
        let waited = Date().timeIntervalSince(started)
        child.waitUntilExit()
        let ids = store.attachments(for: ref).map(\.id)
        #expect(ids.contains("other-process"), "the other copy's record survived: \(ids)")
        #expect(store.attachments(for: ref).contains { $0.originalFilename == "mine.png" }, "ours too")
        #expect(waited > 0.5, "our write waited for the other process (\(waited) s)")
    }

    @Test func lockIsReentrantAndReleased() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr16-lock-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReportStore(root: root)
        let held = try store.withStoreLock { try store.withStoreLock { () -> Bool in
            let fd = open(root.appendingPathComponent(".store.lock").path, O_RDWR)
            defer { close(fd) }
            return flock(fd, LOCK_EX | LOCK_NB) != 0
        } }
        #expect(held, "held while a mutation runs")
        let fd = open(root.appendingPathComponent(".store.lock").path, O_RDWR)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0, "released afterwards")
        flock(fd, LOCK_UN)
    }
}
