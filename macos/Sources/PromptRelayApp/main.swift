import AppKit
import PromptRelayKit
import SwiftUI

// App lifecycle only: the island (notch, or floating on a display without
// one), the menu-bar item as its fallback way in, and the hotkey. All
// behavior lives in PromptRelayKit. There are no regular windows: projects,
// history, settings and the full response open inside the island.

@MainActor
final class AppServices {
    static let shared = AppServices()

    let model = AppModel.live()
    let settings = NotchSettings()
    let notifier = ReadyNotifier()
    private(set) var coordinator: NotchCoordinator?

    /// Started once, after launch, so the island exists before anything is clicked.
    func startNotch() {
        guard coordinator == nil else { return }
        let model = self.model, settings = self.settings, notifier = self.notifier
        coordinator = NotchCoordinator(model: model, settings: settings, notifier: notifier) {
            NotchController(model: model, settings: settings, actions: Actions.current, notifier: notifier)
        }
        #if DEBUG
        // Debug builds: PROMPT_RELAY_DEBUG_CAPTURE_DIR=<dir> renders the real
        // island to PNGs a few seconds after launch (see NotchController).
        if let dir = ProcessInfo.processInfo.environment["PROMPT_RELAY_DEBUG_CAPTURE_DIR"] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await self.coordinator?.controller?.debugCapture(to: URL(fileURLWithPath: dir))
            }
        }
        #endif
    }

    /// Opens the island on a view (menu-bar item, window actions).
    func present(_ route: AppModel.IslandRoute) {
        // After the menu has closed, so the island can take the keyboard.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.coordinator?.controller?.present(route) } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppServices.shared.startNotch() }
    }

    /// Phase 16: opening Prompt Relay again while it runs (double-click in
    /// Applications, Spotlight, Launchpad) opens the island, so the app you
    /// just opened is visibly there — it has no Dock icon or windows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppServices.shared.present(.home) }
        return false
    }
}

struct PromptRelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let services = AppServices.shared

    var body: some Scene {
        // The fallback way in: open the island, its settings, or quit.
        MenuBarExtra {
            Button("Open Prompt Relay  \(HotKeyRegistration.displayString)") { services.present(.home) }
            Button("Results Inbox") { services.present(.inbox) }
            Button("Go To…") { services.present(.switcher) }
            Button("Clipboard") { services.present(.copies) }
            Button("History") { services.present(.history) }
            Button("Import AI Result…") { services.present(.importReport) }
            Divider()
            Button("Settings…") { services.present(.settings) }
                .keyboardShortcut(",")
            Divider()
            Button("Quit Prompt Relay") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            // A Debug build has its own icon, so two running builds are told
            // apart; the installed app shows Relay's silhouette (Phase 16).
            if AppBuild.isDebugBuild {
                Image(systemName: "hammer.circle").accessibilityLabel("Prompt Relay (Debug)")
            } else {
                Image(nsImage: AppIcon.menuBarImage()).accessibilityLabel("Prompt Relay")
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

/// What the island asks the app shell to do. "Open the window" now means
/// the full response inside the island.
@MainActor
enum Actions {
    static var current: SurfaceActions {
        SurfaceActions(
            openWindow: { AppServices.shared.present(.reader) },
            openStatus: { AppServices.shared.present(.settings) },
            openSettings: { AppServices.shared.present(.settings) },
            quit: { NSApp.terminate(nil) }
        )
    }
}

PromptRelayApp.main()
