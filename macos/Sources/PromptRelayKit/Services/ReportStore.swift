import CryptoKit
import Foundation
import UniformTypeIdentifiers

public enum ReportStoreError: Error, Equatable, Sendable {
    case empty
    case notAnImage(String)
    case tooLarge(String)
    case unreadable(String)
    case writeFailed
}

/// Prompt Relay's own data, next to the Core's but separate from it:
/// `<data dir>/app/imports/<id>.json` for imported reports and
/// `<data dir>/app/attachments/` for images the user added. The Core never
/// reads these; the app never writes the Core's `events/`.
///
/// Folders are 0700 and files 0600; writes are atomic. Nothing is ever
/// deleted unless the user removes that import or attachment.
@MainActor
public final class ReportStore {
    public let root: URL
    private let fm = FileManager.default
    public static let maxAttachmentBytes = 50 * 1024 * 1024

    public init(root: URL) {
        self.root = root
    }

    /// The live location under the Core's data directory.
    public static func live(dataDirectory: URL) -> ReportStore {
        ReportStore(root: dataDirectory.appendingPathComponent("app", isDirectory: true))
    }

    private var importsDir: URL { root.appendingPathComponent("imports", isDirectory: true) }
    private var attachmentsDir: URL { root.appendingPathComponent("attachments", isDirectory: true) }
    private var attachmentIndex: URL { root.appendingPathComponent("attachments.json") }

    private func ensure(_ dir: URL) throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    private func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw ReportStoreError.writeFailed
        }
    }

    static func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Imports

    /// Every imported report, newest first. Unreadable files are skipped.
    public func imports() -> [ImportedReport] {
        guard let files = try? fm.contentsOfDirectory(at: importsDir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(ImportedReport.self, from: Data(contentsOf: $0)) }
            .sorted { $0.importedAt > $1.importedAt }
    }

    /// Stores a pasted report verbatim. The same text and task imported again
    /// returns the existing record (`isDuplicate`), so repeating an import
    /// never creates a second copy.
    public func importReport(text: String, task: String?, projectPath: String?, projectName: String?,
                             sessionLabel: String?) throws -> (report: ImportedReport, isDuplicate: Bool) {
        guard !text.isEmpty else { throw ReportStoreError.empty }
        let task = task.flatMap { $0.isEmpty ? nil : $0 }
        let digest = Self.sha256(Data((text + "\u{0}" + (task ?? "")).utf8))
        if let existing = imports().first(where: { $0.digest == digest }) { return (existing, true) }
        try ensure(importsDir)
        let report = ImportedReport(id: UUID().uuidString.lowercased(), importedAt: Self.now(), text: text, task: task,
                                    projectPath: projectPath, projectName: projectName,
                                    sessionLabel: sessionLabel.flatMap { $0.isEmpty ? nil : $0 }, digest: digest)
        try write(try JSONEncoder().encode(report), to: importsDir.appendingPathComponent("\(report.id).json"))
        return (report, false)
    }

    /// Removes an import and its attachments. History captured by the Core is untouched.
    public func deleteImport(_ id: String) {
        try? fm.removeItem(at: importsDir.appendingPathComponent("\(id).json"))
        for attachment in attachments(for: .imported(id: id)) { removeAttachment(attachment.id) }
    }

    // MARK: Attachments

    public func allAttachments() -> [ReportAttachment] {
        guard let data = try? Data(contentsOf: attachmentIndex) else { return [] }
        return (try? JSONDecoder().decode([ReportAttachment].self, from: data)) ?? []
    }

    private func saveIndex(_ list: [ReportAttachment]) throws {
        try ensure(attachmentsDir)
        try write(try JSONEncoder().encode(list), to: attachmentIndex)
    }

    public func attachments(for ref: ReportRef) -> [ReportAttachment] {
        allAttachments().filter { $0.reportKey == ref.key }.sorted { $0.addedAt < $1.addedAt }
    }

    /// The private copy of an attachment, or nil when it is missing.
    public func fileURL(for attachment: ReportAttachment) -> URL? {
        let url = attachmentsDir.appendingPathComponent(attachment.storedFilename)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    /// Copies an image the user chose into the private folder. Only images,
    /// at most 50 MB; the same file added twice to a report is kept once.
    @discardableResult
    public func addAttachment(from source: URL, to ref: ReportRef) throws -> ReportAttachment {
        let name = source.lastPathComponent
        guard let type = UTType(filenameExtension: source.pathExtension), type.conforms(to: .image) else {
            throw ReportStoreError.notAnImage(name)
        }
        let size = (try? fm.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0
        guard size <= Self.maxAttachmentBytes else { throw ReportStoreError.tooLarge(name) }
        guard let data = try? Data(contentsOf: source) else { throw ReportStoreError.unreadable(name) }
        let digest = Self.sha256(data)
        var index = allAttachments()
        if let existing = index.first(where: { $0.reportKey == ref.key && $0.sha256 == digest }) { return existing }
        try ensure(attachmentsDir)
        let id = UUID().uuidString.lowercased()
        let ext = type.preferredFilenameExtension ?? source.pathExtension.lowercased()
        let stored = "\(id).\(ext)"
        try write(data, to: attachmentsDir.appendingPathComponent(stored))
        let attachment = ReportAttachment(id: id, reportKey: ref.key, originalFilename: name, storedFilename: stored,
                                          mimeType: type.preferredMIMEType ?? "image/*", byteCount: data.count,
                                          sha256: digest, addedAt: Self.now(), provenance: "Added by you from a file on this Mac")
        index.append(attachment)
        try saveIndex(index)
        return attachment
    }

    public func removeAttachment(_ id: String) {
        var index = allAttachments()
        guard let attachment = index.first(where: { $0.id == id }) else { return }
        try? fm.removeItem(at: attachmentsDir.appendingPathComponent(attachment.storedFilename))
        index.removeAll { $0.id == id }
        try? saveIndex(index)
    }
}
