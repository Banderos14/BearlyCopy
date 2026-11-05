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
    @State private var xcodeConfiguration = CodexHookConfiguration(state: .absent)
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("Integrations")
            GroupCard {
                IntegrationStatusRow(model: model, provider: .claudeCode)
                Hairline()
                IntegrationStatusRow(model: model, provider: .codex)
                Text(xcodeConfiguration.summary)
                    .font(.system(size: 11)).foregroundStyle(Island.secondary).padding(.horizontal, 12)
                let delivery = CodexDeliveryStatus(sessions: model.allSessions, observed: model.doctor.value?.observed.bySource?["codex:xcode"])
                Text(delivery.summary)
                    .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12)
                Text(delivery.detail)
                    .font(.system(size: 10.5)).foregroundStyle(Island.secondary).padding(.horizontal, 12)
                Text("This app: PID \(ProcessInfo.processInfo.processIdentifier) · \(Bundle.main.bundleURL.path)")
                    .font(.system(size: 10.5)).foregroundStyle(Island.tertiary).padding(.horizontal, 12)
                if !AppBuild.otherBuildsRunning().isEmpty {
                    Text("Another Prompt Relay build is running. An older build may not recognize Codex. Manage running copies in Settings → About.")
                        .font(.system(size: 11)).foregroundStyle(Island.secondary).padding(.horizontal, 12)
                }
                Text("Definitions do not prove trust. Saved Xcode events confirm delivery at the displayed time; Test Connection starts no AI task.")
                    .font(.system(size: 10.5)).foregroundStyle(Island.tertiary).padding(.horizontal, 12)
                Hairline()
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Auto-select result attachments", isOn: Binding(
                        get: { model.autoSelectResultAttachments }, set: { model.autoSelectResultAttachments = $0 }))
                    Text("Automatically prepare available result files for sharing. You can remove any attachment.")
                        .font(.system(size: 11)).foregroundStyle(Island.tertiary)
                    Button("Test Connection") {
                        Task {
                            xcodeConfiguration = .inspect(at: CodexHookConfiguration.xcodeURL)
                            diagnostic = await model.testIntegrationConnection()
                        }
                    }.buttonStyle(IslandPillStyle(prominent: false))
                    if let diagnostic { Text(diagnostic).font(.system(size: 11)).foregroundStyle(Island.secondary) }
                }.padding(12)
            }
        }
        .task {
            xcodeConfiguration = .inspect(at: CodexHookConfiguration.xcodeURL)
            diagnostic = await model.testIntegrationConnection()
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
                Text(sessions.isEmpty ? "Action required" : "Recorded events")
                    .font(.system(size: 11)).foregroundStyle(Island.secondary)
            }
            Text("Source adapter: installed in Prompt Relay")
                .font(.system(size: 10.5)).foregroundStyle(Island.tertiary)
            if sessions.isEmpty {
                Text("No recorded hook events. Setup and a real session are required.")
                    .font(.system(size: 11)).foregroundStyle(Island.secondary)
            }
            if let latest = sessions.first {
                Text("\(latest.sourceLabel) · last event \(Wording.relative(latest.lastEventAt))")
                    .font(.system(size: 11)).foregroundStyle(Island.secondary)
            }
            if provider == .codex, !sessions.contains(where: { $0.source?.environment == .xcode }) {
                Text("Xcode: no recorded events; CLI history does not verify Xcode capture.")
                    .font(.system(size: 11)).foregroundStyle(Island.secondary)
            }
            if let source = sessions.first?.source {
                Text("Source capabilities: " + source.capabilities.joined(separator: ", "))
                    .font(.system(size: 10.5)).foregroundStyle(Island.tertiary)
            }
            Text(provider == .codex
                 ? "Requires reviewed Codex hooks and project capture enabled. Delivery stages above distinguish configuration, execution, storage and the final Stop."
                 : "UserPromptSubmit, Stop, PostToolUse and PostToolUseFailure through the existing Claude Code plugin.")
                .font(.system(size: 11)).foregroundStyle(Island.tertiary)
            Text("To stop capture, disable the project in Projects or disable Prompt Relay hooks in the agent. Saved history stays available.")
                .font(.system(size: 10.5)).foregroundStyle(Island.tertiary)
        }.padding(12)
    }
}
