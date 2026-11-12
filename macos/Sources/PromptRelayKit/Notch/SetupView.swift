import AppKit
import SwiftUI

/// Phase 11 first-run setup: Detect Agents → Connect → Enable Project →
/// Verify Capture → First Result, on one scrolling page. Every step can be
/// skipped and reopened later (empty Home, Settings → Agents & Projects).
///
/// Prompt Relay changes nothing here by itself: connecting an agent means
/// copying the exact commands, which the user runs and can undo; Enable
/// Project opens the existing capture switches. Status comes from
/// `AgentFacts`, which reports "Connected" only after a stored event.
struct SetupView: View {
    let model: AppModel
    let presentation: NotchPresentation
    @State private var facts = AgentFacts()
    @State private var note: String?
    @State private var expanded: ConnectionTarget?

    static let claudeConnect = """
    claude plugin marketplace add Banderos14/prompt-relay
    claude plugin install prompt-relay@prompt-relay
    """
    static let claudeUndo = "claude plugin uninstall prompt-relay@prompt-relay"

    static func codexConnect(_ target: ConnectionTarget) -> String {
        let config = target == .codexXcode
            ? "\"$HOME/Library/Developer/Xcode/CodingAssistant/codex/hooks.json\""
            : "\"$HOME/.codex/hooks.json\""
        let host = target.codexHost ?? "unknown"
        return """
        cd <your prompt-relay checkout>
        python3 macos/Integrations/configure-codex.py --config \(config) --host \(host)            # preview, changes nothing
        python3 macos/Integrations/configure-codex.py --config \(config) --host \(host) --apply    # keeps other hooks, writes a backup
        """
    }

    static func codexUndo(_ target: ConnectionTarget) -> String {
        let config = target == .codexXcode
            ? "\"$HOME/Library/Developer/Xcode/CodingAssistant/codex/hooks.json\""
            : "\"$HOME/.codex/hooks.json\""
        return "python3 macos/Integrations/configure-codex.py --config \(config) --host \(target.codexHost ?? "unknown") --disable --apply"
    }

    var body: some View {
        BoundedScroll(maxHeight: presentation.listHeight(chrome: 16)) {
            VStack(alignment: .leading, spacing: 8) {
                welcome
                if model.offersDailyUseSetup { DailyUseSetupCard(model: model) }
                step(1, "Agents on this Mac") { agents }
                step(2, "Enable a project") { projects }
                step(3, "Verify capture") { verify }
                if let answer = model.readyAnswer {
                    step(4, "First result") {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Island.accent)
                            Text("\(answer.sourceLabel) · \(answer.projectName) · \(Wording.relative(answer.at))")
                                .font(.system(size: 12)).foregroundStyle(Island.primary).lineLimit(1)
                            Spacer(minLength: 6)
                            Button("Open Answer") { model.navigate(to: .home) }.buttonStyle(IslandPillStyle(prominent: true))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(Island.secondary).padding(.leading, 4) }
            }
            .padding(.horizontal, IslandMetrics.of(presentation).leading)
        }
        .islandPadding(presentation, horizontal: false)
        .onAppear { recheck(load: model.doctor.value == nil) }
        .onChange(of: model.doctor.value) { _, _ in facts = AgentFacts.gather(model: model) }
        .onChange(of: model.allSessions.count) { _, _ in facts = AgentFacts.gather(model: model) }
    }

