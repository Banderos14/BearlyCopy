import AppKit
import CoreGraphics

/// Phase 14.1: one-click recovery from "Auto screenshot needs permission".
///
/// Never toggles the permission and never simulates the system switch —
/// only reads the current authorization and opens the pane where the user
/// grants it themselves. `CGPreflightScreenCaptureAccess` is the documented
/// non-prompting check (unlike `SCShareableContent`, it never enumerates
/// windows). Opening System Settings is never treated as granting access:
/// callers must still see a real capture succeed (see `AppModel.checkAutoCaptureAccess`).
@MainActor
public protocol ScreenRecordingPermissionChecking: AnyObject {
    /// True once macOS has recorded this process's own authorization. A
    /// process already running when access was granted can still read
    /// `true` here while a real capture keeps failing — see `restartRequired`.
    func isGranted() -> Bool
    /// Opens System Settings at the Screen Recording pane, trying the
    /// current pane identifier first, then older ones, then System Settings
    /// itself; returns whether anything could be opened at all.
    @discardableResult
    func openSettings() -> Bool
}

public final class LiveScreenRecordingPermission: ScreenRecordingPermissionChecking {
    /// In order: the ExtensionKit pane this Mac's System Settings actually
    /// ships (verified `com.apple.settings.PrivacySecurity.extension`,
    /// macOS 13+), the pre-Ventura System Preferences pane, then System
    /// Settings/Preferences itself with no anchor (always opens something).
    static let settingsURLs = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        "x-apple.systempreferences:",
    ]

    /// Injectable: tests replace this instead of actually opening a URL.
    var urlOpener: (URL) -> Bool

    public init() {
        urlOpener = { NSWorkspace.shared.open($0) }
    }

    init(urlOpener: @escaping (URL) -> Bool) {
        self.urlOpener = urlOpener
    }

    public func isGranted() -> Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    public func openSettings() -> Bool {
        for string in Self.settingsURLs {
            guard let url = URL(string: string) else { continue }
            if urlOpener(url) { return true }
        }
        return false
    }
}
