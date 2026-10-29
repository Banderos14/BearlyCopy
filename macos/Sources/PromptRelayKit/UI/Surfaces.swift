import SwiftUI

// Surfaces: compositions of the shared components over the one AppModel.
// Phase 3B adds a notch surface here; it reuses the same pieces.

/// Actions a surface cannot perform itself (opening windows, quitting); the
/// app lifecycle supplies them.
public struct SurfaceActions {
    public var openWindow: () -> Void
    public var openStatus: () -> Void
    public var quit: () -> Void

    public init(openWindow: @escaping () -> Void, openStatus: @escaping () -> Void, quit: @escaping () -> Void) {
        self.openWindow = openWindow
        self.openStatus = openStatus
        self.quit = quit
    }
}

// MARK: - Shared lists

/// Projects, sessions and turns as plain lists, so the window and the panel
/// render identical rows and empty states.
public struct ProjectList: View {
    let model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        let selection = Binding<String?>(get: { model.selectedProjectPath }, set: { model.selectProject($0) })
        if let error = model.projects.error, model.projects.value == nil {
            CoreErrorView(error) { model.refresh() }
        } else if let projects = model.projects.value, projects.isEmpty {
            EmptyState("No projects yet",
                       message: "Enable capture for a project with `prompt-relay enable <folder>`, then send a prompt in Claude Code.",
                       systemImage: "folder.badge.questionmark")
        } else {
            List(model.projects.value ?? [], selection: selection) { project in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(Wording.projectName(project)).lineLimit(1)
                        if !project.captureEnabled {
                            Image(systemName: "pause.circle").foregroundStyle(.secondary).help("Capture is off for this project")
                        }
                    }
                    Text(project.sessionCount == 1 ? "1 session" : "\(project.sessionCount) sessions")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(project.path ?? "")
                .help(project.path ?? "")
            }
        }
    }
}

public struct SessionList: View {
    let model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        let selection = Binding<String?>(get: { model.selectedSessionKey }, set: { model.selectSession($0) })
        if model.selectedProjectPath == nil {
            EmptyState("No project selected", message: "Choose a project.", systemImage: "sidebar.left")
        } else if let error = model.sessions.error, model.sessions.value == nil {
            CoreErrorView(error) { model.refresh() }
        } else if let sessions = model.sessions.value, sessions.isEmpty {
            EmptyState("No sessions yet",
                       message: "Send a prompt to Claude Code in this project. New answers appear here automatically.",
                       systemImage: "bubble.left.and.text.bubble.right")
        } else if model.sessions.value == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.sessions.value ?? [], selection: selection) { session in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(Wording.sessionTitle(session)).font(.body.monospacedDigit())
                        Spacer()
                        Text(Wording.relative(session.lastEventAt)).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text(session.turnCount == 1 ? "1 turn" : "\(session.turnCount) turns")
                        if let last = session.lastTurn { StatusBadge(last.status) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .tag(session.sessionKey)
                .help(session.sessionID ?? session.sessionKey)
            }
        }
    }
}

public struct TurnList: View {
    let model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        let selection = Binding<Int?>(get: { model.selectedTurnIndex }, set: { model.selectTurn($0) })
        if let error = model.turns.error, model.turns.value == nil {
            CoreErrorView(error) { model.refresh() }
        } else if model.selectedSessionKey == nil {
            EmptyState("No session selected", message: "Choose a session.", systemImage: "list.bullet")
        } else if model.turns.value == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.turnsNewestFirst, selection: selection) { turn in
                TurnRow(turn: turn) {
                    guard let key = model.selectedSessionKey else { return }
                    Task { await model.copyResponse(sessionKey: key, turn: turn.index) }
                }
                .tag(turn.index)
            }
        }
    }
}

// MARK: - Main window

public struct MainWindowView: View {
    let model: AppModel
    let actions: SurfaceActions

    public init(model: AppModel, actions: SurfaceActions) {
        self.model = model
        self.actions = actions
    }

