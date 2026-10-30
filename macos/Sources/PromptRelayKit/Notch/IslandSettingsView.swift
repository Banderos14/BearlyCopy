import AppKit
import SwiftUI

/// Settings, the only way to them being the gear on Home (and the menu-bar
/// fallback). Grouped cards, each preference with one line saying what it
/// does. Technical details (Core, Python, plugin) live only in Diagnostics.
/// Nothing here writes Claude Code's settings.
struct IslandSettingsView: View {
    let model: AppModel
    let presentation: NotchPresentation
    let settings: NotchSettings?
    let notifier: ReadyNotifier?
    let actions: SurfaceActions
    @State private var screens: [ScreenDescriptor] = []
    @State private var note: String?

    static let repository = URL(string: "https://github.com/Banderos14/prompt-relay")!

    var body: some View {
        BoundedScroll(maxHeight: presentation.listHeight(chrome: 16)) {
            VStack(alignment: .leading, spacing: 8) {
                if let settings {
                    notch(settings)
                    appearance(settings)
                    notifications(settings)
                }
                section("Capture") {
                    rowButton("Projects", detail: "Choose which folders Prompt Relay captures.", value: captureSummary) {
                        model.navigate(to: .projects)
                    }
                }
                privacy
                diagnostics
                about
                if let note {
                    Text(note).font(.system(size: 11)).foregroundStyle(Island.tertiary)
                }
            }
            .padding(.horizontal, IslandMetrics.of(presentation).leading)
        }
        .islandPadding(presentation, horizontal: false)
        .onAppear {
            screens = NSScreen.screens.map(ScreenDescriptor.init)
            if model.doctor.value == nil, !model.doctor.isLoading { model.loadDoctor() }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func notch(_ settings: NotchSettings) -> some View {
        @Bindable var settings = settings
        section("Notch") {
            toggle("Open on hover", detail: "Show the answer when the pointer rests on the notch. Off: open from the menu bar or \(HotKeyRegistration.displayString).",
                   isOn: $settings.notchEnabled)
            Hairline()
            picker("Display", detail: "Where Prompt Relay appears. Without a notch it floats below the menu bar.",
                   current: displayTitle(settings.display),
                   options: [("Automatic", DisplayChoice.automatic)]
                    + screens.filter(\.hasNotch).map { ($0.name, DisplayChoice.display($0.displayID)) }) { settings.display = $0 }
            Hairline()
            toggle("Make room for other notch apps", detail: "When another app (for example Coucou) uses the notch, open Prompt Relay from the menu bar instead.",
                   isOn: $settings.yieldToOtherNotchApps)
        }
    }

    @ViewBuilder
    private func appearance(_ settings: NotchSettings) -> some View {
        @Bindable var settings = settings
        section("Appearance") {
            toggle("Show Relay the bear", detail: "A small companion beside the notch. It reacts to new answers and copies.",
                   isOn: $settings.mascotEnabled)
            Hairline()
            picker("Motion", detail: "Reduced uses short fades instead of springs.", current: settings.animation.title,
                   options: NotchSettings.Animation.allCases.map { ($0.title, $0) }) { settings.animation = $0 }
        }
    }

    @ViewBuilder
    private func notifications(_ settings: NotchSettings) -> some View {
        @Bindable var settings = settings
        section("Notifications") {
            toggle("Notify when an answer is ready", detail: "The banner names the project only, never the answer.",
                   isOn: $settings.notifyWhenReady)
                .disabled(!(notifier?.isAvailable ?? false))
                .onChange(of: settings.notifyWhenReady) { _, on in
                    guard on, let notifier else { return }
                    Task {
                        if !(await notifier.requestAuthorization()) {
                            settings.notifyWhenReady = false
                            note = "Notifications are off for Prompt Relay in System Settings → Notifications."
                        }
                    }
                }
        }
    }

    private var privacy: some View {
        section("Privacy") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Everything stays on this Mac").font(.system(size: 12.5)).foregroundStyle(Island.primary)
                Text("No network, no account, no AI service. Answers, imports and images are stored in your Library folder for Prompt Relay only; nothing is sent anywhere unless you paste it.")
                    .font(.system(size: 11)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Hairline()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent Copies").font(.system(size: 12.5)).foregroundStyle(Island.primary)
                    Text("References to your last \(AppModel.copyHistoryLimit) copies; no text is stored.").font(.system(size: 11)).foregroundStyle(Island.tertiary)
                }
                Spacer()
                Button("Clear") { model.clearCopyHistory() }
                    .buttonStyle(IslandPillStyle(prominent: false))
                    .disabled(model.copyHistory.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var diagnostics: some View {
        section("Diagnostics") {
            coreRow
            Hairline()
            pluginRow
            Hairline()
            if let answer = model.readyAnswer {
                // "Stopped" is a fact about Claude Code, not a claim that work or tests succeeded.
                status("Last capture", value: "\(answer.projectName) · \(Wording.relative(answer.at))", ok: true)
            } else {
                status("Last capture", value: model.projects.value == nil ? "—" : "None yet", ok: false)
            }
            Hairline()
            HStack {
                Text("Checks run only when you open this page or click Check Again.").font(.system(size: 11)).foregroundStyle(Island.tertiary)
                Spacer()
                Button("Check Again") { model.refresh(); model.loadDoctor() }.buttonStyle(IslandPillStyle(prominent: false))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var coreRow: some View {
        if let error = model.projects.error ?? model.doctor.error, model.projects.value == nil {
            switch error {
            case .pythonMissing:
                status("Python 3.9 or newer", value: "Not found", ok: false) {
                    copyButton("Copy Install Command", text: "xcode-select --install")
                }
            case .cliMissing:
                status("Prompt Relay Core", value: "Missing from the app", ok: false)
            default:
                status("Prompt Relay Core", value: error.title, ok: false)
            }
        } else if let core = model.doctor.value?.core {
            status("Prompt Relay Core", value: "\(core.promptRelayVersion) · Python \(core.python.version)", ok: core.python.supported)
        } else {
            status("Prompt Relay Core", value: "Checking…", ok: true)
        }
    }

    @ViewBuilder
    private var pluginRow: some View {
        if let doctor = model.doctor.value {
            if let record = doctor.configuration.plugin.records.first(where: { $0.id.hasPrefix("prompt-relay@") }) {
                let events = doctor.observed.byVia["plugin"]
                status("Claude Code plugin", value: "Installed \(record.version ?? "")" + (events.map { " · \($0.events) events" } ?? ""),
                       ok: record.manifestFound && record.launcherFound)
            } else {
                status("Claude Code plugin", value: "Not detected", ok: false) {
                    copyButton("Copy Commands", text: """
                    claude plugin marketplace add <path to your prompt-relay checkout>
                    claude plugin install prompt-relay@prompt-relay
                    """)
                }
            }
        } else {
            status("Claude Code plugin", value: model.doctor.isLoading ? "Checking…" : "Unknown", ok: model.doctor.isLoading)
        }
    }

    private var about: some View {
        section("About") {
            HStack {
                Text("Version").font(.system(size: 12.5)).foregroundStyle(Island.primary)
                Spacer()
                Text(version).font(.system(size: 12)).foregroundStyle(Island.tertiary).textSelection(.enabled)
            }
            .padding(.horizontal, 12).frame(height: 32)
            Hairline()
            Link(destination: Self.repository) {
                HStack {
                    Text("Source code").foregroundStyle(Island.primary)
                    Spacer()
                    Text("GitHub").foregroundStyle(Island.tertiary)
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Island.tertiary)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 12).frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            builds
        }
    }

    /// Debug and Release are separate apps to macOS (separate settings); say
    /// so when both run, and quit the other one only when asked.
    @ViewBuilder
    private var builds: some View {
        let others = AppBuild.otherBuildsRunning()
        if !others.isEmpty {
            Hairline()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(Island.warning).frame(width: 6, height: 6)
                    Text("Also running: " + others.map(AppBuild.name(of:)).joined(separator: ", "))
                        .font(.system(size: 12.5)).foregroundStyle(Island.primary)
                }
                Text("Each copy keeps its own settings and project list. Use one at a time.")
                    .font(.system(size: 11)).foregroundStyle(Island.tertiary)
                ForEach(others, id: \.self) { id in
                    Button("Quit \(AppBuild.name(of: id))") { AppBuild.quit(id) }
                        .buttonStyle(IslandPillStyle(prominent: false))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Caption(title).padding(.leading, 4).padding(.top, 6)
            GroupCard { content() }
        }
    }

    private func toggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5)).foregroundStyle(Island.primary)
                Text(detail).font(.system(size: 11)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(IslandSwitchStyle())
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private func rowButton(_ title: String, detail: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5)).foregroundStyle(Island.primary)
                    Text(detail).font(.system(size: 11)).foregroundStyle(Island.tertiary)
                }
                Spacer()
                Text(value).font(.system(size: 12)).foregroundStyle(Island.tertiary)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Island.tertiary)
            }
            .padding(.horizontal, 2)
        }
        .buttonStyle(IslandRowStyle())
        .padding(.horizontal, 2)
    }

