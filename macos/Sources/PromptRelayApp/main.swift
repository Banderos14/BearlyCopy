import AppKit
import PromptRelayKit
import SwiftUI

// App lifecycle only: scenes, the menu-bar item, the notch coordinator and
// window routing. All behavior lives in PromptRelayKit.

@MainActor
final class AppServices {
    static let shared = AppServices()

    let model = AppModel.live()
    let settings = NotchSettings()
    let notifier = ReadyNotifier()
    private(set) var coordinator: NotchCoordinator?

    /// Started once, after launch, so the notch exists even before any
    /// window or the menu panel was opened.
    func startNotch() {
        guard coordinator == nil else { return }
        let model = self.model, settings = self.settings
        coordinator = NotchCoordinator(model: model, settings: settings, notifier: notifier) {
            NotchController(model: model, settings: settings, actions: Actions.current)
        }
        #if DEBUG
        // Debug builds: PROMPT_RELAY_DEBUG_CAPTURE_DIR=<dir> renders the real
        // notch panel to PNGs a few seconds after launch (see NotchController).
        if let dir = ProcessInfo.processInfo.environment["PROMPT_RELAY_DEBUG_CAPTURE_DIR"] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await self.coordinator?.controller?.debugCapture(to: URL(fileURLWithPath: dir))
            }
        }
        #endif
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppServices.shared.startNotch() }
    }
}

struct PromptRelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let services = AppServices.shared

    var body: some Scene {
        Window("Prompt Relay", id: "main") {
            MainWindowView(model: services.model, actions: Actions.current)
                .background(WindowActionsBridge())
        }
        .defaultSize(width: 1040, height: 680)

        Window("Prompt Relay Status", id: "status") {
            ConnectionStatusView(model: services.model)
                .onAppear { services.model.loadDoctor() }
        }
        .defaultSize(width: 520, height: 560)
        .windowResizability(.contentSize)

        Settings {
            PreferencesView(settings: services.settings, notifier: services.notifier)
                .background(WindowActionsBridge())
        }

        MenuBarExtra {
            MenuPanelView(model: services.model, actions: Actions.current)
                .background(WindowActionsBridge())
        } label: {
            Image(systemName: "doc.on.clipboard")
                .accessibilityLabel("Prompt Relay")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Window actions captured from the SwiftUI environment, so kit views (and
/// the notch panel, which is outside SwiftUI's scene graph) can open windows.
@MainActor
enum Actions {
    static var open: (String) -> Void = { _ in }
    static var settings: () -> Void = {}

    static var current: SurfaceActions {
        SurfaceActions(
            openWindow: { show("main") },
            openStatus: { show("status") },
            openSettings: { NSApp.activate(ignoringOtherApps: true); settings() },
            quit: { NSApp.terminate(nil) }
        )
    }

    static func show(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        open(id)
    }
}

private struct WindowActionsBridge: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.onAppear {
            let open = openWindow, settings = openSettings
            Actions.open = { open(id: $0) }
            Actions.settings = { settings() }
        }
    }
}

PromptRelayApp.main()
