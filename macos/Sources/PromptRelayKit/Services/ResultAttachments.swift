import Darwin
import Foundation

/// Reads only explicitly observed result paths, never walks the project.
/// Each component is opened without following symlinks, including parent directories.
@MainActor
enum ResultAttachments {
    static let maxTotalBytes = 100 * 1024 * 1024
    /// Phase 17: JSON and HTML join (a schema or a report page is a common
    /// deliverable; before, `api-v1.schema.json` stayed an "Add" suggestion).
    static let extensions: Set<String> = ["md", "markdown", "txt", "pdf", "png", "jpg", "jpeg", "gif", "webp", "heic", "csv",
                                          "json", "html", "htm"]

    /// Phase 17: why a result file was not prepared automatically. Shown in
    /// "From this turn" instead of a bare Add.
    enum Skip: String, Equatable, Sendable {
        /// Not inside the answer's own project or worktree (or reached through a symlink).
        case outsideProject
        /// A hidden file or a name that looks like credentials.
        case sensitiveName
        /// The text matches a secret pattern (key, token, password assignment).
        case secretContent
        case unsupportedType
        case missing
        case empty
        case tooLarge
        /// Being written while it was read.
        case unstable
        /// Named only, and older than this turn (`modifiedAfter`).
        case notChangedThisTurn
        /// Modified after the answer arrived: its bytes are no longer the ones the answer describes.
        case changedAfterAnswer
        /// More named files than are attached without asking.
        case overNamedLimit
        /// The store refused it (unreadable image, lock, disk).
        case storeFailed

        /// The state shown for the row.
        var title: String {
            switch self {
            case .sensitiveName, .secretContent, .outsideProject: return "Excluded for safety"
            case .unsupportedType, .empty, .tooLarge: return "Not attachable"
            case .missing, .unstable, .storeFailed: return "Failed to attach"
            case .notChangedThisTurn, .overNamedLimit: return "Named but not verified"
            case .changedAfterAnswer: return "Not attached automatically"
            }
        }

        var reason: String {
            switch self {
            case .outsideProject: return "outside this answer's project"
            case .sensitiveName: return "hidden or credential-like name"
            case .secretContent: return "it seems to contain a secret"
            case .unsupportedType: return "Prompt Relay prepares text, JSON, HTML, PDF and images"
            case .missing: return "the file is not there"
            case .empty: return "the file is empty"
            case .tooLarge: return "too large"
            case .unstable: return "it was changing while read"
            case .notChangedThisTurn: return "not changed during this turn"
            case .changedAfterAnswer: return "changed after this answer — Add takes the current version"
            case .overNamedLimit: return "many files are named — add the ones you need"
            case .storeFailed: return "it could not be saved"
            }
        }

        /// "Excluded for safety — it seems to contain a secret"
        var sentence: String { "\(title) — \(reason)" }
        /// Add would do no better (or should not be one click).
        var blocksManualAdd: Bool { self == .missing || self == .empty || self == .unsupportedType }
    }

    static let sensitiveWords = ["credential", "secret", "password", "passwd", "private", "token", "keychain", "apikey", "api-key",
                                 "api_key", "service-account", "serviceaccount", "adminsdk", "kubeconfig", "htpasswd", "netrc", "id_rsa",
                                 "id_ed25519"]

    /// `modifiedAfter`: Phase 9.3 "named and verified locally" — the file
    /// must have changed at or after this time (the turn's request).
    /// `modifiedBefore`: Phase 17 — and not after this time (the answer's
    /// arrival), so a snapshot taken late never passes newer bytes off as
    /// the ones the answer describes.
    static func read(path: String, root: String, remaining: Int, modifiedAfter: Date? = nil) -> Data? {
        try? load(path: path, root: root, remaining: remaining, modifiedAfter: modifiedAfter).get()
    }

    struct Loaded: Equatable, Sendable { let data: Data; let modified: Date }
    struct SkipError: Error, Equatable { let skip: Skip }

    static func load(path: String, root: String, remaining: Int, modifiedAfter: Date? = nil,
                     modifiedBefore: Date? = nil) -> Result<Data, SkipError> {
        loadFile(path: path, root: root, remaining: remaining, modifiedAfter: modifiedAfter, modifiedBefore: modifiedBefore).map(\.data)
    }

