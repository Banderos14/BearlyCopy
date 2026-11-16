import SwiftUI

/// Capture Health (Settings → Advanced): the current project's capture, the
/// last event the hooks stored, and whether command events exist for the
/// answer shown. "No commands" is told apart: a turn that ran none, capture
/// off, or events that were never recorded.
struct CaptureHealthRows: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Current project", value: project.text, ok: project.ok)
            row("Last hook event", value: lastEvent, ok: lastEvent != "none recorded")
            row("Command events", value: commands.text, ok: commands.ok)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .islandFrame("settings.captureHealth")
    }

    private func row(_ title: String, value: String, ok: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(ok ? Island.success : Island.warning).frame(width: 6, height: 6).padding(.top, 5)
            Text(title).font(.system(size: 12)).foregroundStyle(Island.primary).frame(width: 118, alignment: .leading)
            Text(value).font(.system(size: 11)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var project: (text: String, ok: Bool) {
        if model.selectedImport != nil { return ("an imported result (no capture involved)", true) }
        guard let p = model.selectedProject else { return ("none selected", false) }
        return ("\(p.name ?? p.path ?? "unnamed"): capture \(p.captureEnabled ? "on" : "off")", p.captureEnabled)
    }

    private var lastEvent: String {
        guard let doctor = model.doctor.value else { return model.doctor.isLoading ? "checking…" : "unknown" }
        let latest = doctor.observed.byVia.compactMap { via, v in v.lastAt.map { (via, $0) } }.max { $0.1 < $1.1 }
        return latest.map { "\(Wording.relative($0.1)) (via \($0.0))" } ?? "none recorded"
    }

    static func commandsHealth(captureOn: Bool, observed: ObservedCounts?, imported: Bool) -> (text: String, ok: Bool) {
        if imported { return ("not applicable to imports", true) }
        if !captureOn { return ("capture is off for this project", false) }
        guard let observed else { return ("not recorded for this answer (plugin 0.3.0+ tool hooks needed)", false) }
        if observed.toolEvents == 0 { return ("recorded; this turn ran no tools", true) }
        return ("recorded: \(observed.toolEvents) tool events in this turn", true)
    }

    private var commands: (text: String, ok: Bool) {
        Self.commandsHealth(captureOn: model.selectedProject?.captureEnabled ?? true, observed: model.selectedTurn?.observed,
                            imported: model.selectedImport != nil)
    }
}
