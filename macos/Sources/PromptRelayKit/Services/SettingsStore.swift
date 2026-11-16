import Foundation

/// The key-value storage behind `NotchSettings` and `AppModel`'s remembered
/// state (Phase 11).
///
/// The app uses `UserDefaults.standard`. Tests use `MemorySettingsStore`:
/// before Phase 11 every test made a real `UserDefaults(suiteName:)` suite,
/// and `cfprefsd` left one plist per suite in `~/Library/Preferences`
/// (≈11,000 files on the development Mac). An in-memory store never touches
/// the preferences system, so nothing is left behind.
public protocol SettingsStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    /// `nil` removes the key, as in `UserDefaults`.
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

public extension SettingsStore {
    func bool(forKey key: String) -> Bool {
        switch object(forKey: key) {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        case let value as String: return ["yes", "true", "1"].contains(value.lowercased())
        default: return false
        }
    }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
}

extension UserDefaults: SettingsStore {}

/// Process-memory storage with `UserDefaults` semantics for the methods
/// above. Thread-safe; a reference type, so two models given the same store
/// see each other's writes (how tests simulate a restart).
public final class MemorySettingsStore: SettingsStore, @unchecked Sendable {
    private var values: [String: Any]
    private let lock = NSLock()

    public init(_ values: [String: Any] = [:]) { self.values = values }

    public func object(forKey defaultName: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[defaultName]
    }

    public func set(_ value: Any?, forKey defaultName: String) {
        lock.lock(); defer { lock.unlock() }
        // `Optional<Optional<T>>.some(nil)` arrives as a non-nil `Any`;
        // unwrap it so `set(nil as String?, …)` removes like UserDefaults.
        if let value, !Self.isNil(value) { values[defaultName] = value } else { values[defaultName] = nil }
    }

    public func removeObject(forKey defaultName: String) {
        lock.lock(); defer { lock.unlock() }
        values[defaultName] = nil
    }

    /// All keys, for tests.
    public var keys: [String] {
        lock.lock(); defer { lock.unlock() }
        return values.keys.sorted()
    }

    private static func isNil(_ value: Any) -> Bool {
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional && mirror.children.isEmpty
    }
}
