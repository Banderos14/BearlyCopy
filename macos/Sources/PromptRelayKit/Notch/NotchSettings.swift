import Foundation
import Observation

/// Interface preferences, persisted in UserDefaults. The notch is off until
/// the user turns it on.
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
            case .system: return "Follow system (Reduce Motion)"
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
    }

    private let defaults: UserDefaults

    public var notchEnabled: Bool { didSet { defaults.set(notchEnabled, forKey: Key.notchEnabled) } }
    public var notifyWhenReady: Bool { didSet { defaults.set(notifyWhenReady, forKey: Key.notifyWhenReady) } }
    public var animation: Animation { didSet { defaults.set(animation.rawValue, forKey: Key.animation) } }
    /// When another notch app (Coucou) is running, do not compete for the
    /// notch: no hover target there; ⌃⌥⌘P and the menu-bar item still open it.
    public var yieldToOtherNotchApps: Bool { didSet { defaults.set(yieldToOtherNotchApps, forKey: Key.yield) } }
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
        notchEnabled = defaults.bool(forKey: Key.notchEnabled)          // default: off
        notifyWhenReady = defaults.bool(forKey: Key.notifyWhenReady)    // default: off
        animation = defaults.string(forKey: Key.animation).flatMap(Animation.init(rawValue:)) ?? .system
        yieldToOtherNotchApps = defaults.object(forKey: Key.yield) as? Bool ?? true   // default: yield
        if let id = defaults.object(forKey: Key.display) as? Int, id > 0 {
            display = .display(UInt32(id))
        } else {
            display = .automatic
        }
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
