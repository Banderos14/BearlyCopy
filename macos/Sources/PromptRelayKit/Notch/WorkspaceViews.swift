import SwiftUI

// Phase 12: Results Inbox, Quick Switcher, and the By Agent grouping of
// Project and Session. All three read the same model state as History and
// Project and Session; none keeps its own copy of the history.

// MARK: - Results Inbox

/// Final answers of every agent, newest first. A row opens exactly that
/// result on Home; reading one never marks another as read.
struct InboxView: View {
    let model: AppModel
    let presentation: NotchPresentation

    var body: some View {
        let entries = model.inboxEntries
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            HStack(spacing: 8) {
                Picker("Show", selection: Binding(get: { model.inboxFilter }, set: { model.inboxFilter = $0 })) {
                    Text("All").tag(AppModel.InboxFilter.all)
                    Text(model.unreadResultCount > 0 ? "Unread (\(model.unreadResultCount))" : "Unread").tag(AppModel.InboxFilter.unread)
                    let attention = model.inboxNeedsAttention.count
                    if attention > 0 || model.inboxFilter == .attention {
                        Text("Attention (\(attention))").tag(AppModel.InboxFilter.attention)
                    }
                }
                .pickerStyle(.segmented).fixedSize().labelsHidden()
                .accessibilityLabel("Show all or unread results")
                ProfileFilterMenu(model: model)
                Spacer(minLength: 4)
                if entries.contains(where: model.isUnread) {
                    Button("Mark Read") { model.markInboxRead() }
                        .buttonStyle(IslandPillStyle(prominent: false))
                        .islandHelp("Mark the results listed here as read")
                }
            }
            CaptureModeCard(model: model, compact: true)
            content(entries)
            PackBar(model: model)
        }
        .islandPadding(presentation)
    }

    @ViewBuilder
    private func content(_ entries: [ResultSummary]) -> some View {
        switch model.inbox {
        case .idle, .loading(previous: nil):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading results…").font(.system(size: 12)).foregroundStyle(Island.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        case .failed(let error, previous: nil):
            MessageCard(title: "Results could not be loaded", detail: error.detail, symbol: "exclamationmark.triangle",
                        tint: Island.warning, action: ("Try Again", { Task { await model.loadInbox() } }))
        default:
            let attention = model.inboxFilter == .all ? model.inboxNeedsAttention : []
            if entries.isEmpty && model.inboxFilter == .attention {
                MessageCard(title: "Nothing needs attention",
                            detail: "Results whose completion is unknown appear here: the agent stopped while its own work was running and nothing followed.",
                            symbol: "checkmark.circle", tint: Island.secondary, action: nil)
            } else if entries.isEmpty && attention.isEmpty {
                MessageCard(title: model.inboxFilter == .unread ? "Nothing unread" : "No final results yet",
                            detail: model.inboxFilter == .unread
                                ? "Every result listed has been opened. Switch to All to see them."
                                : "Final answers of Claude Code and Codex appear here as they finish, newest first.",
                            symbol: model.inboxFilter == .unread ? "checkmark.circle" : "tray", tint: Island.secondary, action: nil)
            } else {
                BoundedScroll(maxHeight: presentation.listHeight(chrome: model.packRefs.isEmpty ? 76 : 112)) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if model.inboxFilter == .attention {
                            AttentionNote()
                        }
                        ForEach(entries) { r in InboxRow(model: model, result: r) }
                        if !attention.isEmpty {
                            HStack(spacing: 5) {
                                Image(systemName: "exclamationmark.triangle").font(.system(size: 10, weight: .semibold))
                                Text("Needs attention · \(attention.count)").font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(Island.warning)
                            .padding(.horizontal, 9).padding(.top, entries.isEmpty ? 4 : 10).padding(.bottom, 2)
                            .islandFrame("inbox.attention")
                            AttentionNote()
                            ForEach(attention) { r in InboxRow(model: model, result: r) }
                        }
                        footer(shown: entries.count)
                    }
                    .padding(4)
                }
                .background(RoundedRectangle(cornerRadius: Island.cardRadius).fill(Island.card))
            }
        }
    }

    @ViewBuilder
    private func footer(shown: Int) -> some View {
        let loaded = model.inbox.value?.count ?? 0
        if model.inboxTotal > loaded {
            HStack {
                Text("\(loaded) of \(model.inboxTotal) results").font(.system(size: 11)).foregroundStyle(Island.tertiary)
                Spacer()
                Button("Show More") { model.loadMoreInbox() }.buttonStyle(.plain).foregroundStyle(Island.accent)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 9).frame(height: 28)
        }
    }
}

