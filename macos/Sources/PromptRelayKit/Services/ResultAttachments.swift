import Darwin
import Foundation

/// Reads only explicitly observed result paths, never walks the project.
/// Each component is opened without following symlinks, including parent directories.
@MainActor
enum ResultAttachments {
    static let maxTotalBytes = 100 * 1024 * 1024
    static let extensions: Set<String> = ["md", "markdown", "txt", "pdf", "png", "jpg", "jpeg", "gif", "webp", "heic", "csv"]

    static func read(path: String, root: String, remaining: Int) -> Data? {
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        let absolute = path.hasPrefix("/") ? path : base + "/" + path
        let normalized = URL(fileURLWithPath: absolute).standardizedFileURL.path
        guard normalized.hasPrefix(base + "/") else { return nil }
        let parts = String(normalized.dropFirst(base.count + 1)).split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ component in
            let c = component.lowercased()
            return !c.hasPrefix(".") && !["credential", "secret", "password", "private", "token", "keychain"].contains(where: c.contains)
        }), extensions.contains(URL(fileURLWithPath: normalized).pathExtension.lowercased()) else { return nil }
        var fd = Darwin.open(base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        for (index, part) in parts.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (index < parts.count - 1 ? O_DIRECTORY : 0)
            let next = openat(fd, part, flags)
            guard next >= 0 else { return nil }
            Darwin.close(fd)
            fd = next
        }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= min(remaining, ReportStore.maxAttachmentBytes) else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: Int(before.st_size) + 1), data.count == before.st_size else { return nil }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { return nil }
        if let text = String(data: data, encoding: .utf8), !SecretScanner.scan(text, section: "attachment").isEmpty { return nil }
        return data
    }
}

extension ReportStore {
    /// Persist successful discoveries, including files later removed by the user.
    /// Rediscovery must never reselect a checkbox or recreate a removed attachment.
    func prepareResults(_ show: ShowData) throws -> Int {
        guard let rootPath = show.session.project.path, let answer = show.turn.finalResponse?.text,
              let observed = show.turn.observedDetail else { return 0 }
        let ref = ReportRef.local(sessionKey: show.session.sessionKey, turn: show.turn.index)
        let ledger = root.appendingPathComponent("prepared-results.json")
        var prepared: [String: Set<String>] = [:]
        if FileManager.default.fileExists(atPath: ledger.path) {
            prepared = try JSONDecoder().decode([String: Set<String>].self, from: Data(contentsOf: ledger))
        }
        let candidates = AppModel.suggestions(observed: observed, answer: answer, root: rootPath,
                                              addedPaths: [], addedURLs: [], exists: { _ in true })
        var total = attachments(for: ref).reduce(0) { $0 + $1.byteCount }
        var count = 0
        for candidate in candidates where candidate.kind == .file && !candidate.id.hasPrefix("found:") {
            guard let path = candidate.path else { continue }
            let absolute = path.hasPrefix("/") ? path : rootPath + "/" + path
            let canonical = URL(fileURLWithPath: absolute).standardizedFileURL.path
            guard !(prepared[ref.key] ?? []).contains(canonical),
                  let data = ResultAttachments.read(path: path, root: rootPath, remaining: ResultAttachments.maxTotalBytes - total) else { continue }
            guard ReportStore.classify(data, name: canonical) != nil else { continue }
            let display = AppModel.displayPath(canonical, root: rootPath)
            // Existing manual snapshots retain their selection and bytes.
            if !attachments(for: ref).contains(where: { $0.originalPath == display }) {
                _ = try addData(data, name: URL(fileURLWithPath: canonical).lastPathComponent, to: ref,
                                source: .agentResult, displayPath: display, sourceProvider: show.session.provider)
                total += data.count
                count += 1
            }
            prepared[ref.key, default: []].insert(canonical)
        }
        if !prepared.isEmpty {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(prepared).write(to: ledger, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledger.path)
        }
        return count
    }
}
