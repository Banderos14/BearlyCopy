import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ReportStoreError: Error, Equatable, Sendable {
    case empty
    case notAnImage(String)
    case tooLarge(String)
    case unreadable(String)
    /// The file exists but this user may not read it.
    case noPermission(String)
    /// The extension says image, the bytes are not a readable image.
    case damagedImage(String)
    case writeFailed
    case removeFailed
    /// Not an image, a PDF or a UTF-8 text document Prompt Relay keeps.
    case unsupported(String)
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

    // MARK: Ephemeral window snapshots (Phase 10)

    /// Phase 10: window snapshots live in this process's memory only. They are
    /// listed, selected and handed off like any attachment, but are never
    /// written to the attachments folder, the index, the hand-off folder or
    /// any other file by Prompt Relay, and are gone when the app quits.
    /// Bounded by count, total bytes and age; the oldest go first.
    public struct EphemeralLimits: Equatable, Sendable {
        public var maxCount: Int
        public var maxTotalBytes: Int
        public var maxAge: TimeInterval
        public static let standard = EphemeralLimits(maxCount: 12, maxTotalBytes: 96 * 1024 * 1024, maxAge: 4 * 60 * 60)
    }
    public var ephemeralLimits = EphemeralLimits.standard
    private var ephemeral: [ReportAttachment] = []
    private var ephemeralData: [String: Data] = [:]
    private var ephemeralBorn: [String: Date] = [:]
    /// Injectable clock for the age limit (tests).
    var clock: () -> Date = Date.init

    /// Total bytes held in memory now (Settings / diagnostics).
    public var ephemeralBytes: Int { ephemeralData.values.reduce(0) { $0 + $1.count } }

    /// Keeps an image in memory only and lists it with the report. The same
    /// bytes for the same report are kept once. Over the limits the oldest
    /// snapshots are dropped (never a persistent attachment).
    @discardableResult
    public func addEphemeralImage(_ data: Data, name: String, to ref: ReportRef, source: AttachmentSource,
                                  sourceProvider: AgentProvider? = nil) throws -> ReportAttachment {
        guard !data.isEmpty else { throw ReportStoreError.empty }
        guard let type = Self.imageType(of: data) else { throw ReportStoreError.damagedImage(name) }
        guard data.count <= ephemeralLimits.maxTotalBytes, data.count <= Self.maxAttachmentBytes else { throw ReportStoreError.tooLarge(name) }
        expireEphemeral()
        let digest = Self.sha256(data)
        if let existing = ephemeral.first(where: { $0.reportKey == ref.key && $0.sha256 == digest }) { return existing }
        let id = "mem-" + UUID().uuidString.lowercased()
        var attachment = ReportAttachment(id: id, reportKey: ref.key, originalFilename: name,
                                          storedFilename: "", mimeType: type.preferredMIMEType ?? "image/png",
                                          byteCount: data.count, sha256: digest, addedAt: Self.now(),
                                          provenance: Self.provenance(source) + ". Kept in memory only (not saved to disk)")
        attachment.kind = .image
        attachment.source = source
        attachment.sourceProvider = sourceProvider
        attachment.inMemory = true
        ephemeral.append(attachment)
        ephemeralData[id] = data
        ephemeralBorn[id] = clock()
        while ephemeral.count > ephemeralLimits.maxCount || ephemeralBytes > ephemeralLimits.maxTotalBytes {
            dropEphemeral(ephemeral[0].id)
        }
        return attachment
    }

    /// The bytes of an attachment: memory for a snapshot, the private copy otherwise.
    public func data(for attachment: ReportAttachment) -> Data? {
        if attachment.isInMemory { expireEphemeral(); return ephemeralData[attachment.id] }
        return fileURL(for: attachment).flatMap { try? Data(contentsOf: $0) }
    }

    /// Present now (in memory, or its private file exists).
    public func isAvailable(_ attachment: ReportAttachment) -> Bool {
        if attachment.isInMemory { expireEphemeral(); return ephemeralData[attachment.id] != nil }
        return fileURL(for: attachment) != nil
    }

    private func expireEphemeral() {
        let now = clock()
        for a in ephemeral where now.timeIntervalSince(ephemeralBorn[a.id] ?? now) >= ephemeralLimits.maxAge {
            dropEphemeral(a.id)
        }
    }

    private func dropEphemeral(_ id: String) {
        ephemeral.removeAll { $0.id == id }
        ephemeralData[id] = nil
        ephemeralBorn[id] = nil
    }

    /// Forgets every in-memory snapshot (Settings: turning auto-capture off
    /// keeps them; this is for an explicit "Clear snapshots").
    public func clearEphemeral() {
        ephemeral.removeAll()
        ephemeralData.removeAll()
        ephemeralBorn.removeAll()
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
                             sessionLabel: String?, assistant: String? = nil,
                             importedAs: String? = nil, host: AgentHost? = nil) throws -> (report: ImportedReport, isDuplicate: Bool) {
        guard !text.isEmpty else { throw ReportStoreError.empty }
        let task = task.flatMap { $0.isEmpty ? nil : $0 }
        let digest = Self.sha256(Data((text + "\u{0}" + (task ?? "")).utf8))
        if let existing = imports().first(where: { $0.digest == digest && $0.assistant == assistant && $0.host == host && $0.projectPath == projectPath && (sessionLabel == nil || $0.sessionLabel == sessionLabel.flatMap { $0.isEmpty ? nil : $0 }) }) { return (existing, true) }
        try ensure(importsDir)
        var report = ImportedReport(id: UUID().uuidString.lowercased(), importedAt: Self.now(), text: text, task: task,
                                    projectPath: projectPath, projectName: projectName,
                                    sessionLabel: sessionLabel.flatMap { $0.isEmpty ? nil : $0 }, digest: digest)
        report.assistant = assistant
        report.importedAs = importedAs
        report.host = host
        try write(try JSONEncoder().encode(report), to: importsDir.appendingPathComponent("\(report.id).json"))
        return (report, false)
    }

    /// Removes an import and its attachments. History captured by the Core is untouched.
    public func deleteImport(_ id: String) {
        try? fm.removeItem(at: importsDir.appendingPathComponent("\(id).json"))
        for attachment in attachments(for: .imported(id: id)) { try? removeAttachment(attachment.id) }
    }

    // MARK: Attachments

    public func allAttachments() -> [ReportAttachment] {
        expireEphemeral()
        return persistedAttachments() + ephemeral
    }

    private func persistedAttachments() -> [ReportAttachment] {
        guard let data = try? Data(contentsOf: attachmentIndex) else { return [] }
        return ((try? JSONDecoder().decode([ReportAttachment].self, from: data)) ?? []).filter { !$0.isInMemory }
    }

    /// Only persistent records are ever written; in-memory snapshots never are.
    private func saveIndex(_ list: [ReportAttachment]) throws {
        try ensure(attachmentsDir)
        try write(try JSONEncoder().encode(list.filter { !$0.isInMemory }), to: attachmentIndex)
    }

    public func attachments(for ref: ReportRef) -> [ReportAttachment] {
        allAttachments().filter { $0.reportKey == ref.key }.sorted { $0.addedAt < $1.addedAt }
    }

    /// The private copy of an attachment, or nil when it is missing. A
    /// stored name that is not a plain file name (a damaged or edited index)
    /// never resolves outside the attachments folder.
    public func fileURL(for attachment: ReportAttachment) -> URL? {
        let name = attachment.storedFilename
        guard !attachment.isInMemory, !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else { return nil }
        let url = attachmentsDir.appendingPathComponent(name)
        guard url.deletingLastPathComponent().standardizedFileURL == attachmentsDir.standardizedFileURL else { return nil }
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    /// Copies an image the user chose into the private folder; the original
    /// is only read, never changed. The bytes must decode as an image (the
    /// type comes from the content, not the name), at most 50 MB. The same
    /// image added twice to a report is kept once.
    @discardableResult
    public func addAttachment(from source: URL, to ref: ReportRef) throws -> ReportAttachment {
        let name = source.lastPathComponent
        if let type = UTType(filenameExtension: source.pathExtension), !type.conforms(to: .image) {
            throw ReportStoreError.notAnImage(name)
        }
        if source.pathExtension.isEmpty { throw ReportStoreError.notAnImage(name) }
        let size = (try? fm.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0
        guard size <= Self.maxAttachmentBytes else { throw ReportStoreError.tooLarge(name) }
        let data: Data
        do { data = try Data(contentsOf: source) } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw ReportStoreError.noPermission(name)
        } catch {
            throw ReportStoreError.unreadable(name)
        }
        guard let type = Self.imageType(of: data) else { throw ReportStoreError.damagedImage(name) }
        let digest = Self.sha256(data)
        var index = persistedAttachments()
        if let existing = index.first(where: { $0.reportKey == ref.key && $0.sha256 == digest }) { return existing }
        try ensure(attachmentsDir)
        let id = UUID().uuidString.lowercased()
        let stored = "\(id).\(type.preferredFilenameExtension ?? "img")"
        try write(data, to: attachmentsDir.appendingPathComponent(stored))
        let attachment = ReportAttachment(id: id, reportKey: ref.key, originalFilename: name, storedFilename: stored,
                                          mimeType: type.preferredMIMEType ?? "image/*", byteCount: data.count,
                                          sha256: digest, addedAt: Self.now(), provenance: "Added by you from a file on this Mac")
        index.append(attachment)
        try saveIndex(index)
        return attachment
    }

    // MARK: Typed files (Phase 5, ADR-016)

    public static let maxDocumentBytes = 1024 * 1024
    /// Text formats kept as documents (the bytes must also be UTF-8).
    static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "json", "jsonl", "csv", "tsv", "yaml", "yml", "toml", "xml", "html", "htm",
        "css", "js", "mjs", "ts", "tsx", "jsx", "swift", "py", "rb", "go", "rs", "java", "kt", "c", "h", "m", "mm",
        "cpp", "hpp", "sh", "zsh", "bash", "sql", "log", "ini", "conf", "cfg", "plist", "diff", "patch", "rst",
    ]

    /// What a file is, from its bytes (and, for text, its extension).
    static func classify(_ data: Data, name: String) -> (AttachmentKind, UTType)? {
        if let type = imageType(of: data) { return (.image, type) }
        if data.starts(with: Array("%PDF-".utf8)), let provider = CGDataProvider(data: data as CFData),
           let pdf = CGPDFDocument(provider), pdf.numberOfPages > 0 {
            return (.pdf, .pdf)
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if textExtensions.contains(ext), data.count <= maxDocumentBytes, String(data: data, encoding: .utf8) != nil {
            return (.document, UTType(filenameExtension: ext) ?? .plainText)
        }
        return nil
    }

    /// Copies a document, PDF or image into the private folder as a snapshot
    /// of this moment. The original is only read. Same bytes for the same
    /// report (and mockup state) are kept once.
    @discardableResult
    public func addFile(from url: URL, to ref: ReportRef, source: AttachmentSource = .you, displayPath: String? = nil,
                        mockupID: String? = nil, stateID: String? = nil, filename: String? = nil) throws -> ReportAttachment {
        let name = filename ?? url.lastPathComponent
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ReportStoreError.unreadable(name)
        }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= Self.maxAttachmentBytes else { throw ReportStoreError.tooLarge(name) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw ReportStoreError.noPermission(name)
        } catch {
            throw ReportStoreError.unreadable(name)
        }
        return try addData(data, name: name, to: ref, source: source, displayPath: displayPath, mockupID: mockupID, stateID: stateID)
    }

    /// The same for bytes that are not a file yet (a clipboard image).
    @discardableResult
    public func addData(_ data: Data, name: String, to ref: ReportRef, source: AttachmentSource,
                        displayPath: String? = nil, mockupID: String? = nil, stateID: String? = nil, sourceProvider: AgentProvider? = nil) throws -> ReportAttachment {
        guard !data.isEmpty else { throw ReportStoreError.empty }
        guard let (kind, type) = Self.classify(data, name: name) else {
            let ext = (name as NSString).pathExtension.lowercased()
            if let t = UTType(filenameExtension: ext), t.conforms(to: .image) { throw ReportStoreError.damagedImage(name) }
            throw ReportStoreError.unsupported(name)
        }
        let digest = Self.sha256(data)
        var index = persistedAttachments()
        if let existing = index.first(where: { $0.reportKey == ref.key && $0.sha256 == digest && $0.mockupID == mockupID
                                               && $0.stateID == stateID && (source != .agentResult || $0.originalPath == displayPath) }) {
            return existing
        }
        try ensure(attachmentsDir)
        let id = UUID().uuidString.lowercased()
        let ext = kind == .document ? ((name as NSString).pathExtension.isEmpty ? "txt" : (name as NSString).pathExtension.lowercased())
            : (type.preferredFilenameExtension ?? "bin")
        let stored = "\(id).\(ext)"
        try write(data, to: attachmentsDir.appendingPathComponent(stored))
        var attachment = ReportAttachment(id: id, reportKey: ref.key, originalFilename: name, storedFilename: stored,
                                          mimeType: type.preferredMIMEType ?? (kind == .document ? "text/plain" : "application/octet-stream"),
                                          byteCount: data.count, sha256: digest, addedAt: Self.now(),
                                          provenance: Self.provenance(source))
        attachment.kind = kind
        attachment.source = source
        attachment.sourceProvider = sourceProvider
        attachment.originalPath = displayPath
        attachment.mockupID = mockupID
        attachment.stateID = stateID
        index.append(attachment)
        try saveIndex(index)
        return attachment
    }

    static func provenance(_ source: AttachmentSource) -> String {
        switch source {
        case .you: return "Added by you from a file on this Mac"
        case .claude: return "Shown or written by Claude in this turn; added by you"
        case .named: return "Named in the agent's answer and found in the project (not seen being written); added by you"
        case .clipboard: return "Copied to your clipboard; added by you"
        case .agentObserved: return "Observed in this turn; added by you"
        case .agentResult: return "Observed result file; automatically prepared from this turn"
        case .namedVerified: return "Named in the answer and changed during this turn (local file time); automatically prepared. Not proof the agent created it"
        case .windowCapture: return "Still image of the window you chose for auto-capture, taken after this final answer arrived"
        case .windowSnapshot: return "Still image of the window you picked in the macOS picker"
        }
    }

    /// Include or exclude an attachment from Copy for ChatGPT and the hand-off.
    public func setSelected(_ id: String, _ selected: Bool) throws {
        if let i = ephemeral.firstIndex(where: { $0.id == id }) { ephemeral[i].selected = selected; return }
        var index = persistedAttachments()
        guard let i = index.firstIndex(where: { $0.id == id }) else { return }
        index[i].selected = selected
        try saveIndex(index)
    }

    /// The original changed since the snapshot (or is gone): for display.
    public func originalChanged(_ attachment: ReportAttachment, original: URL) -> Bool? {
        guard let data = try? Data(contentsOf: original) else { return nil }
        return Self.sha256(data) != attachment.sha256
    }

    // MARK: Links and mockups

    private var materialsIndex: URL { root.appendingPathComponent("materials.json") }

    public func allMaterials() -> [ReportMaterial] {
        guard let data = try? Data(contentsOf: materialsIndex) else { return [] }
        return (try? JSONDecoder().decode([ReportMaterial].self, from: data)) ?? []
    }

    public func materials(for ref: ReportRef) -> [ReportMaterial] {
        allMaterials().filter { $0.reportKey == ref.key }.sorted { $0.addedAt < $1.addedAt }
    }

    private func saveMaterials(_ list: [ReportMaterial]) throws {
        try ensure(root)
        try write(try JSONEncoder().encode(list), to: materialsIndex)
    }

    /// Adds a link or mockup; the same URL (or source) for a report is kept once.
    @discardableResult
    public func addMaterial(_ material: ReportMaterial) throws -> ReportMaterial {
        var list = allMaterials()
        if let existing = list.first(where: { $0.reportKey == material.reportKey && $0.kind == material.kind
                                              && (($0.url != nil && $0.url == material.url)
                                                  || ($0.url == nil && $0.sourcePath != nil && $0.sourcePath == material.sourcePath)) }) {
            return existing
        }
        list.append(material)
        try saveMaterials(list)
        return material
    }

    public func updateMaterial(_ material: ReportMaterial) throws {
        var list = allMaterials()
        guard let i = list.firstIndex(where: { $0.id == material.id }) else { return }
        list[i] = material
        try saveMaterials(list)
    }

    /// Removes a link or mockup and the state images stored for it.
    public func removeMaterial(_ id: String) throws {
        var list = allMaterials()
        guard let material = list.first(where: { $0.id == id }) else { return }
        list.removeAll { $0.id == id }
        do { try saveMaterials(list) } catch { throw ReportStoreError.removeFailed }
        for attachment in allAttachments() where attachment.mockupID == material.id { try? removeAttachment(attachment.id) }
    }

    /// Stores an image for one state of a mockup (replacing an earlier one).
    @discardableResult
    public func setStateImage(from url: URL, mockupID: String, stateID: String) throws -> ReportMaterial {
        var list = allMaterials()
        guard let i = list.firstIndex(where: { $0.id == mockupID }),
              let s = list[i].states.firstIndex(where: { $0.id == stateID }) else { throw ReportStoreError.writeFailed }
        let ref = Self.ref(forKey: list[i].reportKey)
        let previous = list[i].states[s].attachmentID
        let attachment: ReportAttachment
        do {
            attachment = try addFile(from: url, to: ref, source: .you, mockupID: mockupID, stateID: stateID)
        } catch {
            list[i].states[s].status = .failed
            list[i].states[s].failure = "the image could not be read"
            try? saveMaterials(list)
            throw error
        }
        guard attachment.effectiveKind == .image else {
            try? removeAttachment(attachment.id)
            throw ReportStoreError.notAnImage(url.lastPathComponent)
        }
        list[i].states[s].attachmentID = attachment.id
        list[i].states[s].status = .captured
        list[i].states[s].failure = nil
        try saveMaterials(list)
        if let previous, previous != attachment.id { try? removeAttachment(previous) }
        return list[i]
    }

    /// A ReportRef from its key (only the key is stored with a material).
    static func ref(forKey key: String) -> ReportRef {
        if key.hasPrefix("import-") { return .imported(id: String(key.dropFirst("import-".count))) }
        let body = key.dropFirst("local-".count)
        if let dash = body.lastIndex(of: "-"), let turn = Int(body[body.index(after: dash)...]) {
            return .local(sessionKey: String(body[..<dash]), turn: turn)
        }
        return .local(sessionKey: String(body), turn: 0)
    }

    /// The image type read from the bytes, when they decode as an image.
    static func imageType(of data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier), type.conforms(to: .image),
              CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                              kCGImageSourceThumbnailMaxPixelSize: 8] as CFDictionary) != nil
        else { return nil }
        return type
    }

    /// Unlinks one image from its report. The report's text and its other
    /// images are untouched; the stored file is deleted only when no other
    /// record uses it. The index is saved first, so a failure never leaves a
    /// record pointing at a deleted file.
    public func removeAttachment(_ id: String) throws {
        if ephemeral.contains(where: { $0.id == id }) { dropEphemeral(id); return }
        var index = persistedAttachments()
        guard let attachment = index.first(where: { $0.id == id }) else { return }
        index.removeAll { $0.id == id }
        do { try saveIndex(index) } catch { throw ReportStoreError.removeFailed }
        if !index.contains(where: { $0.storedFilename == attachment.storedFilename }), let url = fileURL(for: attachment) {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: Hand-off copies

    private var handoffDir: URL { root.appendingPathComponent("handoff", isDirectory: true) }

    /// Copies of a report's images under their original names, for dragging,
    /// Copy File and Finder: an app receiving "3f2a….png" would show that name.
    /// Rebuilt on each call; only this folder is ever cleared.
    public func handoffFiles(for attachments: [ReportAttachment], names: [String: String] = [:]) throws -> [URL] {
        try? fm.removeItem(at: handoffDir)
        try ensure(handoffDir)
        var used = Set<String>()
        var urls: [URL] = []
        for attachment in attachments where !attachment.isInMemory {
            guard let source = fileURL(for: attachment) else { continue }
            let wanted = names[attachment.id] ?? attachment.originalFilename
            let name = Self.uniqueName(Self.safeFilename(wanted, fallback: attachment.storedFilename), used: &used)
            let target = handoffDir.appendingPathComponent(name)
            do {
                try fm.copyItem(at: source, to: target)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            } catch { throw ReportStoreError.writeFailed }
            urls.append(target)
        }
        return urls
    }

    static func safeFilename(_ name: String, fallback: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? fallback : cleaned
    }

    static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        var candidate = name, n = 2
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while used.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            n += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }
}
