import AppKit

public enum ClipboardError: Error, Equatable, Sendable {
    /// The pasteboard refused the string.
    case writeFailed
    /// Reading back gave different text; nothing is reported as copied.
    case verificationFailed
}

/// Writes text to an NSPasteboard verbatim (`.string`, i.e.
/// `public.utf8-plain-text`) and reads it back to confirm. The text is never
/// trimmed, normalized or logged.
@MainActor
public final class ClipboardService {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Returns the pasteboard change count of the write.
    @discardableResult
    public func copy(_ text: String) throws -> Int {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw ClipboardError.writeFailed }
        let changeCount = pasteboard.changeCount
        // Compare scalars, not `String ==`, which treats canonically
        // equivalent strings (é vs e + U+0301) as equal.
        guard let back = pasteboard.string(forType: .string),
              Array(back.unicodeScalars) == Array(text.unicodeScalars) else {
            throw ClipboardError.verificationFailed
        }
        return changeCount
    }
}