    private func status<Action: View>(_ title: String, value: String, ok: Bool,
                                      @ViewBuilder action: () -> Action = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            Circle().fill(ok ? Island.accent : Island.warning).frame(width: 6, height: 6)
            Text(title).font(.system(size: 12.5)).foregroundStyle(Island.primary)
            Spacer(minLength: 6)
            Text(value).font(.system(size: 12)).foregroundStyle(Island.tertiary).lineLimit(1).truncationMode(.middle)
            action()
        }
        .padding(.horizontal, 12).frame(minHeight: 32)
        .accessibilityElement(children: .combine)
    }

    private func picker<Value>(_ title: String, detail: String, current: String, options: [(String, Value)],
                               select: @escaping (Value) -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5)).foregroundStyle(Island.primary)
                Text(detail).font(.system(size: 11)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Menu {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Button(option.0) { select(option.1) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(current).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 12))
                .foregroundStyle(Island.primary)
                .padding(.horizontal, 9).frame(height: 24)
                .background(Capsule().fill(Island.control))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(title): \(current)")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private var captureSummary: String {
        let on = model.projectRows.filter(\.captureEnabled).count
        return "\(on) of \(model.projectRows.count) on"
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        return AppBuild.isDebugBuild ? "\(v) (development build)" : v
    }

    private func displayTitle(_ choice: DisplayChoice) -> String {
        switch choice {
        case .automatic: return "Automatic"
        case .display(let id): return screens.first { $0.displayID == id }?.name ?? "Disconnected display"
        }
    }

    private func copyButton(_ title: String, text: String) -> some View {
        Button(title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            note = "Copied. Paste it into Terminal."
        }
        .buttonStyle(IslandPillStyle(prominent: false))
    }
}