    private var welcome: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Connect an agent once").font(.system(size: 13, weight: .semibold)).foregroundStyle(Island.primary)
                Text("Prompt Relay keeps each final answer of Claude Code or Codex on this Mac, ready to copy with its context. Nothing is captured until you enable a project.")
                    .font(.system(size: 11.5)).foregroundStyle(Island.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button("Skip for Now") { model.navigate(to: .home) }.buttonStyle(IslandPillStyle(prominent: false))
        }
        .padding(.horizontal, 4).padding(.top, 4)
    }

    @ViewBuilder
    private var agents: some View {
        ForEach(Array(ConnectionTarget.allCases.enumerated()), id: \.element) { index, target in
            if index > 0 { Hairline() }
            agentRow(target)
        }
    }

    private func agentRow(_ target: ConnectionTarget) -> some View {
        let state = facts.state(of: target)
        let open = expanded == target || (expanded == nil && state.needsAction && firstNeedingAction == target)
        return VStack(alignment: .leading, spacing: 6) {
            Button { expanded = open ? .none : target } label: {
                HStack(spacing: 8) {
                    Circle().fill(color(state)).frame(width: 7, height: 7)
                    Text(target.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Island.primary)
                    Spacer(minLength: 6)
                    Text(state.title).font(.system(size: 11.5)).foregroundStyle(Island.secondary).lineLimit(1)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Island.tertiary)
                }
                .frame(minHeight: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(target.title): \(state.title)")
            if open {
                Text(facts.diagnosis(of: target))
                    .font(.system(size: 11.5)).foregroundStyle(Island.secondary).fixedSize(horizontal: false, vertical: true)
                actions(for: target, state: state)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    @ViewBuilder
    private func actions(for target: ConnectionTarget, state: ConnectionState) -> some View {
        switch state {
        case .configurationRequired, .error:
            let connect = target == .claudeCode ? Self.claudeConnect : Self.codexConnect(target)
            let undo = target == .claudeCode ? Self.claudeUndo : Self.codexUndo(target)
            Text(connect).font(.system(size: 11, design: .monospaced)).foregroundStyle(Island.primary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Island.smallRadius).fill(Island.control))
            Text(target == .claudeCode
                 ? "Changes: Claude Code adds the plugin to your user settings (its own mechanism). Other plugins and hooks stay. Undo: \(undo)"
                 : "Changes: adds three Prompt Relay hook entries to that hooks.json; other hooks stay; a backup is written first. Undo: \(undo)")
                .font(.system(size: 11)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Button("Copy Commands") { copy(connect) }.buttonStyle(IslandPillStyle(prominent: true))
                Button("Check Again") { recheck(load: true) }.buttonStyle(IslandPillStyle(prominent: false))
            }
        case .trustRequired, .captureDisabled, .waitingForFirstEvent, .installed:
            HStack(spacing: 6) {
                if state == .captureDisabled {
                    Button("Enable a Project") { model.navigate(to: .capture) }.buttonStyle(IslandPillStyle(prominent: true))
                }
                Button("Check Again") { recheck(load: true) }.buttonStyle(IslandPillStyle(prominent: false))
            }
        case .notDetected, .connected:
            EmptyView()
        }
    }

    private var projects: some View {
        let on = model.projectRows.filter(\.captureEnabled).count
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(on == 0 ? "No project is captured yet" : "\(on) project\(on == 1 ? "" : "s") captured")
                    .font(.system(size: 12.5)).foregroundStyle(Island.primary)
                Text("Only folders you turn on are recorded. Turning one off keeps its history.")
                    .font(.system(size: 11)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button(on == 0 ? "Choose Project…" : "Projects") { model.navigate(to: .capture) }
                .buttonStyle(IslandPillStyle(prominent: on == 0))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var verify: some View {
        let connected = ConnectionTarget.allCases.filter { facts.state(of: $0).isConnected }
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(connected.isEmpty ? "No event received yet" : "Receiving from " + connected.map(\.title).joined(separator: ", "))
                    .font(.system(size: 12.5)).foregroundStyle(Island.primary)
                Text(connected.isEmpty
                     ? "Send any short prompt to your agent in an enabled project, then Check Again. A configuration file alone does not count."
                     : "Connected means Prompt Relay stored a real event from that agent.")
                    .font(.system(size: 11)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button("Check Again") { recheck(load: true) }.buttonStyle(IslandPillStyle(prominent: connected.isEmpty))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var firstNeedingAction: ConnectionTarget? {
        ConnectionTarget.allCases.first { facts.state(of: $0).needsAction }
    }

    private func color(_ state: ConnectionState) -> Color {
        switch state {
        case .connected: return Island.accent
        case .notDetected: return Island.tertiary.opacity(0.6)
        case .waitingForFirstEvent, .installed: return Island.secondary
        default: return Island.warning
        }
    }

    private func recheck(load: Bool) {
        if load { model.refresh(); model.loadDoctor() }
        facts = AgentFacts.gather(model: model)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        note = "Copied. Paste into Terminal, read what each line does, then run it."
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Caption("\(number) · \(title)").padding(.leading, 4).padding(.top, 6)
            GroupCard { content() }
        }
    }
}
