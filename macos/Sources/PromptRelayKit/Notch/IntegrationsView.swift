import SwiftUI

struct ProviderFilterPicker: View {
    let model: AppModel
    var body: some View {
        Picker("Agent", selection: Binding(get: { model.providerFilter }, set: { model.providerFilter = $0 })) {
            Text("All").tag(AgentProvider?.none)
            Text("Claude Code").tag(AgentProvider?.some(.claudeCode))
            Text("Codex").tag(AgentProvider?.some(.codex))
            Text("Imported").tag(AgentProvider?.some(.imported))
        }
        .pickerStyle(.segmented)
    }
}

struct IntegrationsView: View {
    let model: AppModel
    @State private var diagnostic: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("Integrations")
            GroupCard {
                IntegrationStatusRow(model: model, provider: .claudeCode)
                Hairline()
                IntegrationStatusRow(model: model, provider: .codex)
                Hairline()
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Auto-select result attachments", isOn: Binding(
                        get: { model.autoSelectResultAttachments }, set: { model.autoSelectResultAttachments = $0 }))
                    Text("Automatically prepare available result files for sharing. You can remove any attachment.")
                        .font(.system(size: 11)).foregroundStyle(Island.tertiary)
                    Button("Test Connection") {
                        Task {
                            diagnostic = await model.testIntegrationConnection()
                        }
                    }.buttonStyle(IslandPillStyle(prominent: false))
                    if let diagnostic { Text(diagnostic).font(.system(size: 11)).foregroundStyle(Island.secondary) }
                }.padding(12)
            }
        }
    }
}

struct IntegrationStatusRow: View {
    let model: AppModel
    let provider: AgentProvider
    var body: some View {
        let sessions = model.allSessions.filter { $0.provider == provider }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(provider.title).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text(sessions.isEmpty ? "Not connected" : "Limited · events received")
                    .font(.system(size: 11)).foregroundStyle(Island.secondary)
            }
            if let latest = sessions.first {
                Text("\(latest.sourceLabel) · last event \(Wording.relative(latest.lastEventAt))")
                    .font(.system(size: 11)).foregroundStyle(Island.secondary)
            }
            if let source = sessions.first?.source {
                Text("Source capabilities: " + source.capabilities.joined(separator: ", "))
                    .font(.system(size: 10.5)).foregroundStyle(Island.tertiary)
            }
            Text(provider == .codex
                 ? "Requires reviewed Codex hooks and project capture enabled. Xcode capture is unverified; use Import AI Result for a reliable manual handoff."
                 : "UserPromptSubmit, Stop, PostToolUse and PostToolUseFailure through the existing Claude Code plugin.")
                .font(.system(size: 11)).foregroundStyle(Island.tertiary)
            Text("To stop capture, disable the project in Projects or disable Prompt Relay hooks in the agent. Saved history stays available.")
                .font(.system(size: 10.5)).foregroundStyle(Island.tertiary)
        }.padding(12)
    }
}
