import AppKit

/// Which Prompt Relay build this is, and whether another one runs.
///
/// Debug (Xcode) and Release builds have different bundle IDs, so they keep
/// separate preferences and can run side by side: two menu-bar icons and,
/// with the notch on in both, two islands on top of each other. The Release
/// build steps aside at the notch while a Debug build runs; Settings says
/// when several builds run and quits the other one only on request.
public enum AppBuild {
    public static let releaseBundleID = "io.github.banderos14.PromptRelay"
    public static let debugBundleID = "io.github.banderos14.PromptRelay.debug"

    public static var bundleID: String? { Bundle.main.bundleIdentifier }
    public static var isDebugBuild: Bool { bundleID == debugBundleID }

    /// Prompt Relay builds in `running` other than this process (a second
    /// copy with the same bundle ID counts too).
    public static func otherBuilds(own: String?, running: [String]) -> [String] {
        let known: Set<String> = [releaseBundleID, debugBundleID]
        var others = Set(running.filter { known.contains($0) && $0 != own })
        if let own, running.filter({ $0 == own }).count > 1 { others.insert(own) }
        return others.sorted()
    }

    @MainActor
    public static func otherBuildsRunning() -> [String] {
        otherBuilds(own: bundleID, running: NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// Quits the other build, only when the user asks for it (Settings →
    /// About). Asks the app to quit normally; never forces it.
    @MainActor
    public static func quit(_ otherBundleID: String) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: otherBundleID)
        where app.processIdentifier != ownPID {
            app.terminate()
        }
    }

    /// One running copy of Prompt Relay.
    public struct Copy: Equatable, Sendable {
        public let pid: Int32
        public let bundleID: String
        public let launched: Date?
        public init(pid: Int32, bundleID: String, launched: Date?) { self.pid = pid; self.bundleID = bundleID; self.launched = launched }
    }

    /// The copies this one steps aside for at the notch, so only one Relay is
    /// ever on screen (Phase 7.1: two Debug runs and an installed build drew
    /// two or three bears; only Release → Debug used to step aside). A
    /// Release build yields to any Debug build; within one bundle ID the
    /// newest launch keeps the notch (ties: the higher PID). Builds from
    /// before Phase 7.1 do not follow this rule; Settings offers to quit them.
    public static func yields(own: Copy, to running: [Copy]) -> [Copy] {
        running.filter { other in
            guard other.pid != own.pid, [releaseBundleID, debugBundleID].contains(other.bundleID) else { return false }
            if own.bundleID == releaseBundleID && other.bundleID == debugBundleID { return true }
            guard other.bundleID == own.bundleID else { return false }
            switch (other.launched, own.launched) {
            case let (a?, b?) where a != b: return a > b
            default: return other.pid > own.pid
            }
        }
    }