struct InboxRow: View {
    let model: AppModel
    let result: ResultSummary

    var body: some View {
        let unread = model.isUnread(result)
        let attention = AppModel.inboxSection(result) == .needsAttention
        let current = model.currentRef == result.ref
        let files = model.attachments(for: result.ref).count + (result.observed?.filesChanged ?? 0)
        HStack(alignment: .top, spacing: 2) {
        Button { model.openResult(result) } label: {
            HStack(alignment: .top, spacing: 7) {
                if attention {
                    Image(systemName: "questionmark.circle").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Island.warning).frame(width: 6, height: 12).padding(.top, 2)
                        .accessibilityHidden(true)
                } else {
                    Circle().fill(unread ? Island.success : .clear).frame(width: 6, height: 6).padding(.top, 5)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 12, weight: unread ? .semibold : .medium))
                            .foregroundStyle(attention ? Island.secondary : Island.primary).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        if !attention, model.readyAnswer?.sessionKey == result.sessionKey, model.readyAnswer?.turnIndex == result.turn {
                            Text("Latest").font(.system(size: 11, weight: .semibold)).foregroundStyle(Island.success)
                        }
                        Text(Wording.relative(result.answeredAt)).font(.system(size: 11)).foregroundStyle(Island.tertiary)
                            .lineLimit(1).fixedSize()
                    }
                    HStack(spacing: 5) {
                        Text(meta).font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 2)
                        if files > 0 {
                            Label("\(files)", systemImage: "paperclip").labelStyle(.titleAndIcon)
                                .font(.system(size: 11)).foregroundStyle(Island.tertiary)
                                .accessibilityLabel("\(files) files or attachments")
                        }
                        if let state = stateTag { Text(state).font(.system(size: 11, weight: .medium)).foregroundStyle(Island.warning) }
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Island.rowRadius).fill(current ? Island.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel((attention ? "Completion unknown. " : unread ? "Unread. " : "") + title + ". " + meta)
        .islandHelp(attention ? "Completion unknown: open to see the last message and what was observed" : "Open this result")
        .contextMenu {
            Button("Open") { model.openResult(result) }
            Button(model.isPinned(result.ref) ? "Unpin" : "Pin") { model.togglePin(result.ref) }
            if model.advancedToolsEnabled {
                Button(model.isInPack(result.ref) ? "Remove from Context Pack" : "Add to Context Pack") { model.togglePack(result.ref) }
            }
        }
        if model.advancedToolsEnabled { PackToggle(model: model, ref: result.ref).padding(.top, 4) }
        }
    }

    /// The request that named the task (display text), else the answer's start.
    private var title: String {
        let text = AppModel.oneLine(result.request?.displayPreview ?? result.response.preview)
        return text.isEmpty ? "Answer" : text
    }

    /// "Claude · Work · Claude Desktop · prompt-relay · Fix login"
    private var meta: String {
        var parts = [model.agentLine(provider: result.provider, profile: result.profileKey, host: result.host), model.projectName(of: result)]
        if let conversation = result.conversation.title.map(AppModel.oneLine), !conversation.isEmpty, conversation != title {
            parts.append(conversation)
        }
        return parts.joined(separator: " · ")
    }

    private var stateTag: String? {
        switch result.completion {
        case .answerBackgroundRunning: return "work was running"
        case .waitingBackground: return "completion unknown · not finished"
        default: return nil
        }
    }
}

