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

    public static func name(of bundleID: String) -> String {
        bundleID == debugBundleID ? "Prompt Relay (Debug)" : "Prompt Relay"
    }
}