    static func loadFile(path: String, root: String, remaining: Int, modifiedAfter: Date? = nil,
                         modifiedBefore: Date? = nil) -> Result<Loaded, SkipError> {
        func no(_ skip: Skip) -> Result<Loaded, SkipError> { .failure(SkipError(skip: skip)) }
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        let absolute = path.hasPrefix("/") ? path : base + "/" + path
        let normalized = URL(fileURLWithPath: absolute).standardizedFileURL.path
        guard normalized.hasPrefix(base + "/") else { return no(.outsideProject) }
        let parts = String(normalized.dropFirst(base.count + 1)).split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return no(.outsideProject) }
        guard parts.allSatisfy({ component in
            let c = component.lowercased()
            return !c.hasPrefix(".") && !sensitiveWords.contains(where: c.contains)
        }) else { return no(.sensitiveName) }
        guard extensions.contains(URL(fileURLWithPath: normalized).pathExtension.lowercased()) else { return no(.unsupportedType) }
        var fd = Darwin.open(base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return no(.missing) }
        defer { Darwin.close(fd) }
        for (index, part) in parts.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (index < parts.count - 1 ? O_DIRECTORY : 0)
            let next = openat(fd, part, flags)
            // ELOOP / ENOTDIR: a symlink on the way — it may lead out of the project.
            guard next >= 0 else { return no(errno == ENOENT ? .missing : .outsideProject) }
            Darwin.close(fd)
            fd = next
        }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { return no(.unsupportedType) }
        guard before.st_size > 0 else { return no(.empty) }
        guard before.st_size <= min(remaining, ReportStore.maxAttachmentBytes) else { return no(.tooLarge) }
        let mtime = Date(timeIntervalSince1970: TimeInterval(before.st_mtimespec.tv_sec) + TimeInterval(before.st_mtimespec.tv_nsec) / 1e9)
        if let modifiedAfter, mtime < modifiedAfter.addingTimeInterval(-1) { return no(.notChangedThisTurn) }
        if let modifiedBefore, mtime > modifiedBefore.addingTimeInterval(freshnessSlack) { return no(.changedAfterAnswer) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: Int(before.st_size) + 1), data.count == before.st_size else { return no(.unstable) }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { return no(.unstable) }
        if let text = String(data: data, encoding: .utf8), !SecretScanner.scan(text, section: "attachment").isEmpty { return no(.secretContent) }
        return .success(Loaded(data: data, modified: mtime))
    }

    /// A file written up to this long after the answer's Stop still counts
    /// as part of it (the hook and the last write race by milliseconds).
    static let freshnessSlack: TimeInterval = 2
    /// Named in the answer, present, but not seen being written or changed
    /// this turn: at most this many are attached without asking.
    static let maxNamedExisting = 6
}

extension ReportStore {
    /// Persist successful discoveries, including files later removed by the user.
    /// Rediscovery must never reselect a checkbox or recreate a removed attachment.
    func prepareResults(_ show: ShowData) throws -> Int {
        // Phase 16 (S8): the ledger and the index are read and written as one step.
        try withStoreLock { try prepareResultsLocked(show) }
    }

    private func prepareResultsLocked(_ show: ShowData) throws -> Int {
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
        // Phase 10: in-memory window snapshots do not use the result-file budget.
        var total = attachments(for: ref).filter { !$0.isInMemory }.reduce(0) { $0 + $1.byteCount }
        var count = 0
        // Phase 17: the bytes must be the ones the answer describes — a file
        // modified after the answer arrived is offered, not snapshotted.
        let answered = show.turn.finalResponse?.receivedAt.flatMap(Wording.date)
        var skips: [String: ResultAttachments.Skip] = [:]
        var namedExisting = attachments(for: ref).filter { $0.source == .named && $0.autoPrepared == true }.count
        for candidate in candidates where candidate.kind == .file {
            guard let path = candidate.path else { continue }
            let namedOnly = candidate.id.hasPrefix("found:")
            let absolute = path.hasPrefix("/") ? path : cwd + "/" + path
            let canonical = URL(fileURLWithPath: absolute).standardizedFileURL.path
            guard !(prepared[ref.key] ?? []).contains(canonical) else { continue }
            let remaining = ResultAttachments.maxTotalBytes - total
            var source: AttachmentSource = namedOnly ? .namedVerified : .agentResult
            var loaded = ResultAttachments.load(path: canonical, root: rootPath, remaining: remaining,
                                                modifiedAfter: namedOnly ? turnStarted : nil, modifiedBefore: answered)
            // Phase 17: named in the answer, present in this project, but not
            // changed during this turn (an existing document the answer
            // refers to). Prepared too, under its own honest provenance.
            if namedOnly, turnStarted == nil || loaded == .failure(.init(skip: .notChangedThisTurn)) {
                source = .named
                loaded = namedExisting < ResultAttachments.maxNamedExisting
                    ? ResultAttachments.load(path: canonical, root: rootPath, remaining: remaining, modifiedBefore: answered)
                    : .failure(.init(skip: .overNamedLimit))
            }
            let data: Data
            switch loaded {
            case .success(let bytes): data = bytes
            case .failure(let error): skips[canonical] = error.skip; continue
            }
            guard ReportStore.classify(data, name: canonical) != nil else {
                let isText = ReportStore.textExtensions.contains(URL(fileURLWithPath: canonical).pathExtension.lowercased())
                skips[canonical] = isText && data.count > ReportStore.maxDocumentBytes ? .tooLarge : .unsupportedType
                continue
            }
            let display = AppModel.displayPath(canonical, root: rootPath)
            // Existing manual snapshots retain their selection and bytes.
            if !attachments(for: ref).contains(where: { $0.originalPath == display }) {
                do {
                    let stored = try addData(data, name: URL(fileURLWithPath: canonical).lastPathComponent, to: ref,
                                             source: source, displayPath: display, sourceProvider: show.session.provider,
                                             autoPrepared: true, selected: autoSelectsPrepared)
                    if stored.originalPath != display {
                        // The same bytes are attached already under another path: kept once.
                        prepareDuplicates[ref.key, default: [:]][canonical] = stored.id
                        prepared[ref.key, default: []].insert(canonical)
                        continue
                    }
                } catch ReportStoreError.lockUnavailable {
                    throw ReportStoreError.lockUnavailable
                } catch {
                    skips[canonical] = .storeFailed; continue
                }
                total += data.count
                count += 1
                if source == .named { namedExisting += 1 }
            }
            prepared[ref.key, default: []].insert(canonical)
        }
        prepareSkips[ref.key] = skips.isEmpty ? nil : skips
        if !prepared.isEmpty {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(prepared).write(to: ledger, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledger.path)
        }
        return count
    }
}