/// "All agents" or one provider · profile (Inbox).
struct ProfileFilterMenu: View {
    let model: AppModel

    var body: some View {
        let profiles = model.knownProfiles
        if profiles.count > 1 {
            Menu {
                Button("All Agents") { model.inboxProfile = nil }
                Divider()
                ForEach(profiles) { key in
                    Button(model.profileTitle(key)) { model.inboxProfile = key }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(model.inboxProfile.map(model.profileTitle) ?? "All Agents").lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Island.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Agent filter")
        }
    }
}

// MARK: - Quick Switcher

/// ⌘K: type a few letters, press Return. Searches what is already loaded
/// (agents, profiles, projects, conversations, results); no second History.
struct QuickSwitcherView: View {
    let model: AppModel
    let presentation: NotchPresentation
    @FocusState private var focused: Bool
    @State private var highlighted = 0

    var body: some View {
        let items = model.switcherItems()
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Island.tertiary)
                TextField("Go to", text: Binding(get: { model.switcherQuery }, set: { model.switcherQuery = $0; highlighted = 0 }),
                          prompt: Text("Agent, project, conversation or result").foregroundStyle(Island.tertiary))
                    .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Island.primary)
                    .focused($focused)
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(items.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .onKeyPress(.return) {
                        guard items.indices.contains(highlighted) else { return .ignored }
                        model.activate(items[highlighted]); return .handled
                    }
                    .accessibilityLabel("Go to")
                Text("↑↓ ↩").font(.system(size: 11)).foregroundStyle(Island.tertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Island.rowRadius, style: .continuous).fill(Island.card))
            Picker("Scope", selection: Binding(get: { model.switcherScope }, set: { model.switcherScope = $0; highlighted = 0 })) {
                ForEach(AppModel.SwitcherScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if items.isEmpty {
                Text(model.switcherQuery.isEmpty ? "Nothing captured yet." : "Nothing matches “\(model.switcherQuery)”.")
                    .font(.system(size: 12)).foregroundStyle(Island.secondary).padding(.vertical, 8)
            } else {
                ScrollViewReader { proxy in
                    BoundedScroll(maxHeight: presentation.listHeight(chrome: 96)) {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                SwitcherRow(item: item, highlighted: i == highlighted) { model.activate(item) }
                                    .id(i)
                                    .onHover { if $0 { highlighted = i } }
                            }
                        }
                        .padding(4)
                    }
                    .background(RoundedRectangle(cornerRadius: Island.cardRadius).fill(Island.card))
                    .onChange(of: highlighted) { _, new in proxy.scrollTo(new) }
                }
            }
        }
        .islandPadding(presentation)
        .onAppear { highlighted = 0; focused = true }
    }
}

struct SwitcherRow: View {
    let item: AppModel.SwitcherItem
    let highlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Island.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Island.primary).lineLimit(1)
                    Text(item.subtitle).font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if item.unread { Circle().fill(Island.success).frame(width: 6, height: 6).accessibilityLabel("Unread") }
                Text(item.kind.rawValue).font(.system(size: 11)).foregroundStyle(Island.tertiary)
            }
            .padding(.horizontal, 8).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: Island.rowRadius).fill(highlighted ? Island.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.kind.rawValue): \(item.title), \(item.subtitle)")
    }

    private var symbol: String {
        switch item.kind {
        case .latest: return "sparkle"
        case .unread: return "tray"
        case .agent: return "person.crop.square"
        case .project: return "folder"
        case .conversation: return "bubble.left.and.bubble.right"
        case .result: return "text.alignleft"
        }
    }
}

// MARK: - By Agent (Project and Session)

