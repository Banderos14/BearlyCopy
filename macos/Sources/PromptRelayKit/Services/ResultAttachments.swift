import Darwin
import Foundation

/// Reads only explicitly observed result paths, never walks the project.
/// Each component is opened without following symlinks, including parent directories.
@MainActor
enum ResultAttachments {
    static let maxTotalBytes = 100 * 1024 * 1024
    static let extensions: Set<String> = ["md", "markdown", "txt", "pdf", "png", "jpg", "jpeg", "gif", "webp", "heic", "csv"]

    /// `modifiedAfter`: Phase 9.3 "named and verified locally" — the file
    /// must have changed at or after this time (the turn's request), so an
    /// old file the answer merely mentions is never picked automatically.
    static func read(path: String, root: String, remaining: Int, modifiedAfter: Date? = nil) -> Data? {
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
        if let modifiedAfter {
            let mtime = Date(timeIntervalSince1970: TimeInterval(before.st_mtimespec.tv_sec) + TimeInterval(before.st_mtimespec.tv_nsec) / 1e9)
            guard mtime >= modifiedAfter.addingTimeInterval(-1) else { return nil }
        }
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
        guard let cwd = show.session.project.path, let answer = show.turn.finalResponse?.text,
              let own = show.turn.observedDetail else { return 0 }
        // Phase 9.4: an intermediate Stop is not the result; its files are
        // prepared with the final answer that continues it.
        guard show.turn.completion.isFinal || show.turn.completion == .waitingBackground && show.turn.workChain == nil
                && AppModel.waitExpired(show.turn.finalResponse?.receivedAt) else { return 0 }
        // The follow-up of background work: the files of the task's earlier
        // turns (same session) count as observed for this answer.
        let chain = show.turn.workChain
        let observed = ObservedDetail(commands: own.commands, filesChanged: (chain?.filesChanged ?? []) + own.filesChanged,
                                      shownFiles: (chain?.shownFiles ?? []) + own.shownFiles.filter { !(chain?.shownFiles ?? []).contains($0) },
                                      artifacts: own.artifacts, notifications: own.notifications)
        // Phase 9.3: an agent in `<repo>/macos` may name `<repo>/docs/…`. The
        // allowed root is the logical project when it contains the folder
        // (an enabled project or a verified Git root), else the folder.
        let logical = show.session.logicalProject?.path
        let rootPath = logical.flatMap { AppModel.path(cwd, isInside: $0) ? $0 : nil } ?? cwd
        let turnStarted = (chain?.startedAt ?? show.turn.request?.receivedAt).flatMap(Wording.date)
        let ref = ReportRef.local(sessionKey: show.session.sessionKey, turn: show.turn.index)
        let ledger = root.appendingPathComponent("prepared-results.json")
        var prepared: [String: Set<String>] = [:]
        if FileManager.default.fileExists(atPath: ledger.path) {
            prepared = try JSONDecoder().decode([String: Set<String>].self, from: Data(contentsOf: ledger))
        }
        // Observed output (a tool confirmed the write and the answer names it)
        // first; then files only named in the answer, relative to the folder
        // the agent ran in or to the project, which qualify only when they
        // changed during this turn ("named and verified locally").
        func exists(_ path: String) -> Bool {
            var st = stat()
            return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG
        }
        var candidates = AppModel.suggestions(observed: observed, answer: answer, root: cwd,
                                              addedPaths: [], addedURLs: [], exists: exists)
        if rootPath != cwd {
            let known = Set(candidates.compactMap(\.path))
            candidates += AppModel.suggestions(observed: observed, answer: answer, root: rootPath, addedPaths: [],
                                               addedURLs: [], exists: exists).filter { !known.contains($0.path ?? "") }
        }
        var total = attachments(for: ref).reduce(0) { $0 + $1.byteCount }
        var count = 0
        for candidate in candidates where candidate.kind == .file {
            guard let path = candidate.path else { continue }
            let namedOnly = candidate.id.hasPrefix("found:")
            if namedOnly && turnStarted == nil { continue }   // no turn window: offer only
            let absolute = path.hasPrefix("/") ? path : cwd + "/" + path
            let canonical = URL(fileURLWithPath: absolute).standardizedFileURL.path
            guard !(prepared[ref.key] ?? []).contains(canonical),
                  let data = ResultAttachments.read(path: canonical, root: rootPath, remaining: ResultAttachments.maxTotalBytes - total,
                                                    modifiedAfter: namedOnly ? turnStarted : nil) else { continue }
            guard ReportStore.classify(data, name: canonical) != nil else { continue }
            let display = AppModel.displayPath(canonical, root: rootPath)
            // Existing manual snapshots retain their selection and bytes.
            if !attachments(for: ref).contains(where: { $0.originalPath == display }) {
                _ = try addData(data, name: URL(fileURLWithPath: canonical).lastPathComponent, to: ref,
                                source: namedOnly ? .namedVerified : .agentResult, displayPath: display,
                                sourceProvider: show.session.provider)
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
