import AppKit
import PromptRelayKit
import SwiftUI

// App lifecycle only: scenes, the menu-bar item and window routing. All
// behavior lives in PromptRelayKit.

struct PromptRelayApp: App {
    @State private var model = AppModel.live()

    var body: some Scene {
        Window("Prompt Relay", id: "main") {
            MainWindowView(model: model, actions: Actions.current)
                .background(WindowActionsBridge())
        }
        .defaultSize(width: 1040, height: 680)

        Window("Prompt Relay Status", id: "status") {
            ConnectionStatusView(model: model)
                .onAppear { model.loadDoctor() }
        }
        .defaultSize(width: 520, height: 560)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuPanelView(model: model, actions: Actions.current)
                .background(WindowActionsBridge())
        } label: {
            Image(systemName: "doc.on.clipboard")
                .accessibilityLabel("Prompt Relay")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Window actions captured from the SwiftUI environment, so kit views can
/// ask for a window without depending on the App type.
@MainActor
enum Actions {
    static var open: (String) -> Void = { _ in }

    static var current: SurfaceActions {
        SurfaceActions(
            openWindow: { show("main") },
            openStatus: { show("status") },
            quit: { NSApp.terminate(nil) }
        )
    }

    static func show(_ id: String) {
        open(id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct WindowActionsBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear {
            let open = openWindow
            Actions.open = { open(id: $0) }
        }
    }
}

PromptRelayApp.main()
