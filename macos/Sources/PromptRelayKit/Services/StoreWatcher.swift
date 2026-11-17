import CoreServices
import Foundation

/// Watches the BearlyCopy data dir with FSEvents and reports, debounced,
/// that history may have changed. It never reads the files: the app then
/// asks the Core again, which tolerates a file being appended mid-read.
///
/// Only changes under `events/` and to `config.json` count. `handler.log`
/// changes on every hook run, even for projects that are not enabled, so it
/// is ignored to avoid needless Core calls.
public final class StoreWatcher: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case watching
        /// FSEvents could not start (for example the data dir does not exist
        /// yet). The app falls back to a slow timer plus manual refresh.
        case unavailable
    }

    private let directory: URL
    private let latency: CFTimeInterval
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "PromptRelay.StoreWatcher")
    public private(set) var state: State = .stopped

    public init(directory: URL, latency: CFTimeInterval = 0.4, onChange: @escaping @Sendable () -> Void) {
        self.directory = directory.standardizedFileURL
        self.latency = latency
        self.onChange = onChange
    }

    deinit { stop() }

    @discardableResult
    public func start() -> State {
        stop()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            state = .unavailable
            return state
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<StoreWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            let changed = (array as? [String] ?? []).prefix(count)
            if changed.contains(where: watcher.isRelevant) { watcher.onChange() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else {
            state = .unavailable
            return state
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            state = .unavailable
            return state
        }
        stream = created
        state = .watching
        return state
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        state = .stopped
    }

    /// `path` is reported with the real (resolved) prefix, so compare the
    /// part after the watched directory's last component.
    func isRelevant(_ path: String) -> Bool {
        Self.isRelevant(path, root: directory.path)
    }

    static func isRelevant(_ path: String, root: String) -> Bool {
        let resolvedRoot = (root as NSString).resolvingSymlinksInPath
        let candidates = [root, resolvedRoot, "/private" + root]
        for prefix in candidates where path.hasPrefix(prefix) {
            let rest = String(path.dropFirst(prefix.count))
            if rest.hasPrefix("/events/") || rest == "/events" { return rest.hasSuffix(".jsonl") || rest == "/events" }
            if rest == "/config.json" { return true }
            return false
        }
        return false
    }
}
