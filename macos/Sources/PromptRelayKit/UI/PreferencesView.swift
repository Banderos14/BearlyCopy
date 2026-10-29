import AppKit
import SwiftUI

/// Settings: the notch, notifications, motion and display.
public struct PreferencesView: View {
    @Bindable var settings: NotchSettings
    let notifier: ReadyNotifier
    @State private var screens: [ScreenDescriptor] = []
    @State private var notificationsDenied = false
    @State private var neighbors: [String] = []

    public init(settings: NotchSettings, notifier: ReadyNotifier) {
        self.settings = settings
        self.notifier = notifier
    }

    public var body: some View {
        Form {
            Section {
                Toggle("Show Prompt Relay at the notch", isOn: $settings.notchEnabled)
                Text(notchHint).font(.caption).foregroundStyle(.secondary)
                Picker("Display", selection: displayBinding) {
                    Text("Automatic (built-in display)").tag(DisplayChoice.automatic)
                    ForEach(screens.filter(\.hasNotch), id: \.displayID) { screen in
                        Text(screen.name).tag(DisplayChoice.display(screen.displayID))
                    }
                }
                .disabled(!settings.notchEnabled)
                Toggle("Step aside when another notch app is running", isOn: $settings.yieldToOtherNotchApps)
                    .disabled(!settings.notchEnabled)
                Text(neighborHint).font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Notch")
            }

            Section("Motion") {
                Picker("Animation", selection: $settings.animation) {
                    ForEach(NotchSettings.Animation.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("Notifications") {
                Toggle("Notify when an answer is ready", isOn: $settings.notifyWhenReady)
                    .disabled(!notifier.isAvailable)
                    .onChange(of: settings.notifyWhenReady) { _, on in
                        guard on else { return }
                        Task {
                            let granted = await notifier.requestAuthorization()
                            notificationsDenied = !granted
                            if !granted { settings.notifyWhenReady = false }
                        }
                    }
                Text(notificationsDenied
                     ? "Notifications are off for Prompt Relay in System Settings → Notifications."
                     : "The banner names the project only; the answer text is never shown.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            screens = NSScreen.screens.map(ScreenDescriptor.init)
            neighbors = LiveNotchNeighbors().running
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            neighbors = LiveNotchNeighbors().running
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            neighbors = LiveNotchNeighbors().running
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens.map(ScreenDescriptor.init)
        }
    }

    private var displayBinding: Binding<DisplayChoice> {
        Binding(get: { settings.display }, set: { settings.display = $0 })
    }

    private var neighborHint: String {
        guard let name = neighbors.first else {
            return "No other notch app is running now. If one starts (for example Coucou), Prompt Relay leaves the notch to it; open Prompt Relay with \(HotKeyRegistration.displayString) or the menu-bar icon."
        }
        return settings.yieldToOtherNotchApps
            ? "\(name) is using the notch, so Prompt Relay stays out of it. Open Prompt Relay with \(HotKeyRegistration.displayString) or the menu-bar icon — or turn off \(name)'s island in its own settings and switch this off."
            : "\(name) is also using the notch. Both islands share the same spot; hover may reach either app. Turn off \(name)'s island in its own settings, or switch this back on."
    }

    private var notchHint: String {
        if !screens.contains(where: \.hasNotch) {
            return "No display with a notch is connected. The menu-bar icon stays available; the notch appears when the built-in display is in use."
        }
        return "Hover over the notch to open, or press \(HotKeyRegistration.displayString). The menu-bar icon always stays available."
    }
}

