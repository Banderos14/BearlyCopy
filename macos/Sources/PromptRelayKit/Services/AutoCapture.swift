import AppKit
import Foundation

// Phase 14: Automatic final screenshots. Pure decisions here (no
// ScreenCaptureKit, no timers), so every rule is unit-tested:
// which window belongs to a finished answer, when that is ambiguous, and
// whether two captures of a window show the same picture.

/// A window the user picked in macOS's own content picker. Prompt Relay never
/// enumerates windows: it only knows what the picker returned, for this app
/// run (window identity does not survive a restart of either app).
public struct PickedWindow: Equatable, Hashable, Sendable {
    /// Prompt Relay's handle for the picker's filter (memory only).
    public let handle: String
    /// "Claude — Window" when macOS says (15.2+), else "the window you picked".
    public let label: String
    /// The system window number, when macOS gives it (15.2+): two links to
    /// one window are recognised as the same window.
    public let windowID: UInt32?

    public init(handle: String, label: String, windowID: UInt32? = nil) {
        self.handle = handle; self.label = label; self.windowID = windowID
    }

    /// What identifies the window on screen: its number, else the handle.
    var token: String { windowID.map { "w\($0)" } ?? "h" + handle }
}

/// The agent a window was linked for. All four must match a finished answer;
/// the project name alone, or the app's bundle id, are never enough.
public struct CaptureSourceKey: Hashable, Sendable {
    public let provider: AgentProvider
    /// The Core's local profile id (config folder), or `unassigned`.
    public let profileID: String
    public let host: AgentHost
    public let projectPath: String

    public init(provider: AgentProvider, profileID: String, host: AgentHost, projectPath: String) {
        self.provider = provider; self.profileID = profileID; self.host = host; self.projectPath = projectPath
    }
}

/// One link: this window shows this agent's conversations (of this project),
/// or only one conversation (`sessionKey`).
public struct WindowBinding: Identifiable, Equatable, Sendable {
    public let id: String
    public let key: CaptureSourceKey
    /// nil: any conversation of `key` while it is the only active one there.
    public let sessionKey: String?
    public let window: PickedWindow
    /// Answers that finished before the link are never captured.
    public let createdAt: Date

    public init(id: String = UUID().uuidString, key: CaptureSourceKey, sessionKey: String?, window: PickedWindow, createdAt: Date) {
        self.id = id; self.key = key; self.sessionKey = sessionKey; self.window = window; self.createdAt = createdAt
    }
}

/// What happened to the automatic screenshot of one answer. Shown only when
/// it needs the user (never "Captured": the attachment itself says that).
public enum AutoCaptureStatus: Equatable, Sendable {
    case pending
    case captured
    /// macOS refused the capture (Screen Recording / screen sharing consent).
    case permissionRequired
    /// Phase 14.1: the system API now reports access, but a real capture of
    /// the linked window still fails the same way — this process was already
    /// running when access was granted and must restart to use it.
    case restartRequired
    /// No window is linked to this agent, host and project.
    case windowNotBound
    /// The linked window is closed, hidden or no longer capturable.
    case windowUnavailable
    case failed
    /// Two active conversations could be in the linked window: nothing taken.
    case associationRequired
    /// A newer final answer of the same window arrived before this one settled.
    case superseded

    /// Short status word, for a compact card (never a paragraph).
    public var title: String? {
        switch self {
        case .pending: return nil
        case .captured: return nil
        case .permissionRequired: return "Permission required"
        case .restartRequired: return "Restart required"
        case .windowNotBound: return "Window not linked"
        case .windowUnavailable: return "Window unavailable"
        case .failed: return "Capture failed"
        case .associationRequired: return "Window association required"
        case .superseded: return "Superseded by a newer answer"
        }
    }

    /// One short sentence under the title; never the long how-to paragraph
    /// this used to be — the recovery buttons say what to do.
    public var detail: String? {
        switch self {
        case .pending: return "Taking the auto screenshot…"
        case .captured: return nil
        case .permissionRequired: return "Allow Prompt Relay to capture your linked window."
        case .restartRequired: return "Permission was granted. Quit and reopen Prompt Relay to use it — your results and settings stay."
        case .windowNotBound: return "No window is linked to this agent, so no auto screenshot was taken."
        case .windowUnavailable: return "The linked window is closed or not available. Link it again to resume auto screenshots."
        case .failed: return "The auto screenshot failed. The answer text is complete; you can capture the window yourself."
        case .associationRequired: return "Another conversation may be showing in the linked window, so no screenshot was taken."
        case .superseded: return "A newer answer arrived in the same window first."
        }
    }

    /// `title` + `detail` as one line, for places that show only one string.
    public var message: String? {
        switch (title, detail) {
        case let (t?, d?): return "\(t): \(d)"
        case let (nil, d?): return d
        case let (t?, nil): return t
        case (nil, nil): return nil
        }
    }

    /// The user can do something about it here: link a window, or capture now.
    public var offersLink: Bool {
        switch self {
        case .windowNotBound, .associationRequired, .windowUnavailable: return true
        default: return false
        }
    }

    /// Phase 14.1: Open Screen Recording Settings + Check Again.
    public var offersPermissionRecovery: Bool { self == .permissionRequired }
    /// Phase 14.1: Quit Prompt Relay (to reopen it) + Check Again.
    public var offersRestartRecovery: Bool { self == .restartRequired }
    /// Check Again is useful whenever the status could have changed outside
    /// Prompt Relay (a permission toggle, a relaunch, the window reopening).
    public var offersRecheck: Bool {
        switch self {
        case .permissionRequired, .restartRequired, .windowUnavailable: return true
        default: return false
        }
    }
}

