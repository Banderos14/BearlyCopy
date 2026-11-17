import AppKit

/// Phase 7: one result written to a folder the user chose: the Copy with
/// Context text, the chosen attachments (their stored snapshots, byte for
/// byte) and a small manifest of what is in it, what is missing and where
/// each part came from. Local only: nothing is uploaded, no project file is
/// read, and the package goes through the same secret check as a copy.
public enum ExportBundle {
    public struct FileEntry: Codable, Equatable, Sendable {
        public let name: String
        /// "included", or "missing" when the stored snapshot cannot be read.
        public let status: String
        public let provenance: String
        public let sha256: String
        public let bytes: Int
    }

    public struct Manifest: Codable, Equatable, Sendable {
        public var format = "prompt-relay-export-bundle/1"
        public let exportedAt: String
        public let source: String
        public let project: String
        public let session: String
        public let turn: Int?
        public let detail: String
        public let package: String
        public let files: [FileEntry]
        /// Mockups and links: listed only, never fetched.
        public let materials: [String]
        public let limitations: [String]
    }

    /// A folder name without characters Finder or shells trip over.
    static func safe(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        let squeezed = cleaned.replacingOccurrences(of: "-+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return String((squeezed.isEmpty ? "result" : squeezed).prefix(48))
    }

    /// Writes the bundle into a new folder inside `parent`; returns it.
    /// Never overwrites: a taken name gets " 2", " 3"…
    public static func write(into parent: URL, name: String, package: String, files: [(attachment: ReportAttachment, url: URL?)],
                             memory: [String: Data] = [:], packageName: String = "context.md",
                             manifest make: ([FileEntry]) -> Manifest?) throws -> URL {
        let fm = FileManager.default
        var folder = parent.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) { folder = parent.appendingPathComponent("\(name) \(n)", isDirectory: true); n += 1 }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data(package.utf8).write(to: folder.appendingPathComponent(packageName))
        var entries: [FileEntry] = []
        if !files.isEmpty {
            let dir = folder.appendingPathComponent("files", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: false)
            var used = Set<String>()
            for (a, url) in files {
                var fileName = (a.originalFilename as NSString).lastPathComponent
                if fileName.isEmpty || fileName.hasPrefix(".") { fileName = "file-" + fileName }
                let base = (fileName as NSString).deletingPathExtension, ext = (fileName as NSString).pathExtension
                var k = 2
                while used.contains(fileName.lowercased()) { fileName = ext.isEmpty ? "\(base) \(k)" : "\(base) \(k).\(ext)"; k += 1 }
                used.insert(fileName.lowercased())
                // Phase 10: an in-memory snapshot is written only here, into
                // the folder the user chose for this export.
                if let data = memory[a.id] ?? url.flatMap({ try? Data(contentsOf: $0) }) {
                    try data.write(to: dir.appendingPathComponent(fileName))
                    entries.append(FileEntry(name: "files/" + fileName, status: "included", provenance: a.provenance, sha256: a.sha256, bytes: data.count))
                } else {
                    entries.append(FileEntry(name: "files/" + fileName, status: "missing", provenance: a.provenance, sha256: a.sha256, bytes: 0))
                }
            }
        }
        // Phase 13: a Context Pack writes its own manifest (PackManifest).
        guard let manifest = make(entries) else { return folder }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        return folder
    }
}

extension AppModel {
    @discardableResult
    public func writeBundle(_ ref: ReportRef, into parent: URL) async -> URL? {
        switch await buildPack(ref) {
        case .failure(let f):
            finishCopy(.failed(f.message)); return nil
        case .success(let pack):
            guard pack.findings.isEmpty else {
                finishCopy(.failed("Not exported: the package may contain secrets (\(pack.findings.count)). Review it in Preview."))
                return nil
            }
            let (project, label) = describe(ref)
            let chosen = handoffAttachments(for: ref)
            let materials = materials(for: ref).filter(\.selected).map { m in
                m.kind == .mockup ? "mockup “\(m.title)”: \(m.states.filter { $0.status == .captured }.count)/\(m.states.count) states captured; only captured images are in files/"
                                  : "link “\(m.title)”: \(m.url ?? "no address"); the page itself is not included"
            }
            let turn: Int? = { if case .local(_, let i) = ref { return i } else { return nil } }()
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let name = "BearlyCopy \(ExportBundle.safe(project)) \(turn.map { "turn \($0)" } ?? "import") \(stamp.prefix(15))"
            do {
                let folder = try ExportBundle.write(into: parent, name: name, package: pack.text,
                                                    files: chosen.map { ($0, attachmentURL($0)) },
                                                    memory: Dictionary(uniqueKeysWithValues: chosen.filter(\.isInMemory)
                                                        .compactMap { a in attachmentData(a).map { (a.id, $0) } })) { entries in
                    ExportBundle.Manifest(exportedAt: pack.builtAt,
                                          source: selectedImport != nil ? "imported by you" : "captured on this Mac by the BearlyCopy hooks",
                                          project: project, session: label, turn: turn, detail: pack.detail.rawValue,
                                          package: "context.md", files: entries, materials: materials,
                                          limitations: ["Only the chosen attachments are included.",
                                                        "No project files and no other sessions were read.",
                                                        "Mockups and links are listed, not fetched or run."])
                }
                finishCopy(.copied(.files, characters: pack.text.unicodeScalars.count), token: Self.exportToken(ref))
                lastExportFolder = folder
                return folder
            } catch {
                finishCopy(.failed("Export failed: \(error.localizedDescription)"))
                return nil
            }
        }
    }

    static func exportToken(_ ref: ReportRef?) -> String { "export|\(ref?.key ?? "-")" }
}