    public var body: some View {
        NavigationSplitView {
            ProjectList(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 210)
                .safeAreaInset(edge: .bottom) { ConnectionFooter(model: model, openStatus: actions.openStatus) }
        } content: {
            SessionList(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VSplitView {
                TurnList(model: model).frame(minHeight: 120, idealHeight: 200)
                ResponseDetailView(model: model)
                    .padding(14)
                    .frame(minHeight: 260)
            }
        }
        .navigationTitle(model.selectedProject.map(Wording.projectName) ?? "Prompt Relay")
        .toolbar {
            ToolbarItem {
                RefreshButton(model: model)
            }
        }
        .sensitiveContextAlert(model)
        .frame(minWidth: 860, minHeight: 520)
        .onAppear { model.surfaceAppeared() }
        .onDisappear { model.surfaceDisappeared() }
    }
}

// MARK: - Menu-bar panel

/// Compact panel shown from the menu-bar icon. One glance: the newest answers
/// of the chosen project with a copy button each, and the selected answer.
public struct MenuPanelView: View {
    let model: AppModel
    let actions: SurfaceActions

    public init(model: AppModel, actions: SurfaceActions) {
        self.model = model
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let error = model.projects.error, model.projects.value == nil {
                CoreErrorView(error) { model.refresh() }.frame(height: 260)
            } else if let projects = model.projects.value, projects.isEmpty {
                EmptyState("No projects yet",
                           message: "Enable capture with `prompt-relay enable <folder>`, then send a prompt in Claude Code.",
                           systemImage: "folder.badge.questionmark")
                    .frame(height: 260)
            } else {
                pickers
                TurnList(model: model)
                    .listStyle(.plain)
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                ResponseDetailView(model: model, compact: true)
                    .frame(height: 250)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 420)
        .sensitiveContextAlert(model)
        .onAppear { model.surfaceAppeared() }
        .onDisappear { model.surfaceDisappeared() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard").foregroundStyle(.tint)
            Text("Prompt Relay").font(.headline)
            Spacer()
            RefreshButton(model: model)
                .buttonStyle(.borderless)
            Button { actions.openWindow() } label: { Image(systemName: "macwindow") }
                .buttonStyle(.borderless)
                .help("Open the Prompt Relay window")
        }
    }

    private var pickers: some View {
        HStack(spacing: 8) {
            Picker("Project", selection: Binding<String?>(get: { model.selectedProjectPath },
                                                         set: { model.selectProject($0) })) {
                ForEach(model.projects.value ?? []) { project in
                    Text(Wording.projectName(project)).tag(Optional(project.path ?? ""))
                }
            }
            .labelsHidden()
            Picker("Session", selection: Binding<String?>(get: { model.selectedSessionKey },
                                                         set: { model.selectSession($0) })) {
                ForEach(model.sessions.value ?? []) { session in
                    Text("\(Wording.sessionTitle(session)) · \(Wording.relative(session.lastEventAt))")
                        .tag(Optional(session.sessionKey))
                }
            }
            .labelsHidden()
            .disabled((model.sessions.value ?? []).isEmpty)
        }
    }

    private var footer: some View {
        HStack {
            ConnectionFooter(model: model, openStatus: actions.openStatus)
            Spacer()
            Button("Quit") { actions.quit() }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .font(.caption)
    }
}

// MARK: - Small shared pieces

public struct RefreshButton: View {
    let model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        Button { model.refresh() } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .labelStyle(.iconOnly)
        .keyboardShortcut("r")
        .help(model.lastRefresh.map { "Updated \($0.formatted(date: .omitted, time: .standard))" } ?? "Refresh")
    }
}

/// One line: is the Core reachable, is the history live-updating.
public struct ConnectionFooter: View {
    let model: AppModel
    let openStatus: () -> Void

    public init(model: AppModel, openStatus: @escaping () -> Void) {
        self.model = model
        self.openStatus = openStatus
    }

    public var body: some View {
        Button(action: openStatus) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(text).lineLimit(1)
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
        .help("Show connection status")
    }

    private var failed: Bool { model.projects.error != nil && model.projects.value == nil }

    private var color: Color {
        if failed { return .red }
        if model.doctor.value?.findings.contains(where: { $0.level == "error" }) == true { return .orange }
        return model.projects.value == nil ? .gray : .green
    }

    private var text: String {
        if failed { return "Core unavailable" }
        guard model.projects.value != nil else { return "Connecting…" }
        switch model.refreshMode {
        case .watching: return "Connected · live"
        case .polling: return "Connected · refresh every \(AppModel.pollSeconds) s"
        }
    }
}
