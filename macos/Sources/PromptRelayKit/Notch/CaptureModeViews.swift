import SwiftUI

/// Phase 16: what capture does now and how to change it — All projects
/// (Global Capture), Selected projects or Paused. Shown at the top of
/// Projects and in Settings; a compact version in the Inbox only when
/// something needs the user (paused, plugin too old, or the one-time offer).
struct CaptureModeCard: View {
    let model: AppModel
    /// Projects / Settings: always shown, with the mode menu. Inbox: only
    /// when something needs the user.
    var compact = false

    var body: some View {
        let status = model.captureStatus
        if model.offersGlobalCapture, case .selectedProjects = status {
            offer
        } else if !compact || !status.isActive && status != .unknown {
            card(status)
        }
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "tray.full").font(.system(size: 13)).foregroundStyle(Island.accent).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Capture every project automatically?").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Island.primary)
                    Text("Answers from any project Claude Code or a connected Codex works in will appear here, grouped by project — no per-project switch. Stored only on this Mac. You can exclude projects or pause at any time.")
                        .font(.system(size: 11)).foregroundStyle(Island.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button("Capture All Projects") { Task { await model.setCaptureMode(.mode(.global)) } }
                    .buttonStyle(IslandPillStyle(prominent: true))
                    .accessibilityLabel("Turn on capture for all projects")
                Button("Not Now") { model.dismissGlobalCaptureOffer() }
                    .buttonStyle(IslandPillStyle(prominent: false))
                    .islandHelp("Keep capturing only the projects switched on in Projects")
            }
            if let error = model.captureModeError {
                Text(error).font(.system(size: 11)).foregroundStyle(Island.warning).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Island.rowRadius, style: .continuous).fill(Island.card))
    }

    private func card(_ status: AppModel.CaptureStatus) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: symbol(status)).font(.system(size: 12)).foregroundStyle(tint(status)).frame(width: 18)
                Text(status.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Island.primary)
                Spacer(minLength: 4)
                if model.captureSettings != nil { modeMenu }
            }
            .accessibilityElement(children: .combine)
            if let detail = status.detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(status.isActive ? Island.tertiary : Island.warning)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 26)
                    .textSelection(.enabled)
            }
            if let error = model.captureModeError {
                Text(error).font(.system(size: 11)).foregroundStyle(Island.warning).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
            }
        }
        .padding(compact ? 8 : 10)
        .background(RoundedRectangle(cornerRadius: Island.rowRadius, style: .continuous).fill(Island.card))
    }

    private var modeMenu: some View {
        Menu {
            Button("All Projects") { Task { await model.setCaptureMode(.mode(.global)) } }
            Button("Selected Projects Only") { Task { await model.setCaptureMode(.mode(.selected)) } }
            Divider()
            if model.captureSettings?.mode == .paused {
                Button("Resume Capture") { Task { await model.setCaptureMode(.resume) } }
            } else {
                Button("Pause Capture") { Task { await model.setCaptureMode(.mode(.paused)) } }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.captureSettings?.mode.title ?? "—").lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11.5)).foregroundStyle(Island.primary)
            .padding(.horizontal, 8).frame(height: 22)
            .background(Capsule().fill(Island.control))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Capture mode: \(model.captureSettings?.mode.title ?? "unknown")")
    }

    private func symbol(_ status: AppModel.CaptureStatus) -> String {
        switch status {
        case .allProjects: return "dot.radiowaves.left.and.right"
        case .selectedProjects: return "checklist"
        case .paused: return "pause.circle"
        case .pluginUpdateRequired: return "exclamationmark.triangle"
        case .unknown: return "questionmark.circle"
        }
    }

    private func tint(_ status: AppModel.CaptureStatus) -> Color {
        status.isActive ? Island.accent : Island.warning
    }
}
