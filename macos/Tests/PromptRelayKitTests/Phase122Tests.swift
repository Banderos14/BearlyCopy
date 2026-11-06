import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// Phase 12.2: drag from the island on the first interaction, with the
/// panel not key (the island opened on hover while another app is in front).
/// Events go through the real `NotchPanel.sendEvent`, as AppKit delivers
/// them; drag sessions are recorded, not started.
@MainActor
final class Phase122Tests: XCTestCase {
    final class Clicks { var count = 0 }

    private func panel(clicks: Clicks, payload: Bool = true) throws -> (NotchPanel, FileDragSource.DragView, NSView) {
        _ = NSApplication.shared
        let panel = NotchPanel()
        let root = HStack(spacing: 20) {
            Button("Plain") { clicks.count += 1 }.frame(width: 80, height: 30)
            FileDragButton(title: "Drag", help: "", payloads: {
                payload ? [.file(URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist"))] : []
            })
        }
        .frame(width: 300, height: 60)
        panel.install(root: root)
        panel.setFrame(NSRect(x: 200, y: 200, width: 300, height: 60), display: false)
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        let drag = try XCTUnwrap(Self.find(FileDragSource.DragView.self, in: panel.contentView))
        return (panel, drag, try XCTUnwrap(panel.contentView))
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let hit = view as? T { return hit }
        for sub in view.subviews { if let hit = find(type, in: sub) { return hit } }
        return nil
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in panel: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func center(of view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    func testFirstDragStartsWhileThePanelIsNotKey() throws {
        let clicks = Clicks()
        let (panel, drag, _) = try panel(clicks: clicks)
        defer { panel.orderOut(nil) }
        panel.resignKey()
        XCTAssertFalse(panel.isKeyWindow, "the island opened on hover is not key")
        var sessions = 0
        drag.beginSession = { _, _ in sessions += 1 }
        let start = center(of: drag)
        XCTAssertTrue(panel.contentView?.hitTest(start) === drag, "the Drag control receives the press")
        panel.sendEvent(event(.leftMouseDown, at: start, in: panel))
        panel.sendEvent(event(.leftMouseDragged, at: NSPoint(x: start.x + 12, y: start.y + 3), in: panel))
        XCTAssertEqual(sessions, 1, "the very first press-and-move starts the drag (no activation click)")
        panel.sendEvent(event(.leftMouseUp, at: NSPoint(x: start.x + 12, y: start.y + 3), in: panel))
    }

    func testAPlainClickIsNeverADragAndSmallJitterIsIgnored() throws {
        let (panel, drag, _) = try panel(clicks: Clicks())
        defer { panel.orderOut(nil) }
        panel.resignKey()
        var sessions = 0
        drag.beginSession = { _, _ in sessions += 1 }
        let start = center(of: drag)
        panel.sendEvent(event(.leftMouseDown, at: start, in: panel))
        panel.sendEvent(event(.leftMouseUp, at: start, in: panel))
        XCTAssertEqual(sessions, 0, "a click without movement does not drag")
        panel.sendEvent(event(.leftMouseDown, at: start, in: panel))
        panel.sendEvent(event(.leftMouseDragged, at: NSPoint(x: start.x + 1, y: start.y + 1), in: panel))
        XCTAssertEqual(sessions, 0, "1–2 pt of hand jitter is not a drag")
        panel.sendEvent(event(.leftMouseDragged, at: NSPoint(x: start.x + 5, y: start.y), in: panel))
        panel.sendEvent(event(.leftMouseDragged, at: NSPoint(x: start.x + 40, y: start.y), in: panel))
        XCTAssertEqual(sessions, 1, "one session per press, however long the move")
        panel.sendEvent(event(.leftMouseUp, at: NSPoint(x: start.x + 40, y: start.y), in: panel))
    }

    func testRepeatedDragsAfterDropOrEscapeEachStartOnce() throws {
        let (panel, drag, _) = try panel(clicks: Clicks())
        defer { panel.orderOut(nil) }
        var sessions = 0
        drag.beginSession = { _, _ in sessions += 1 }
        let start = center(of: drag)
        for round in 1...3 {
            panel.resignKey()        // the island closed and opened on hover again
            panel.sendEvent(event(.leftMouseDown, at: start, in: panel))
            panel.sendEvent(event(.leftMouseDragged, at: NSPoint(x: start.x + 10, y: start.y), in: panel))
            XCTAssertEqual(sessions, round)
            // AppKit ends the session (a drop, or Esc in round 2) and the press is released.
            drag.sessionEnded()
            panel.sendEvent(event(.leftMouseUp, at: NSPoint(x: start.x + 10, y: start.y), in: panel))
        }
    }

    func testOnlyTheDragSourceOptsIntoFirstMouse() throws {
        let (panel, drag, content) = try panel(clicks: Clicks())
        defer { panel.orderOut(nil) }
        let down = event(.leftMouseDown, at: center(of: drag), in: panel)
        XCTAssertTrue(drag.acceptsFirstMouse(for: down))
        XCTAssertTrue(drag.shouldDelayWindowOrdering(for: down))
        func hosting(_ v: NSView) -> NSView? {
            if String(describing: type(of: v)).hasPrefix("NSHostingView") { return v }
            return v.subviews.lazy.compactMap(hosting).first
        }
        let host = try XCTUnwrap(hosting(content))
        XCTAssertFalse(host.acceptsFirstMouse(for: down), "the island's general click handling is unchanged")
    }

    func testAButtonStillFiresOnTheFirstClickAndTheDragViewDoesNotStealIt() throws {
        let clicks = Clicks()
        let (panel, _, content) = try panel(clicks: clicks)
        defer { panel.orderOut(nil) }
        panel.resignKey()
        let point = content.convert(NSPoint(x: 40 + (300 - 80 - 20 - 70) / 2, y: 30), to: nil)
        panel.sendEvent(event(.leftMouseDown, at: point, in: panel))
        panel.sendEvent(event(.leftMouseUp, at: point, in: panel))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(clicks.count, 1)
    }

    func testAnEmptySelectionStartsNothing() throws {
        let (panel, drag, _) = try panel(clicks: Clicks(), payload: false)
        defer { panel.orderOut(nil) }
        panel.resignKey()
        var sessions = 0
        drag.beginSession = { _, _ in sessions += 1 }
        let start = center(of: drag)
        panel.sendEvent(event(.leftMouseDown, at: start, in: panel))
        panel.sendEvent(event(.leftMouseDragged, at: NSPoint(x: start.x + 10, y: start.y), in: panel))
        XCTAssertEqual(sessions, 0)
    }

    /// Files are offered as file URLs (hand-off copies); an in-memory window
    /// snapshot as image data only — no file URL, and no PNG on disk.
    func testDragOffersFilesAndInMemoryImagesWithoutWritingThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr122-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard(name: .init("PromptRelay122-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let store = ReportStore(root: root.appendingPathComponent("store"))
        let model = AppModel(core: FakeCore(projects: []), clipboard: ClipboardService(pasteboard: board), dataDirectory: nil,
                             reportStore: store)
        _ = model.importReport(text: "Answer", task: "Task", projectPath: "/p", sessionLabel: nil)
        let ref = try XCTUnwrap(model.currentRef)
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let text = src.appendingPathComponent("notes.md"); try Data("# Notes\n".utf8).write(to: text)
        let png = src.appendingPathComponent("shot.png"); try TypedAttachmentTests.png().write(to: png)
        try store.addFile(from: text, to: ref, source: .you, displayPath: "notes.md")
        try store.addFile(from: png, to: ref, source: .you, displayPath: "shot.png")
        _ = try store.addEphemeralImage(TypedAttachmentTests.png(.systemOrange), name: "Final window.png", to: ref, source: .windowSnapshot)
        model.attachmentsVersion += 1
        let attachments = model.attachments(for: ref)
        XCTAssertEqual(attachments.count, 3)
        func pngCount() -> Int {
            (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { $0.pathExtension == "png" && $0.lastPathComponent != "shot.png" }.count
        }
        let pngsBefore = pngCount()

        let panel = NotchPanel()
        defer { panel.orderOut(nil) }
        panel.install(root: FileDragButton(title: "Drag 3", help: "", payloads: { model.dragPayloads(for: attachments) })
            .frame(width: 120, height: 40))
        panel.setFrame(NSRect(x: 200, y: 200, width: 120, height: 40), display: false)
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.resignKey()
        let drag = try XCTUnwrap(Self.find(FileDragSource.DragView.self, in: panel.contentView))
        var offered: [NSDraggingItem] = []
        drag.beginSession = { items, _ in offered = items }
        let start = center(of: drag)
        panel.sendEvent(event(.leftMouseDown, at: start, in: panel))
        panel.sendEvent(event(.leftMouseDragged, at: NSPoint(x: start.x + 10, y: start.y), in: panel))
        panel.sendEvent(event(.leftMouseUp, at: NSPoint(x: start.x + 10, y: start.y), in: panel))

        XCTAssertEqual(offered.count, 3, "all chosen materials in one drag, first try")
        let urls = offered.compactMap { $0.item as? NSURL as URL? }
        XCTAssertEqual(Set(urls.map(\.lastPathComponent)), ["notes.md", "shot.png"], "files go as file URLs")
        let images = offered.compactMap { $0.item as? NSPasteboardItem }
        XCTAssertEqual(images.count, 1, "the snapshot goes as data")
        let image = try XCTUnwrap(images.first)
        XCTAssertNil(image.string(forType: .fileURL), "no file behind the in-memory snapshot")
        XCTAssertNotNil(image.data(forType: .png))
        XCTAssertEqual(pngCount(), pngsBefore, "dragging wrote no PNG")
    }
}
