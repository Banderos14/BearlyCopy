import SwiftUI

/// Phase 17: the one-time setup. The three choices that need the user's own
/// yes are in front of them; nothing here is on until they press Enable.
struct DailyUseSetupCard: View {
    let model: AppModel
    @State private var choices: AppModel.DailyUseChoices?
    @State private var working = false

    private var current: AppModel.DailyUseChoices { choices ?? model.dailyUseProposal }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(Island.accent).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up daily use").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Island.primary)
                    Text("The newest answer and its result files already arrive by themselves. These three need your yes, once. Everything stays on this Mac.")
                        .font(.system(size: 11)).foregroundStyle(Island.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            choice("Capture all projects",
                   detail: "Every project Claude Code or a connected Codex works in, without a per-project switch. You can exclude projects or pause.",
                   isOn: current.globalCapture) { var c = current; c.globalCapture.toggle(); choices = c }
            if current.globalCapture, model.captureSettings?.mode != .global, let blocked = model.globalCaptureBlockedByPlugin {
                Label("The Claude Code plugin is \(blocked.installed); All Projects needs \(blocked.needed). It will be switched on after the plugin update, not before — an old plugin would store nothing.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(Island.warning).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
            }
            choice("Automatic final screenshots",
                   detail: "After each final answer, one still image of the window you link to that agent. Memory only. macOS asks for Screen Recording when you link a window.",
                   isOn: current.autoScreenshots) {
                var c = current; c.autoScreenshots.toggle()
                if !c.autoScreenshots { c.screenshotsInHandoff = model.autoScreenshotsInHandoff }
                choices = c
            }
            choice("Include screenshots in hand-offs",
                   detail: "On: they start ticked for Copy with Context and drag. Off: you tick them yourself.",
                   isOn: current.screenshotsInHandoff, enabled: current.autoScreenshots) {
                var c = current; c.screenshotsInHandoff.toggle(); choices = c
            }
            HStack(spacing: 10) {
                Button("Enable Recommended Daily Use") {
                    working = true
                    let chosen = current
                    Task {
                        await model.enableDailyUse(chosen)
                        working = false
                        model.dailySetupOpen = false
                    }
                }
                .buttonStyle(IslandPillStyle(prominent: true))
                .disabled(working)
                .accessibilityLabel("Enable the ticked daily-use options")
                Button("Not Now") { model.dismissDailyUseSetup(); model.dailySetupOpen = false }
                    .buttonStyle(IslandPillStyle(prominent: false))
                    .islandHelp("Change nothing. Settings → Daily Use opens this again.")
            }
            .padding(.top, 2)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Island.rowRadius, style: .continuous).fill(Island.card))
    }

    private func choice(_ title: String, detail: String, isOn: Bool, enabled: Bool = true, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isOn && enabled ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12)).foregroundStyle(isOn && enabled ? Island.accent : Island.tertiary).frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12)).foregroundStyle(enabled ? Island.primary : Island.tertiary)
                    Text(detail).font(.system(size: 11)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
        .accessibilityValue(isOn && enabled ? "on" : "off")
        .accessibilityHint(detail)
    }
}

/// Phase 17: Settings → Daily Use. One state, one sentence, one action;
/// the checks behind it on request. Never "Ready" from a toggle alone.
struct DailyUseStatusCard: View {
    let model: AppModel
    @State private var showsChecks = false
    @State private var checking = false

