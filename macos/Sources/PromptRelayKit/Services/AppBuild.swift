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
}
