import AppKit
import UniformTypeIdentifiers

public enum ClipboardError: Error, Equatable, Sendable {
    /// The pasteboard refused the string.
    case writeFailed
    /// Reading back gave different text; nothing is reported as copied.
    case verificationFailed
}

/// Phase 10: one image to put on the pasteboard. `file` is nil for an
/// in-memory window snapshot: only its image data is written (PNG + TIFF),
/// never a file URL, so no file has to exist for it.
public struct ClipboardImage: Equatable, Sendable {
    public let data: Data
    public let uti: String
    public let file: URL?
    public init(data: Data, uti: String = "public.png", file: URL? = nil) {
        self.data = data; self.uti = uti; self.file = file
    }
    public init?(file url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data, uti: UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.png", file: url)
    }

    func item() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(uti))
        if uti != NSPasteboard.PasteboardType.tiff.rawValue, let image = NSImage(data: data), let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        if let file { item.setString(file.absoluteString, forType: .fileURL) }
        return item
    }
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

    /// Changes whenever anything (any app) writes to the pasteboard.
    public var changeCount: Int { pasteboard.changeCount }

    /// Returns the pasteboard change count of the write.
    @discardableResult
    public func copy(_ text: String) throws -> Int {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw ClipboardError.writeFailed }
        markOwn()
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
        try copy(text, imageItems: images.compactMap(ClipboardImage.init(file:)))
    }

    /// The same with images that may exist only in memory (no file URL).
    @discardableResult
    public func copy(_ text: String, imageItems images: [ClipboardImage]) throws -> Int {
        pasteboard.clearContents()
        let textItem = NSPasteboardItem()
        textItem.setString(text, forType: .string)
        let items = [textItem] + images.map { $0.item() }
        guard pasteboard.writeObjects(items) else { throw ClipboardError.writeFailed }
        markOwn()
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
        item.setData(Data([1]), forType: ClipboardImageHistory.ownType)
        guard pasteboard.writeObjects([item]) else { throw ClipboardError.writeFailed }
    }

    /// Phase 10: one image from memory, as image data only (PNG + TIFF): no
    /// file URL, no file. Read back: the clipboard holds exactly these bytes.
    public func copyImage(_ image: ClipboardImage) throws {
        pasteboard.clearContents()
        let item = image.item()
        item.setData(Data([1]), forType: ClipboardImageHistory.ownType)
        guard pasteboard.writeObjects([item]),
              pasteboard.data(forType: NSPasteboard.PasteboardType(image.uti)) == image.data else { throw ClipboardError.writeFailed }
    }

    /// Phase 10, hand-off step 2 with snapshots: the files as file URLs (like
    /// ⌘C in Finder) plus each in-memory snapshot as image data, one item
    /// each. Read back: exactly these files and this many items.
    public func copyFiles(_ urls: [URL], images: [ClipboardImage]) throws {
        guard !images.isEmpty else { try copyFiles(urls); return }
        pasteboard.clearContents()
        let objects: [NSPasteboardWriting] = urls.map { $0 as NSURL } + images.map { $0.item() }
        guard !objects.isEmpty, pasteboard.writeObjects(objects) else { throw ClipboardError.writeFailed }
        markOwn()
        let back = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard back.map(\.standardizedFileURL) == urls.map(\.standardizedFileURL), itemCount == objects.count else {
            throw ClipboardError.verificationFailed
        }
    }

    /// Files, like ⌘C in Finder: one file URL per item.
    public func copyFiles(_ urls: [URL]) throws {
        pasteboard.clearContents()
        guard !urls.isEmpty, pasteboard.writeObjects(urls.map { $0 as NSURL }) else { throw ClipboardError.writeFailed }
        markOwn()
        // Read back: success only when the clipboard holds exactly these files.
        let back = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard back.map(\.standardizedFileURL) == urls.map(\.standardizedFileURL) else { throw ClipboardError.verificationFailed }
    }

    /// Marks what BearlyCopy wrote, so its own clipboard image history
    /// never takes it back in. Added to the first item.
    private func markOwn() {
        pasteboard.pasteboardItems?.first?.setData(Data([1]), forType: ClipboardImageHistory.ownType)
    }

    var itemCount: Int { pasteboard.pasteboardItems?.count ?? 0 }
}
