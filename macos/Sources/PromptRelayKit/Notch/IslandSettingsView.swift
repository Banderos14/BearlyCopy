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
                // Capture → Clipboard → Appearance → Notifications → Privacy → Advanced → About.
                section("Capture") {
                    rowButton("Projects", detail: "Which folders Prompt Relay captures agent answers from. New folders start off.", value: captureSummary) {
                        model.navigate(to: .capture)
                    }
                    Hairline()
                    toggle("Stay on the session I choose",
                           detail: "On: a new answer in another session shows as “New in …” and never replaces the one you are reading. Off: Prompt Relay follows the newest answer.",
                           isOn: Binding(get: { model.sessionPinned }, set: { on in
                               if on { model.selectSession(model.selectedSessionKey) } else { model.unpinSession() }
                           }))
                }
                IntegrationsView(model: model)
                section("Clipboard") {
                    toggle("Keep the last 5 copied images",
                           detail: "Screenshots and image files you copy anywhere, kept on this Mac for 24 hours to copy or drag later. Text from other apps is never read; password-manager items are skipped. Turning it off deletes them.",
                           isOn: Binding(get: { model.clipboardHistoryEnabled }, set: { model.clipboardHistoryEnabled = $0 }))
                    Hairline()
                    rowButton("Open Clipboard", detail: "Your last copies in Prompt Relay and the kept images.",
                              value: model.clipboardHistoryEnabled ? "\(model.clipboardImages?.items.count ?? 0) of \(ClipboardImageHistory.limit) images" : "") {
                        model.navigate(to: .clipboard)
                    }
                }
                if let settings {
                    appearance(settings)
                    notifications(settings)
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
    private func notchRows(_ settings: NotchSettings) -> some View {
        @Bindable var settings = settings
        Group {
            toggle("Open on hover", detail: "Show the answer when the pointer rests on the notch. Off: open from the menu bar or \(HotKeyRegistration.displayString).",
                   isOn: $settings.notchEnabled)
            Hairline()
            picker("Display", detail: "Automatic: the built-in display's notch, else another display with a notch, else a small floating island under the menu bar of the main display. A display you choose without a notch gets the floating island there. Unplugged, Automatic is used until it returns.",
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
            picker("Theme", detail: "Colors of the island. Classic is Phase 6's first look; the camera area stays black in all.",
                   current: settings.theme.title,
                   options: IslandTheme.allCases.map { ($0.title, $0) }) { settings.theme = $0 }
            Hairline()
            notchRows(settings)
            Hairline()
            toggle("Show Relay the bear", detail: "A small companion beside the notch. It reacts to new answers and copies.",
                   isOn: $settings.mascotEnabled)
            if settings.mascotEnabled {
                Hairline()
                picker("Relay", detail: "Subtle (default): calm head turns and an idle moment every 16–34 s. Expressive: fuller turns, every 9–18 s. Off: a still bear; nothing is animated or drawn. Motion → Reduced, or Reduce Motion with Follow System, keeps it still as well.",
                       current: settings.relayMotion.title,
                       options: NotchSettings.RelayMotion.allCases.map { ($0.title, $0) }) { settings.relayMotion = $0 }
                Hairline()
                toggle("Idle moments", detail: "Now and then a glance, a look around, a smile; sleepy after a long quiet time. Never while you move the pointer.",
                       isOn: $settings.relayIdle)
                Hairline()
                toggle("Follow the pointer", detail: "Relay's eyes and head turn toward the pointer near the island.",
                       isOn: $settings.relayFollowsPointer)
                Hairline()
                toggle("Relay on displays without a notch", detail: "A small pill under the menu bar, centred; hover opens Quick Peek. One Relay at a time, on the display Prompt Relay uses.",
                       isOn: $settings.relayWithoutNotch)
            }
            Hairline()
            picker("Motion", detail: "Follow System (default): System Settings → Accessibility → Reduce Motion decides. Smooth: full motion even when Reduce Motion is on — only if you choose it here. Reduced: short fades, no moving or resizing, and Relay keeps still.",
                   current: settings.animation.title,
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
                    Text("Clipboard text list").font(.system(size: 12.5)).foregroundStyle(Island.primary)
                    Text("References to your last \(AppModel.copyHistoryLimit) copies; the text itself is not stored.").font(.system(size: 11)).foregroundStyle(Island.tertiary)
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
        section("Advanced") {
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
            CaptureHealthRows(model: model)
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
            VStack(alignment: .leading, spacing: 3) {
                aboutLine("Build", AppBuild.isDebugBuild ? "Debug (Xcode)" : "Release")
                aboutLine("Commit", AppBuild.gitCommit ?? "not recorded in this build (Xcode builds; see `git log` in the checkout)")
                aboutLine("Plugin", model.doctor.value?.configuration.plugin.records.first { $0.id.hasPrefix("prompt-relay@") }?.version
                          ?? (model.doctor.value == nil ? "open Advanced to check" : "not detected"))
                aboutLine("Running", AppBuild.describeRunning().joined(separator: "\n"))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
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

    private func aboutLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Island.secondary).frame(width: 56, alignment: .leading)
            Text(value).font(.system(size: 11)).foregroundStyle(Island.tertiary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
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
