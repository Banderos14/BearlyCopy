import Foundation

/// Phase 19.1: one clear control for the window screenshots.
///
/// - **Automatic** (recommended): the window of the app in front when you send a
///   prompt is linked by itself and photographed once when the answer is ready.
/// - **Manual**: screenshots are on, but you choose the window yourself in
///   macOS's picker (Link Window…).
/// - **Off**: no screenshots.
extension AppModel {
    public enum ScreenshotMode: String, CaseIterable, Identifiable, Sendable {
        case automatic, manual, off
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .manual: return "Manual"
            case .off: return "Off"
            }
        }
        public var detail: String {
            switch self {
            case .automatic: return "Recommended. When you send a prompt, the window of the app in front (Claude Desktop, a terminal, an editor) is linked to that conversation; one still image of it is kept when the answer is ready."
            case .manual: return "You choose the window yourself (Link Window…). Use this if automatic linking picks the wrong window or macOS keeps asking for permission."
            case .off: return "No screenshots are taken."
            }
        }
    }

    public var screenshotMode: ScreenshotMode {
        get {
            guard autoCaptureFinalWindow else { return .off }
            return autoLinkWindowEnabled ? .automatic : .manual
        }
        set {
            switch newValue {
            case .automatic: autoLinkWindowEnabled = true; autoCaptureFinalWindow = true
            case .manual: autoLinkWindowEnabled = false; autoCaptureFinalWindow = true
            case .off: autoCaptureFinalWindow = false
            }
        }
    }
}
