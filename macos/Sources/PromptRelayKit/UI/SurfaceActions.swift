import Foundation

/// What the island cannot do itself (quit the app; the menu-bar shell opens
/// the island on a view). The app lifecycle supplies them.
public struct SurfaceActions {
    public var openWindow: () -> Void
    public var openStatus: () -> Void
    public var openSettings: () -> Void
    public var quit: () -> Void

    public init(openWindow: @escaping () -> Void = {}, openStatus: @escaping () -> Void = {},
                openSettings: @escaping () -> Void = {}, quit: @escaping () -> Void) {
        self.openWindow = openWindow
        self.openStatus = openStatus
        self.openSettings = openSettings
        self.quit = quit
    }
}