/// Left: provider · profile rows. Right: that profile's conversations,
/// under small project headers — Provider → Profile → Project →
/// Conversations in two columns instead of a four-level tree.
struct AgentWorkspaceColumns: View {
    let model: AppModel
    let height: CGFloat

    var body: some View {
        let groups = model.agentGroups
        let current = groups.first { $0.key == model.browsingProfile } ?? groups.first
        HStack(alignment: .top, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups) { group in
                        Button { model.browsingProfile = group.key } label: {
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(model.profileName(group.key)).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(group.key.provider.title)
                                        .font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1)
                                }
                                Spacer(minLength: 2)
                                let fresh = model.newAnswerCount(inProfile: group.key)
                                if fresh > 0 {
                                    Text("\(fresh) new").font(.system(size: 11, weight: .medium)).foregroundStyle(Island.success)
                                        .accessibilityLabel("\(fresh) new answers")
                                }
                                Text("\(group.sessionCount)").font(.system(size: 11)).foregroundStyle(Island.tertiary)
                            }
                            .foregroundStyle(Island.primary)
                            .padding(.horizontal, 9).frame(height: 38)
                            .background(RoundedRectangle(cornerRadius: Island.rowRadius).fill(group.key == current?.key ? Island.selected : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(model.profileTitle(group.key)), \(group.sessionCount) conversations")
                        .islandHelp(model.profileExplanation(group.key))
                    }
                }
                .padding(5)
            }
            .frame(width: 180, height: height)
            .background(RoundedRectangle(cornerRadius: Island.cardRadius).fill(Island.card))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let current {
                        ForEach(current.projects) { project in
                            HStack(spacing: 4) {
                                Image(systemName: "folder").font(.system(size: 9.5)).foregroundStyle(Island.tertiary)
                                Text(project.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Island.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 9).padding(.top, 6).padding(.bottom, 1)
                            ForEach(project.sessions) { session in ConversationRow(model: model, session: session) }
                        }
                    } else {
                        Text("No conversations captured yet.").font(.system(size: 11.5)).foregroundStyle(Island.tertiary).padding(10)
                    }
                }
                .padding(5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: Island.cardRadius).fill(Island.card))
        }
    }
}

// MARK: - In-island shortcuts

/// Keys that work on every view of the open island (the panel has the
/// keyboard only while it is open; nothing here is global):
/// ⌘K Go To (Quick Switcher) · ⌘I Results Inbox · ⌘J next unread result.
/// ⇧⌘C / ⌥⌘C (copies), ⌘[ (Back), ⌘, (Settings) and Esc stay as before.
struct WorkspaceShortcuts: View {
    let model: AppModel

    var body: some View {
        ZStack {
            Button("Go To") { model.navigate(to: model.route == .switcher ? .home : .switcher) }
                .keyboardShortcut("k", modifiers: .command)
            Button("Results Inbox") { model.navigate(to: .inbox) }
                .keyboardShortcut("i", modifiers: .command)
            Button("Next Unread Result") { model.openNextUnread() }
                .keyboardShortcut("j", modifiers: .command)
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Project and Session: By Project / By Agent as a small menu, so the agent
/// filter keeps its room in the narrow island.
struct WorkspaceModeMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            ForEach(AppModel.WorkspaceMode.allCases, id: \.self) { mode in
                Button { model.workspaceMode = mode } label: {
                    if mode == model.workspaceMode { Label(mode.rawValue, systemImage: "checkmark") } else { Text(mode.rawValue) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(model.workspaceMode.rawValue).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Island.primary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Group conversations: \(model.workspaceMode.rawValue)")
        .islandHelp("Group conversations by project or by agent profile")
    }
}

/// Why a result is under Needs attention (one line, no blame).
struct AttentionNote: View {
    var body: some View {
        Text("The agent stopped while its own work (tests, builds) was still running, and nothing followed. Its last message is kept; whether the task finished is unknown.")
            .font(.system(size: 11)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9).padding(.bottom, 4)
    }
}
