import Foundation
import Observation

/// Interface preferences, persisted in UserDefaults.
@MainActor
@Observable
public final class NotchSettings {
    public enum Animation: String, CaseIterable, Identifiable, Sendable {
        /// Follow the system "Reduce motion" setting.
        case system
        case full
        case reduced

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .system: return "Follow System"
            case .full: return "Smooth"
            case .reduced: return "Reduced"
            }
        }
    }

    enum Key {
        static let notchEnabled = "notch.enabled"
        static let notifyWhenReady = "notify.whenReady"
        static let animation = "notch.animation"
        static let display = "notch.displayID"
        static let yield = "notch.yieldToOtherNotchApps"
        static let mascot = "mascot.enabled"
        static let theme = "appearance.theme"
    }

    private let defaults: UserDefaults

    /// The resting island at the notch opens on hover. Off: Prompt Relay
    /// opens only from the menu-bar item or the hotkey. On by default since
    /// Phase 3D: the island is the app's interface.
    public var notchEnabled: Bool { didSet { defaults.set(notchEnabled, forKey: Key.notchEnabled) } }
    public var notifyWhenReady: Bool { didSet { defaults.set(notifyWhenReady, forKey: Key.notifyWhenReady) } }
    public var animation: Animation { didSet { defaults.set(animation.rawValue, forKey: Key.animation) } }
    /// When another notch app (Coucou) is running, do not compete for the
    /// notch: no hover target there; ⌃⌥⌘P and the menu-bar item still open it.
    public var yieldToOtherNotchApps: Bool { didSet { defaults.set(yieldToOtherNotchApps, forKey: Key.yield) } }
    /// Relay the bear beside the notch (on by default; Settings → Appearance).
    public var mascotEnabled: Bool { didSet { defaults.set(mascotEnabled, forKey: Key.mascot) } }
    /// The island's colors (Settings → Appearance). Warm Cocoa by default;
    /// Soft Spectrum, Material Calm and Classic stay available.
    public var theme: IslandTheme {
        didSet { defaults.set(theme.rawValue, forKey: Key.theme); Island.palette = theme.palette }
    }
    public var display: DisplayChoice {
        didSet {
            switch display {
            case .automatic: defaults.removeObject(forKey: Key.display)
            case .display(let id): defaults.set(Int(id), forKey: Key.display)
            }
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notchEnabled = defaults.object(forKey: Key.notchEnabled) as? Bool ?? true   // default: on
        notifyWhenReady = defaults.bool(forKey: Key.notifyWhenReady)    // default: off
        animation = defaults.string(forKey: Key.animation).flatMap(Animation.init(rawValue:)) ?? .system
        yieldToOtherNotchApps = defaults.object(forKey: Key.yield) as? Bool ?? true   // default: yield
        mascotEnabled = defaults.object(forKey: Key.mascot) as? Bool ?? true
        // An explicit choice is kept; without one (new installs, and anyone who
        // never picked a theme) Warm Cocoa.
        let theme = defaults.string(forKey: Key.theme).flatMap(IslandTheme.init(rawValue:)) ?? .warmCocoa
        self.theme = theme
        if let id = defaults.object(forKey: Key.display) as? Int, id > 0 {
            display = .display(UInt32(id))
        } else {
            display = .automatic
        }
        Island.palette = theme.palette
    }

    /// Whether motion should be reduced, given the system setting.
    public func reducesMotion(systemReduceMotion: Bool) -> Bool {
        switch animation {
        case .system: return systemReduceMotion
        case .full: return false
        case .reduced: return true
        }
    }
}
