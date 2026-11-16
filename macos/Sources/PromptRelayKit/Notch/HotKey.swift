import AppKit
import Carbon.HIToolbox

/// One global shortcut through the Carbon hot-key API. It needs no
/// Accessibility permission and sees only its own key combination, never
/// other keystrokes.
@MainActor
public final class HotKeyRegistration {
    /// ⌃⌥⌘P: opens or closes the notch panel with keyboard focus.
    public static let displayString = "⌃⌥⌘P"

    public var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var active: [UInt32: HotKeyRegistration] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    /// Registers one combination. Nil when macOS refuses it — most often
    /// because another app already registered the same keys.
    public init?(keyCode: UInt32, modifiers: UInt32) {
        id = Self.nextID
        Self.nextID += 1
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let key = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyRegistration.active[key]?.onPress?() }
            }
            return noErr
        }, 1, &spec, nil, &handler)
        guard status == noErr else { return nil }
        let hotKeyID = EventHotKeyID(signature: OSType(0x5052_4C59), id: id)  // "PRLY"
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
        Self.active[id] = self
    }

    /// Tests: a handle that registers nothing with macOS.
    init(inert: Void) {
        id = Self.nextID
        Self.nextID += 1
    }

    public static func standard() -> HotKeyRegistration? {
        HotKeyRegistration(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey | cmdKey))
    }

    /// Phase 12: an optional global shortcut with the chosen modifiers.
    public static func make(_ shortcut: GlobalShortcut, modifiers: ShortcutModifiers) -> HotKeyRegistration? {
        HotKeyRegistration(keyCode: shortcut.keyCode, modifiers: modifiers.carbon)
    }

    public func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
        Self.active[id] = nil
        onPress = nil
    }
}

/// Phase 12: optional global shortcuts besides ⌃⌥⌘P. Each is off until the
/// user turns it on (Settings → General → Shortcuts), so nothing new takes
/// keys from other apps by default. Carbon hot keys: no Accessibility
/// permission, and only the registered combination is seen.
public enum GlobalShortcut: String, CaseIterable, Identifiable, Sendable {
    case openInbox, quickSwitcher, nextUnread
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .openInbox: return "Open Results Inbox"
        case .quickSwitcher: return "Go To (Quick Switcher)"
        case .nextUnread: return "Next Unread Result"
        }
    }
    public var key: String {
        switch self {
        case .openInbox: return "I"
        case .quickSwitcher: return "K"
        case .nextUnread: return "N"
        }
    }
    var keyCode: UInt32 {
        switch self {
        case .openInbox: return UInt32(kVK_ANSI_I)
        case .quickSwitcher: return UInt32(kVK_ANSI_K)
        case .nextUnread: return UInt32(kVK_ANSI_N)
        }
    }
}

public enum ShortcutModifiers: String, CaseIterable, Identifiable, Sendable {
    case controlOptionCommand, controlShiftCommand, optionShiftCommand
    public var id: String { rawValue }
    public var symbols: String {
        switch self {
        case .controlOptionCommand: return "⌃⌥⌘"
        case .controlShiftCommand: return "⌃⇧⌘"
        case .optionShiftCommand: return "⌥⇧⌘"
        }
    }
    var carbon: UInt32 {
        switch self {
        case .controlOptionCommand: return UInt32(controlKey | optionKey | cmdKey)
        case .controlShiftCommand: return UInt32(controlKey | shiftKey | cmdKey)
        case .optionShiftCommand: return UInt32(optionKey | shiftKey | cmdKey)
        }
    }
}
