import AppKit
import XCTest
@testable import PromptRelayKit

/// Uses a private, uniquely named pasteboard: the user's clipboard is never touched.
@MainActor
final class ClipboardServiceTests: XCTestCase {
    var pasteboard: NSPasteboard!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("PromptRelayTests-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
    }

    func testTextIsCopiedVerbatim() throws {
        let service = ClipboardService(pasteboard: pasteboard)
        let samples = [
            "Привет, мир! 🚀",
            "👩‍💻 👨‍👩‍👧‍👦 🇺🇦 e\u{301} vs é",          // ZWJ, flags, combining vs precomposed
            "line1\r\nline2\r\n\r\n",              // CRLF kept
            "before\u{0}after\u{0}\u{0}",           // NUL kept
            "  leading and trailing spaces  \n\n",
            "```swift\nlet x = 1\n```\n\n````md\n```js\n```\n````",
            "\u{1b}[31mred\u{1b}[0m \u{7} \u{feff}bom",
        ]
        for text in samples {
            try service.copy(text)
            let back = try XCTUnwrap(pasteboard.string(forType: .string))
            XCTAssertEqual(Array(back.unicodeScalars), Array(text.unicodeScalars))
            XCTAssertEqual(pasteboard.data(forType: .string), Data(text.utf8))
        }
    }

    func testLargeTextAndReplacement() throws {
        let service = ClipboardService(pasteboard: pasteboard)
        let big = String(repeating: "## Заголовок\n- пункт `code` 🚀\n", count: 40_000)  // ~1.4 MB
        let first = try service.copy(big)
        XCTAssertEqual(pasteboard.string(forType: .string)?.utf8.count, big.utf8.count)
        let second = try service.copy("short")
        XCTAssertGreaterThan(second, first)
        XCTAssertEqual(pasteboard.string(forType: .string), "short")
        // Only plain text is written (AppKit also lists its legacy alias for it).
        XCTAssertEqual(pasteboard.types?.first, .string)
        XCTAssertFalse(pasteboard.types?.contains(.rtf) ?? true)
    }

    func testEmptyStringIsStillAWrite() throws {
        // The model refuses empty answers before reaching the service; the
        // service itself copies whatever it is given.
        try ClipboardService(pasteboard: pasteboard).copy("")
        XCTAssertEqual(pasteboard.string(forType: .string), "")
    }
}
