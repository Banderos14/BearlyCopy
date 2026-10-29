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

    private init?(keyCode: UInt32, modifiers: UInt32) {
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

    public static func standard() -> HotKeyRegistration? {
        HotKeyRegistration(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey | cmdKey))
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
