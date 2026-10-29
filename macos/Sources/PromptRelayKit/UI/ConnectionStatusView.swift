import SwiftUI

/// "Is Prompt Relay connected?" — built from `doctor --json`. Shows facts the
/// Core read locally; it never prints other tools' hook commands (the Core
/// only reports counts) and never message text.
public struct ConnectionStatusView: View {
    let model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        Group {
            switch model.doctor {
            case .idle, .loading(previous: nil):
                ProgressView("Checking Prompt Relay…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let error, nil):
                CoreErrorView(error) { model.loadDoctor() }
            default:
                if let doctor = model.doctor.value { report(doctor) }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
        .toolbar {
            ToolbarItem {
                Button { model.loadDoctor() } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                    .disabled(model.doctor.isLoading)
            }
        }
    }

    private func report(_ d: DoctorData) -> some View {
        Form {
            Section("Summary") {
                row("Capture", overall(d), ok: overallOK(d))
                if !d.findings.isEmpty {
                    ForEach(d.findings, id: \.self) { finding in
                        Label(finding.message, systemImage: finding.level == "error" ? "xmark.octagon" : "exclamationmark.triangle")
                            .foregroundStyle(finding.level == "error" ? .red : .orange)
                            .font(.callout)
                    }
                }
            }
            Section("Claude Code plugin") {
                if let record = d.configuration.plugin.records.first(where: { $0.id.hasPrefix("prompt-relay@") }) {
                    row("Installed", "\(record.id) \(record.version ?? "") (\(record.scope ?? "?") scope)",
                        ok: record.manifestFound && record.launcherFound)
                } else {
                    row("Installed", "No install record found", ok: false)
                }
                let plugin = d.observed.byVia["plugin"]
                row("Events received", plugin.map { "\($0.events) via plugin, last \(Wording.relative($0.lastAt))" } ?? "None yet",
                    ok: (plugin?.events ?? 0) > 0)
            }
            Section("Projects with capture on") {
                if d.capture.enabledProjects.isEmpty {
                    Text("None. Capture is off until a project is enabled.").foregroundStyle(.secondary)
                } else {
                    ForEach(d.capture.enabledProjects, id: \.self) { Text($0).textSelection(.enabled) }
                }
                if let error = d.capture.configError { row("Settings", error, ok: false) }
            }
            Section("Core") {
                row("Prompt Relay", d.core.promptRelayVersion, ok: true)
                row("Python", "\(d.core.python.version) — \(d.core.python.executable)", ok: d.core.python.supported)
                row("Hook interpreter", d.core.pinnedPython.path ?? d.core.pinnedPython.state, ok: d.core.pinnedPython.state == "ok")
                row("History", "\(d.storage.sessionFiles) session file(s) in \(d.storage.dataDir)",
                    ok: d.storage.exists && d.storage.writable)
                row("Updates", refreshDescription, ok: model.refreshMode == .watching)
            }
            if !d.unverified.isEmpty {
                Section("Not verifiable from here") {
                    ForEach(d.unverified, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var refreshDescription: String {
        switch model.refreshMode {
        case .watching: return "Live: watching the history folder"
        case .polling(let s): return "Checking every \(s) s (folder not watchable yet)"
        }
    }

    private func overallOK(_ d: DoctorData) -> Bool {
        !d.findings.contains { $0.level == "error" } && !d.capture.enabledProjects.isEmpty
    }

    private func overall(_ d: DoctorData) -> String {
        if d.findings.contains(where: { $0.level == "error" }) { return "Problem found" }
        if d.capture.enabledProjects.isEmpty { return "Off: no project enabled" }
        return "Ready"
    }

    private func row(_ title: String, _ value: String, ok: Bool) -> some View {
        LabeledContent {
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(ok ? Color.green : Color.orange)
            }
        }
    }
}