    var body: some View {
        let report = model.dailyUse
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: report.state == .ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(report.state == .ready ? Island.success : Island.warning).frame(width: 18)
                Text(report.state.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Island.primary)
                Spacer(minLength: 4)
                Button(checking ? "Checking…" : "Check Again") {
                    checking = true
                    Task { await model.recheckDailyUse(); checking = false }
                }
                .buttonStyle(IslandPillStyle(prominent: false)).disabled(checking)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Daily use: \(report.state.title). \(report.summary)")
            Text(report.summary).font(.system(size: 11)).foregroundStyle(report.state == .ready ? Island.tertiary : Island.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 26).textSelection(.enabled)
            if let notice = model.dailyUseNotice {
                Text(notice).font(.system(size: 11)).foregroundStyle(Island.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
            }
            if case .pluginUpdateFirst(let installed, let needed)? = model.dailyUseOutcome, model.globalCaptureBlockedByPlugin != nil {
                Text("All Projects is not on yet: the Claude Code plugin is \(installed) and needs \(needed). Update it, start a new Claude session, then choose All Projects.")
                    .font(.system(size: 11)).foregroundStyle(Island.warning).fixedSize(horizontal: false, vertical: true).padding(.leading, 26)
            }
            HStack(spacing: 8) {
                if let action = report.action {
                    Button(action.title) { model.perform(action) }.buttonStyle(IslandPillStyle(prominent: true))
                }
                if report.action != .openSetup {
                    Button("Set Up…") { model.dailySetupOpen = true }.buttonStyle(IslandPillStyle(prominent: false))
                        .islandHelp("Review Global Capture and automatic screenshots")
                }
                if model.globalCaptureBlockedByPlugin != nil, report.action != .showPluginUpdate {
                    Button("Copy Update Commands") { model.perform(.showPluginUpdate) }.buttonStyle(IslandPillStyle(prominent: false))
                }
                Spacer(minLength: 0)
                Button(showsChecks ? "Hide Checks" : "Show Checks") { showsChecks.toggle() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Island.accent)
            }
            .padding(.leading, 26)
            if model.dailySetupOpen {
                DailyUseSetupCard(model: model)
            }
            if showsChecks {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.checks) { check in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: symbol(check.level)).font(.system(size: 10)).foregroundStyle(tint(check.level)).frame(width: 14)
                            Text(check.title).font(.system(size: 11, weight: .medium)).foregroundStyle(Island.primary)
                                .frame(width: 128, alignment: .leading)
                            Text(check.detail).font(.system(size: 11)).foregroundStyle(Island.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(check.title): \(check.detail)")
                    }
                }
                .padding(.leading, 26).padding(.top, 2)
            }
        }
        .padding(10)
        .task { if model.doctor.value == nil { model.loadDoctor() } }
    }

    private func symbol(_ level: AppModel.DailyUseCheck.Level) -> String {
        switch level {
        case .ok: return "checkmark.circle"
        case .attention: return "exclamationmark.triangle"
        case .off: return "minus.circle"
        case .info: return "info.circle"
        }
    }

    private func tint(_ level: AppModel.DailyUseCheck.Level) -> Color {
        switch level {
        case .ok: return Island.success
        case .attention: return Island.warning
        case .off, .info: return Island.tertiary
        }
    }
}

/// Phase 17: what Home shows beside the conversation when the report on
/// screen is not the newest answer — always visible, never a tooltip:
/// "Pinned" when the user chose to stay, and the way back to Latest.
struct LatestChip: View {
    let model: AppModel
    /// The "New in …" chip beside it already leads to the newer answer.
    var pinOnly = false

    var body: some View {
        HStack(spacing: 6) {
            if model.sessionPinned {
                HStack(spacing: 3) {
                    Image(systemName: "pin.fill").font(.system(size: 8, weight: .semibold))
                    Text("Pinned").lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Island.secondary)
                .padding(.horizontal, 6).frame(height: 18).background(Capsule().fill(Island.cardRaised))
                .accessibilityLabel("This conversation is pinned")
                .islandHelp("Prompt Relay stays on this conversation. Follow Latest in Settings unpins it.")
            }
            if !pinOnly, model.isOffLatest, let latest = model.readyAnswer {
                Button {
                    if model.sessionPinned { model.followLatestNow() } else { model.jumpToLatest() }
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(Island.success).frame(width: 6, height: 6)
                        Text(model.sessionPinned ? "Follow Latest" : "Jump to Latest").lineLimit(1)
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Island.primary)
                    .padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(Island.cardRaised))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.sessionPinned ? "Unpin and open the newest answer" : "Open the newest answer")
                .islandHelp("Newest answer: \(latest.sourceLabel), \(latest.projectName)")
            }
        }
        .fixedSize()
    }
}
