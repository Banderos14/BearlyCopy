import CoreGraphics
import Foundation
import Observation

/// Interface preferences, persisted in UserDefaults (tests: `MemorySettingsStore`).
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

    /// How lively Relay is (Phase 7.1).
    public enum RelayMotion: String, CaseIterable, Identifiable, Sendable {
        /// Calm, natural movement: small head turns, rare idle moments.
        case subtle
        /// Livelier: larger turns, more frequent idle moments.
        case expressive
        /// A still bear: no head movement, no idle moments, no reactions in motion.
        case off

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .subtle: return "Subtle"
            case .expressive: return "Expressive"
            case .off: return "Off"
            }
        }
        /// Scale of head turns (1 = the bounded maximum).
        public var amplitude: CGFloat { self == .expressive ? 1 : self == .subtle ? 0.65 : 0 }
    }

    enum Key {
        static let notchEnabled = "notch.enabled"
        static let notifyWhenReady = "notify.whenReady"
        static let animation = "notch.animation"
        static let display = "notch.displayID"
        static let yield = "notch.yieldToOtherNotchApps"
        static let mascot = "mascot.enabled"
        static let theme = "appearance.theme"
        static let relayMotion = "relay.motion"
        static let relayIdle = "relay.idle"
        static let relayFollows = "relay.followsPointer"
        static let relayWithoutNotch = "relay.withoutNotch"
        static let shortcutModifiers = "shortcuts.modifiers"
        static func shortcut(_ s: GlobalShortcut) -> String { "shortcuts.enabled." + s.rawValue }
    }

    private let defaults: any SettingsStore

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
    public var relayMotion: RelayMotion { didSet { defaults.set(relayMotion.rawValue, forKey: Key.relayMotion) } }
    /// Rare moments of its own at rest (a glance, a look around, a smile, sleepy after a long quiet time).
    public var relayIdle: Bool { didSet { defaults.set(relayIdle, forKey: Key.relayIdle) } }
    /// The eyes and head follow the pointer near the island.
    public var relayFollowsPointer: Bool { didSet { defaults.set(relayFollowsPointer, forKey: Key.relayFollows) } }
    /// On a display without a notch, Relay rests in a small pill under the
    /// menu bar (hover opens Quick Peek). Off: nothing rests there.
    public var relayWithoutNotch: Bool { didSet { defaults.set(relayWithoutNotch, forKey: Key.relayWithoutNotch) } }
    public var display: DisplayChoice {
        didSet {
            switch display {
            case .automatic: defaults.removeObject(forKey: Key.display)
            case .display(let id): defaults.set(Int(id), forKey: Key.display)
            }
        }
    }

    /// Phase 12: optional global shortcuts, all off by default.
    public private(set) var enabledShortcuts: Set<GlobalShortcut> = []
    public var shortcutModifiers: ShortcutModifiers = .controlOptionCommand {
        didSet {
            defaults.set(shortcutModifiers.rawValue, forKey: Key.shortcutModifiers)
            if oldValue != shortcutModifiers { onShortcutsChanged?() }
        }
    }
    /// Shortcuts macOS refused (another app has the keys); set by the controller.
    public var unavailableShortcuts: Set<GlobalShortcut> = []
    /// The controller re-registers when the user changes shortcuts.
    @ObservationIgnored public var onShortcutsChanged: (() -> Void)?

    public func setShortcut(_ shortcut: GlobalShortcut, enabled: Bool) {
        guard enabledShortcuts.contains(shortcut) != enabled else { return }
        if enabled { enabledShortcuts.insert(shortcut) } else { enabledShortcuts.remove(shortcut) }
        defaults.set(enabled, forKey: Key.shortcut(shortcut))
        onShortcutsChanged?()
    }

    public func display(_ shortcut: GlobalShortcut) -> String { shortcutModifiers.symbols + shortcut.key }

    public init(defaults: any SettingsStore = UserDefaults.standard) {
        self.defaults = defaults
        enabledShortcuts = Set(GlobalShortcut.allCases.filter { defaults.bool(forKey: Key.shortcut($0)) })
        shortcutModifiers = defaults.string(forKey: Key.shortcutModifiers).flatMap(ShortcutModifiers.init(rawValue:)) ?? .controlOptionCommand
        notchEnabled = defaults.object(forKey: Key.notchEnabled) as? Bool ?? true   // default: on
        notifyWhenReady = defaults.bool(forKey: Key.notifyWhenReady)    // default: off
        animation = defaults.string(forKey: Key.animation).flatMap(Animation.init(rawValue:)) ?? .system
        yieldToOtherNotchApps = defaults.object(forKey: Key.yield) as? Bool ?? true   // default: yield
        mascotEnabled = defaults.object(forKey: Key.mascot) as? Bool ?? true
        relayMotion = defaults.string(forKey: Key.relayMotion).flatMap(RelayMotion.init(rawValue:)) ?? .subtle
        relayIdle = defaults.object(forKey: Key.relayIdle) as? Bool ?? true
        relayFollowsPointer = defaults.object(forKey: Key.relayFollows) as? Bool ?? true
        relayWithoutNotch = defaults.object(forKey: Key.relayWithoutNotch) as? Bool ?? true
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
