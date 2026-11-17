import Foundation
import ServiceManagement

/// Phase 12: "Open at Login" through the system's own login items
/// (`SMAppService.mainApp`, macOS 13+). Off by default; only the user turns
/// it on, and turning it off unregisters the same item. macOS starts one
/// copy of the app at login; opening it again only brings that copy forward
/// (LaunchServices; BearlyCopy never starts a second instance itself).
///
/// Offered only for the installed Release copy (`~/Applications` or
/// `/Applications`): registering a Debug build from Xcode's DerivedData
/// would make a build folder start at every login.
public protocol LoginItemService: Sendable {
    func status() -> LoginItemStatus
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

public enum LoginItemStatus: Equatable, Sendable {
    case off
    case on
    /// Registered, but the user must allow it in System Settings → General → Login Items.
    case requiresApproval
    /// The system cannot find the app at this location.
    case notFound
}

public struct SystemLoginItem: LoginItemService {
    public init() {}

    public func status() -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        default: return .off
        }
    }

    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }
    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// What the Settings row shows and allows.
@MainActor
@Observable
public final class LoginItemController {
    public private(set) var status: LoginItemStatus = .off
    public private(set) var message: String?
    /// Why the switch is disabled here (Debug build, not installed), or nil.
    public let unavailableReason: String?
    private let service: LoginItemService

    public init(service: LoginItemService = SystemLoginItem(), bundleURL: URL = Bundle.main.bundleURL,
                isDebugBuild: Bool = AppBuild.isDebugBuild, installedLocations: [URL] = AppBuild.installedLocations) {
        self.service = service
        unavailableReason = Self.unavailableReason(bundleURL: bundleURL, isDebugBuild: isDebugBuild, installed: installedLocations)
        refresh()
    }

    nonisolated static func unavailableReason(bundleURL: URL, isDebugBuild: Bool, installed: [URL]) -> String? {
        if isDebugBuild { return "Available in the installed app, not in a Debug build from Xcode." }
        let path = bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        let known = installed.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        guard known.contains(path) else { return "Install BearlyCopy in Applications first (scripts/install-local.sh)." }
        return nil
    }

    public var isOn: Bool { status == .on || status == .requiresApproval }

    public func refresh() {
        status = unavailableReason == nil ? service.status() : .off
    }

    /// The user's switch. Errors are shown, never retried in a loop.
    public func set(_ on: Bool) {
        guard unavailableReason == nil else { return }
        do {
            if on { try service.register() } else { try service.unregister() }
            message = nil
        } catch {
            message = on ? "macOS did not add BearlyCopy to login items (\(error.localizedDescription))."
                         : "macOS did not remove the login item (\(error.localizedDescription))."
        }
        refresh()
        if status == .requiresApproval { message = "Allow BearlyCopy in System Settings → General → Login Items." }
    }

    public func openSystemSettings() { service.openSystemSettings() }
}