    @MainActor
    public static func runningCopies() -> [Copy] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.map { Copy(pid: app.processIdentifier, bundleID: $0, launched: app.launchDate) }
        }
    }

    @MainActor
    public static var ownCopy: Copy {
        let me = NSRunningApplication.current
        return Copy(pid: me.processIdentifier, bundleID: bundleID ?? "", launched: me.launchDate)
    }

    /// Executable path, launch time and PID of every running copy, for About.
    @MainActor
    public static func describeRunning() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { [releaseBundleID, debugBundleID].contains($0.bundleIdentifier ?? "") }
            .map { app in
                let own = app.processIdentifier == ProcessInfo.processInfo.processIdentifier ? " (this one)" : ""
                let when = app.launchDate.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
                return "PID \(app.processIdentifier)\(own) · \(app.executableURL?.path ?? "?") · started \(when)"
            }
    }

    /// The commit this build was made from, when the build recorded it
    /// (`scripts/build-macos-app.sh` writes `PRGitCommit`); Xcode builds say so.
    public static var gitCommit: String? { Bundle.main.object(forInfoDictionaryKey: "PRGitCommit") as? String }

    public static func name(of bundleID: String) -> String {
        bundleID == debugBundleID ? "Prompt Relay (Debug)" : "Prompt Relay"
    }

    // MARK: Phase 11 — what this build is, and whether it is the one you think

    /// The facts a build records about itself (`Info.plist`, written by
    /// `scripts/build-macos-app.sh` and the Xcode "Embed Python Core" phase).
    public struct Stamp: Equatable, Sendable {
        public var version: String?
        public var commit: String?
        public var dirty: Bool
        public var builtAt: String?
        public var coreVersion: String?

        public init(version: String?, commit: String?, dirty: Bool = false, builtAt: String? = nil, coreVersion: String? = nil) {
            self.version = version; self.commit = commit; self.dirty = dirty; self.builtAt = builtAt; self.coreVersion = coreVersion
        }

        /// Read from an app bundle on disk (not the cached `Bundle.main`
        /// dictionary), so a build replaced while running can be noticed.
        public static func read(appAt url: URL) -> Stamp? {
            guard let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
            else { return nil }
            let core = url.appendingPathComponent("Contents/Resources/core/plugin/prompt_relay/__init__.py")
            return Stamp(version: plist["CFBundleShortVersionString"] as? String,
                         commit: plist["PRGitCommit"] as? String,
                         dirty: (plist["PRGitDirty"] as? String) == "yes",
                         builtAt: plist["PRBuildDate"] as? String,
                         coreVersion: coreVersion(in: core))
        }

        /// `__version__ = "x"` of a Core `__init__.py`.
        public static func coreVersion(in file: URL) -> String? {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            for line in text.split(separator: "\n") where line.hasPrefix("__version__") {
                let parts = line.split(separator: "\"")
                if parts.count >= 2 { return String(parts[1]) }
            }
            return nil
        }

        public var commitText: String {
            guard let commit else { return "not recorded" }
            return dirty ? "\(commit) + uncommitted changes" : commit
        }
    }

    /// The facts as loaded at launch.
    public static var launchStamp: Stamp {
        let info = Bundle.main.infoDictionary ?? [:]
        let core = Bundle.main.resourceURL?.appendingPathComponent("core/plugin/prompt_relay/__init__.py")
        return Stamp(version: info["CFBundleShortVersionString"] as? String,
                     commit: info["PRGitCommit"] as? String,
                     dirty: (info["PRGitDirty"] as? String) == "yes",
                     builtAt: info["PRBuildDate"] as? String,
                     coreVersion: core.flatMap(Stamp.coreVersion(in:)))
    }

    /// Where the Release app is installed by `scripts/install-local.sh` and
    /// by dragging from the DMG.
    public static var installedLocations: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Prompt Relay.app"),
         URL(fileURLWithPath: "/Applications/Prompt Relay.app")]
    }

    /// Mismatches worth telling the user about. Only facts read from the
    /// bundles themselves; nothing is guessed when a build did not record it.
    public static func diagnose(running: Stamp, runningPath: String, isDebug: Bool,
                                onDiskAtRunningPath: Stamp?, installed: [(path: String, stamp: Stamp)],
                                coreInUse: String?) -> [String] {
        var notes: [String] = []
        if let disk = onDiskAtRunningPath, disk != running,
           disk.commit != running.commit || disk.builtAt != running.builtAt || disk.version != running.version {
            notes.append("A different build (\(disk.version ?? "?") · \(disk.commitText)) was installed here after this one started. Quit and reopen Prompt Relay to use it.")
        }
        if let app = running.version, let core = running.coreVersion, app != core {
            notes.append("This build's bundled Core is \(core), the app is \(app). Rebuild with scripts/build-macos-app.sh.")
        }
        if let used = coreInUse, let app = running.version, used != app {
            notes.append("The Core answering this app reports \(used), not \(app) — a development override (PROMPT_RELAY_CLI or the CLI path setting) is in effect.")
        }
        let elsewhere = installed.filter { $0.path != runningPath }
        for copy in elsewhere {
            let name = (copy.path as NSString).abbreviatingWithTildeInPath
            if let a = copy.stamp.commit, let b = running.commit, a != b {
                notes.append("\(isDebug ? "This is the Xcode build" : "This copy") (\(running.commitText)); the app in \(name) is \(copy.stamp.commitText). Update it with scripts/install-local.sh.")
            } else if copy.stamp.commit == nil || running.commit == nil {
                if copy.stamp.version != running.version {
                    notes.append("The app in \(name) is version \(copy.stamp.version ?? "?"); this one is \(running.version ?? "?").")
                }
            }
        }
        return notes
    }

    @MainActor
    public static func currentDiagnostics(coreInUse: String?) -> [String] {
        let own = Bundle.main.bundleURL
        let installed = installedLocations.compactMap { url -> (path: String, stamp: Stamp)? in
            Stamp.read(appAt: url).map { (url.path, $0) }
        }
        return diagnose(running: launchStamp, runningPath: own.path, isDebug: isDebugBuild,
                        onDiskAtRunningPath: Stamp.read(appAt: own), installed: installed, coreInUse: coreInUse)
    }
}
