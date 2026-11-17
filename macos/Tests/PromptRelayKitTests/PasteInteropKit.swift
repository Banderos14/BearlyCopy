import AppKit
import XCTest
@testable import PromptRelayKit

/// Manual interoperability check, not an automated test: puts a known text
/// and a generated test image on the GENERAL pasteboard with the app's own
/// `ClipboardService`, so the owner can paste into ChatGPT and report what
/// arrived. Runs only with PROMPT_RELAY_PASTE_TEST=text-image | image | text.
/// It touches no history and no attachment store.
@MainActor
final class PasteInteropKit: XCTestCase {
    func testPutTestContentOnTheGeneralPasteboard() throws {
        guard let mode = ProcessInfo.processInfo.environment["PROMPT_RELAY_PASTE_TEST"] else {
            throw XCTSkip("set PROMPT_RELAY_PASTE_TEST=text-image, image or text to prepare a manual paste test")
        }
        _ = NSApplication.shared
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "BearlyCopy paste test \(stamp)\n\nLine 2: Кириллица ✅ — `code` 🚀\n"
        let image = NSImage(size: NSSize(width: 480, height: 160), flipped: false) { rect in
            NSColor(red: 0.45, green: 0.85, blue: 0.72, alpha: 1).setFill(); rect.fill()
            ("PROMPT RELAY TEST IMAGE\n" + stamp as NSString).draw(
                in: rect.insetBy(dx: 20, dy: 40),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.black])
            return true
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-relay-paste-test", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("prompt-relay-test.png")
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: url)

        let clipboard = ClipboardService(pasteboard: .general)
        switch mode {
        case "text-image": try clipboard.copy(text, images: [url])
        case "image": try clipboard.copyImage(at: url)
        default: try clipboard.copy(text)
        }
        let types = NSPasteboard.general.pasteboardItems?.map { $0.types.map(\.rawValue).joined(separator: ", ") } ?? []
        print("PASTE-TEST mode=\(mode) items=\(types.count)")
        for (i, t) in types.enumerated() { print("PASTE-TEST item \(i + 1): \(t)") }
        print("PASTE-TEST text first line: BearlyCopy paste test \(stamp)")
    }
}