public enum AutoCapturePlanner {
    /// An active conversation: its last event this recent, or a request running.
    public static let activeWindow: TimeInterval = 30 * 60

    public struct Candidate: Equatable, Sendable {
        public let sessionKey: String
        public let key: CaptureSourceKey?
        public let lastEventAt: Date?
        public let running: Bool

        public init(sessionKey: String, key: CaptureSourceKey?, lastEventAt: Date?, running: Bool) {
            self.sessionKey = sessionKey; self.key = key; self.lastEventAt = lastEventAt; self.running = running
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Take one still image of this binding's window.
        case capture(WindowBinding)
        /// No screenshot; the status says why (nil: nothing to say).
        case skip(AutoCaptureStatus?)
    }

    /// The window linked to a conversation: its own link first, else the
    /// one link of its agent · profile · host · project (two such links:
    /// none, it is ambiguous).
    static func binding(for sessionKey: String, key: CaptureSourceKey, in bindings: [WindowBinding]) -> (WindowBinding?, ambiguous: Bool) {
        if let own = bindings.last(where: { $0.sessionKey == sessionKey && $0.key == key }) { return (own, false) }
        let shared = bindings.filter { $0.sessionKey == nil && $0.key == key }
        if shared.count > 1, Set(shared.map(\.window.token)).count > 1 { return (nil, true) }
        return (shared.last, false)
    }

    /// The decision for one final answer that finished at `finishedAt`.
    public static func decide(sessionKey: String, key: CaptureSourceKey?, finishedAt: Date, isFinal: Bool,
                              needsInput: Bool, bindings: [WindowBinding], others: [Candidate], now: Date) -> Decision {
        // Only a real final answer: never an intermediate Stop, a wait for
        // background work, an API error, a question or a plan approval.
        guard isFinal, !needsInput else { return .skip(nil) }
        guard let key, key.host != .unknown else { return .skip(bindings.isEmpty ? nil : .windowNotBound) }
        let (found, ambiguous) = binding(for: sessionKey, key: key, in: bindings)
        if ambiguous { return .skip(.associationRequired) }
        guard let binding = found else { return .skip(.windowNotBound) }
        guard finishedAt >= binding.createdAt else { return .skip(nil) }   // before the link: never
        // Another active conversation whose link resolves to the same window
        // could be the one on screen: Prompt Relay cannot tell, so it takes
        // nothing rather than a picture of the wrong agent.
        for other in others where other.sessionKey != sessionKey {
            guard let otherKey = other.key else { continue }
            let active = other.running || (other.lastEventAt.map { now.timeIntervalSince($0) < activeWindow } ?? false)
            guard active else { continue }
            let (theirs, theirsAmbiguous) = Self.binding(for: other.sessionKey, key: otherKey, in: bindings)
            if theirsAmbiguous, bindings.contains(where: { $0.key == otherKey && $0.window.token == binding.window.token }) {
                return .skip(.associationRequired)
            }
            if let theirs, theirs.window.token == binding.window.token {
                // The other conversation resolves to the same window.
                return .skip(.associationRequired)
            }
        }
        return .capture(binding)
    }
}

/// Whether two captures of one window show the same picture, compared on a
/// small grayscale thumbnail. A blinking caret changes a few pixels; text
/// still being drawn changes many. Display only: never OCR, never stored.
public enum CaptureStability {
    public static let thumbnailWidth = 160
    /// Pixels whose gray value differs by more than this count as changed.
    static let pixelThreshold: UInt8 = 24
    /// More than this share of changed pixels: the window was still changing.
    static let changedShare = 0.004

    public static func fingerprint(png: Data) -> [UInt8]? {
        guard let rep = NSBitmapImageRep(data: png), let cg = rep.cgImage else { return nil }
        return fingerprint(cg)
    }

    public static func fingerprint(_ image: CGImage) -> [UInt8]? {
        let w = thumbnailWidth
        let h = max(1, Int((CGFloat(image.height) / CGFloat(max(1, image.width)) * CGFloat(w)).rounded()))
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? pixels : nil
    }

    public static func same(_ a: [UInt8]?, _ b: [UInt8]?) -> Bool {
        guard let a, let b, a.count == b.count, !a.isEmpty else { return false }
        var changed = 0
        for i in a.indices where (a[i] > b[i] ? a[i] - b[i] : b[i] - a[i]) > pixelThreshold { changed += 1 }
        return Double(changed) / Double(a.count) <= changedShare
    }
}

/// How long to let the window settle after a final answer. Observed: the
/// Stop hook runs when the model has finished, and the Core stores it before
/// the app sees it (FSEvents, ~0.1–0.5 s); Claude Desktop may still be
/// drawing the last lines then. So: wait `first`, capture, wait `recheck`,
/// capture again; equal pictures end it, else one more try. Never a stream,
/// never more than `maxShots` stills, and cancelled by a newer answer.
public struct CaptureSettle: Equatable, Sendable {
    public var first: TimeInterval
    public var recheck: TimeInterval
    public var maxShots: Int

    public init(first: TimeInterval, recheck: TimeInterval, maxShots: Int) {
        self.first = first; self.recheck = recheck; self.maxShots = maxShots
    }

    public static let standard = CaptureSettle(first: 0.6, recheck: 0.8, maxShots: 3)
    public static let immediate = CaptureSettle(first: 0, recheck: 0, maxShots: 1)
}
