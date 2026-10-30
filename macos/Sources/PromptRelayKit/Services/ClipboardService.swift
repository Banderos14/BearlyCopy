import AppKit
import UniformTypeIdentifiers

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

    /// Text plus images as separate pasteboard items: item 1 is the text,
    /// then one item per image (its own type and a file URL to the private
    /// copy). Whether a destination app accepts several items in one paste
    /// is up to that app; only the text is read back and confirmed.
    @discardableResult
    public func copy(_ text: String, images: [URL]) throws -> Int {
        pasteboard.clearContents()
        let textItem = NSPasteboardItem()
        textItem.setString(text, forType: .string)
        var items = [textItem]
        for url in images {
            guard let data = try? Data(contentsOf: url) else { continue }
            let item = NSPasteboardItem()
            let type = NSPasteboard.PasteboardType(UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.png")
            item.setData(data, forType: type)
            if let image = NSImage(data: data), let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
            item.setString(url.absoluteString, forType: .fileURL)
            items.append(item)
        }
        guard pasteboard.writeObjects(items) else { throw ClipboardError.writeFailed }
        guard let back = pasteboard.string(forType: .string),
              Array(back.unicodeScalars) == Array(text.unicodeScalars) else {
            throw ClipboardError.verificationFailed
        }
        return pasteboard.changeCount
    }

    /// One image alone, as image data (its own type, e.g. PNG, plus TIFF)
    /// and as its file, in one pasteboard item: apps that take a pasted
    /// image read the data, apps that take files read the file URL.
    public func copyImage(at url: URL) throws {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { throw ClipboardError.writeFailed }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        item.setString(url.absoluteString, forType: .fileURL)
        guard pasteboard.writeObjects([item]) else { throw ClipboardError.writeFailed }
    }

    /// Files, like ⌘C in Finder: one file URL per item.
    public func copyFiles(_ urls: [URL]) throws {
        pasteboard.clearContents()
        guard !urls.isEmpty, pasteboard.writeObjects(urls.map { $0 as NSURL }) else { throw ClipboardError.writeFailed }
    }

    var itemCount: Int { pasteboard.pasteboardItems?.count ?? 0 }
}
