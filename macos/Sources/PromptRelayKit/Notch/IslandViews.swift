import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// The one interface of Prompt Relay, inside the island. Home answers four
// questions at a glance: which project, what was asked, what Claude
// answered, which button copies it. Projects, Recent Copies, History,
// Import, Settings and the Full Report open inside the same island and lead
// Back to Home. The band level with the camera stays pure black; content
// sits on deep graphite cards. One white accent: Copy Response.

/// The island's palette and metrics.
enum Island {
    static let primary = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.70)
    static let tertiary = Color.white.opacity(0.52)
    /// Cards: deep graphite on the black island.
    static let card = Color(white: 0.115)
    static let cardRaised = Color(white: 0.16)
    static let code = Color(white: 0.075)
    static let control = Color(white: 0.19)
    static let hover = Color.white.opacity(0.07)
    static let selected = Color.white.opacity(0.11)
    static let hairline = Color.white.opacity(0.08)
    /// The one restrained accent for meaningful states (new, capture on).
    static let accent = Color(red: 0.45, green: 0.85, blue: 0.72)
    static let warning = Color(red: 1.0, green: 0.74, blue: 0.38)
    static let error = Color(red: 1.0, green: 0.47, blue: 0.43)
    static let cardRadius: CGFloat = 14
    /// Inner padding of a card: its text never runs into the rounded edge.
    static let cardPadding = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
}

/// One spacing rule for the open island. The notch outline's sides stand
/// `edge` points in from the window (its top corners flare out above them),
/// so content is measured from that visible side: `inset` from it
/// horizontally, `bottom` above the rounded bottom edge. Short displays get
/// slightly tighter values so more of the report stays visible.
struct IslandMetrics: Equatable {
    var edge: CGFloat
    var inset: CGFloat
    var top: CGFloat
    var bottom: CGFloat
    /// Between the blocks of a view (header, Task, Response, actions, footer).
    var spacing: CGFloat
    /// A short display: one line of the task, smaller image cards.
    var compact = false
    /// Window edge → content.
    var leading: CGFloat { edge + inset }

    @MainActor static func of(_ p: NotchPresentation) -> IslandMetrics {
        make(width: p.islandWidth, maxContentHeight: p.maxContentHeight, floating: p.isFloating, peek: p.surface == .peek)
    }

    static func make(width: CGFloat, maxContentHeight: CGFloat, floating: Bool, peek: Bool) -> IslandMetrics {
        let edge = floating ? 0 : NotchRootView.expandedTopRadius
        if peek { return IslandMetrics(edge: edge, inset: 20, top: 4, bottom: 18, spacing: 10) }
        let roomy = maxContentHeight >= 460
        return IslandMetrics(edge: edge, inset: width >= 520 ? 24 : 22, top: roomy ? 6 : 4,
                             bottom: roomy ? 22 : 18, spacing: roomy ? 12 : 10, compact: !roomy)
    }
}

/// Frames of the island's main blocks and controls, in its own coordinate
/// space: layout regression tests check them against the island outline.
/// Debug builds only. Recorded after layout through a sink in the
/// environment (a preference here was "bound … multiple times per frame"
/// while the island resized).
struct IslandFrameSinkKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String, CGRect) -> Void)? = nil
}

extension EnvironmentValues {
    var islandFrameSink: (@MainActor (String, CGRect) -> Void)? {
        get { self[IslandFrameSinkKey.self] }
        set { self[IslandFrameSinkKey.self] = newValue }
    }
}

struct IslandFrameRecorder: ViewModifier {
    let id: String
    @Environment(\.islandFrameSink) private var sink

    func body(content: Content) -> some View {
        if let sink {
            content.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(NotchRootView.space)) }) { sink(id, $0) }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder func islandFrame(_ id: String) -> some View {
        #if DEBUG
        modifier(IslandFrameRecorder(id: id))
        #else
        self
        #endif
    }

    /// The island's content padding (see `IslandMetrics`).
    @MainActor func islandPadding(_ presentation: NotchPresentation, horizontal: Bool = true) -> some View {
        let m = IslandMetrics.of(presentation)
        return padding(.horizontal, horizontal ? m.leading : 0).padding(.top, m.top).padding(.bottom, m.bottom)
    }
}

// MARK: - Expanded island

struct IslandContent: View {
    let model: AppModel
    let presentation: NotchPresentation
    let interaction: NotchInteraction
    let actions: SurfaceActions
    let settings: NotchSettings?
    let notifier: ReadyNotifier?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IslandBand(presentation: presentation) {
                HStack(spacing: 7) {
                    if presentation.showsMascot {
                        MascotView(state: presentation.mascot, size: MascotView.size(notchHeight: presentation.notchSize.height), reduceMotion: presentation.reduceMotion)
                            .islandFrame("band.mascot")
                    }
                    if model.route != .home { BackButton(model: model) }
                }
            } trailing: {
                if model.route == .home {
                    BandStatus(model: model)
                } else {
                    Text(model.route.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Island.secondary)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            Group {
                switch model.route {
                case .home: DetailsView(model: model, presentation: presentation, actions: actions)
                case .projects: SessionSwitcherView(model: model, presentation: presentation)
                case .capture: ProjectsView(model: model, presentation: presentation)
                case .activity: ActivityView(model: model, presentation: presentation)
                case .mockup: MockupStatesView(model: model, presentation: presentation)
                case .clipboard: ClipboardImagesView(model: model, presentation: presentation)
                case .copies: CopiesView(model: model, presentation: presentation)
                case .history: HistoryView(model: model, presentation: presentation)
                case .importReport: ImportView(model: model, presentation: presentation)
                case .settings: IslandSettingsView(model: model, presentation: presentation, settings: settings, notifier: notifier,
                                                   actions: actions)
                case .reader: ReaderView(model: model, presentation: presentation)
                }
            }
            .transition(.opacity)
        }
        .animation(presentation.reduceMotion ? nil : .easeOut(duration: 0.18), value: model.route)
    }
}

/// The row level with the camera housing: one control left, one fact right,
/// both kept clear of the housing and of the top corner flares.
struct IslandBand<Leading: View, Trailing: View>: View {
    let presentation: NotchPresentation
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        // Same left edge as the content below; clear of the camera housing.
        let leadingInset = IslandMetrics.of(presentation).leading
        let gap: CGFloat = presentation.notchSize.width > 0 ? 12 : 0
        let side = max(0, (presentation.islandWidth - presentation.notchSize.width) / 2 - leadingInset - gap)
        HStack(spacing: 0) {
            leading.frame(width: side, alignment: .leading)
            Spacer(minLength: 0)
            trailing.frame(width: side, alignment: .trailing)
        }
        .padding(.horizontal, leadingInset)
        .frame(height: presentation.notchSize.height)
    }
}

struct ProjectPicker: View {
    let model: AppModel

    var body: some View {
        Button { model.navigate(to: .projects) } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Island.primary)
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Island.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Project: \(title). Choose project")
        .help("Choose a project or turn capture on and off")
    }

    private var title: String {
        if let report = model.selectedImport { return report.projectName ?? "Cloud import" }
        return model.selectedProject.map(Wording.projectName) ?? "Prompt Relay"
    }
}

struct BackButton: View {
    let model: AppModel

    var body: some View {
        Button { model.goBack() } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                Text(model.backRoute == .home ? "Back" : model.backRoute.title).font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Island.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("[", modifiers: .command)
        .accessibilityLabel("Back")
        .help("Back (Esc)")
    }
}

/// "New answer" (accent) while an answer is unseen, else how long ago.
struct BandStatus: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 5) {
            if model.projects.error != nil, model.projects.value == nil {
                Circle().fill(Island.error).frame(width: 6, height: 6)
                Text("Unavailable").foregroundStyle(Island.secondary)
            } else if model.hasUnseenAnswer {
                Circle().fill(Island.accent).frame(width: 6, height: 6)
                Text("New answer").foregroundStyle(Island.accent)
            } else if let at = ReportFacts(model: model).at {
                Text(Wording.relative(at)).foregroundStyle(Island.tertiary)
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The facts Home shows, for local and imported reports alike

/// Reads the current report from the model: source, task, preview, size.
/// Only facts; nothing is summarized or inferred.
@MainActor
struct ReportFacts {
    let model: AppModel

    var source: ReportSource? {
        if model.selectedImport != nil { return .cloudManualImport }
        return model.selectedTurn == nil ? nil : .localClaudeCode
    }

    var at: String? {
        if let report = model.selectedImport { return report.importedAt }
        guard let turn = model.selectedTurn else { return nil }
        return turn.finalResponse?.receivedAt ?? turn.request?.receivedAt
    }

    enum TaskText {
        case linked(String), inferred(String), supplied(String), unavailable(String)
        /// Claude Code started the turn itself; the user's earlier request, if any.
        case automated(earlier: String?, turn: Int?)
        /// Automated blocks mixed with other text: who wrote it is not known.
        case unknownSource(String)
    }

    /// The request was pasted into Claude Code (shown without its wrapper).
    var taskWasPasted: Bool {
        guard model.selectedImport == nil, let request = model.selectedTurn?.request else { return false }
        return Wording.requestForDisplay(request.preview).pasted
    }

    var task: TaskText {
        if let report = model.selectedImport {
            return report.task.map(TaskText.supplied) ?? .unavailable("not supplied when importing")
        }
        guard let turn = model.selectedTurn else { return .unavailable("") }
        switch turn.requestOrigin {
        case .automated?:
            return .automated(earlier: turn.earlierUserRequest.map { Wording.requestForDisplay($0.preview).text },
                              turn: turn.earlierUserRequest?.turn)
        case .unknown? where turn.request != nil:
            return .unknownSource(Wording.requestForDisplay(turn.request!.preview).text)
        default: break
        }
        switch (turn.link, turn.request) {
        case (.promptID, let request?): return .linked(Wording.requestForDisplay(request.preview).text)
        case (_, let request?): return .inferred(Wording.requestForDisplay(request.preview).text)
        default: return .unavailable((Wording.link(turn.link) ?? "not captured").lowercased())
        }
    }

    /// The text to preview: the full text once loaded (imports always are).
    var text: String? {
        if let report = model.selectedImport { return report.text }
        guard let turn = model.selectedTurn else { return nil }
        return model.selectedResponseText ?? turn.finalResponse?.preview
    }

    var characters: Int? {
        if let report = model.selectedImport { return report.text.unicodeScalars.count }
        return model.selectedTurn?.finalResponse?.charCount
    }

    /// Why there is nothing to copy, or nil.
    var blocker: String? {
        if model.selectedImport != nil { return nil }
        guard let turn = model.selectedTurn else { return "No answer selected." }
        return AppModel.copyBlocker(for: turn)
    }
}

// MARK: - Home

struct HomeView: View {
    let model: AppModel
    let presentation: NotchPresentation
    let actions: SurfaceActions
    @State private var taskExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            content
            HomeFooter(model: model, actions: actions).islandFrame("home.footer")
        }
        .islandPadding(presentation)
    }

    @ViewBuilder
    private var content: some View {
        let facts = ReportFacts(model: model)
        if let error = model.projects.error, model.projects.value == nil, model.selectedImport == nil {
            MessageCard(title: "Prompt Relay can't read its history", detail: error.detail,
                        symbol: "exclamationmark.triangle", tint: Island.warning,
                        action: ("Diagnostics", { model.navigate(to: .settings) }))
        } else if facts.source == nil {
            if model.projects.value?.isEmpty == false { ProjectPicker(model: model) }
            if model.projects.value?.isEmpty == true {
                MessageCard(title: "Choose a project to capture",
                            detail: "Prompt Relay keeps Claude Code's final answers for projects you turn on. Nothing is captured until you do.",
                            symbol: "folder.badge.plus", tint: Island.accent,
                            action: ("Choose Project…", { model.navigate(to: .projects) }))
            } else {
                MessageCard(title: "No answer yet",
                            detail: "When Claude Code finishes in a captured project, its answer appears here.",
                            symbol: "text.bubble", tint: Island.secondary, action: nil)
            }
        } else {
            HStack(spacing: 8) {
                ProjectPicker(model: model)
                Spacer(minLength: 8)
                SourceLine(model: model, facts: facts)
            }
            TaskCard(facts: facts, expanded: $taskExpanded, lines: IslandMetrics.of(presentation).compact ? 1 : 2)
                .islandFrame("card.task")
            ResponseCard(model: model, presentation: presentation, facts: facts) { model.navigate(to: .reader) }
            AttachmentStrip(model: model, compact: IslandMetrics.of(presentation).compact)
            HStack(spacing: 8) {
                CopyActions(model: model, blocked: facts.blocker != nil)
                Spacer(minLength: 0)
                AttachButton(model: model)
            }
            .islandFrame("home.actions")
            CopyFeedbackLine(model: model)
        }
    }
}

/// "Claude Code · this Mac · 4 min ago", or the import's provenance, and
/// a warning when capture is off for the project.
struct SourceLine: View {
    let model: AppModel
    let facts: ReportFacts

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: facts.source == .cloudManualImport ? "icloud.and.arrow.down" : "laptopcomputer")
                .font(.system(size: 10, weight: .semibold))
            Text(facts.source?.label ?? "")
            if facts.source == .localClaudeCode, let project = model.selectedProject, !project.captureEnabled {
                Text("· capture off")
                    .foregroundStyle(Island.warning)
                    .help("New answers from this project are not recorded. Turn capture on in Projects.")
            }
            if model.selectedImport == nil, let turn = model.selectedTurn, turn.status == .stopReceivedBackgroundTasksPending {
                // A fact about the Stop, not about now: the work may have ended since.
                Text("· background work at Stop").foregroundStyle(Island.warning)
                    .help("When Claude stopped, background tasks were still running. Monitors (such as an artifact's live updates) are not counted.")
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Island.tertiary)
        .lineLimit(1)
    }
}

struct TaskCard: View {
    let facts: ReportFacts
    @Binding var expanded: Bool
    var lines = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Caption("Task")
                switch facts.task {
                case .inferred: Tag("inferred from order", tint: Island.warning)
                case .supplied: Tag("entered by you", tint: Island.secondary)
                case .automated: Tag("started automatically", tint: Island.warning)
                case .unknownSource: Tag("source not established", tint: Island.warning)
                default: EmptyView()
                }
                if facts.taskWasPasted { Tag("pasted text", tint: Island.secondary) }
                Spacer(minLength: 0)
                if canExpand {
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                            .frame(width: 20, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Island.tertiary)
                    .accessibilityLabel(expanded ? "Show less of the task" : "Show the whole task")
                }
            }
            switch facts.task {
            case .automated(let earlier, let turn):
                Text("Claude Code started this turn itself; you did not write its message.")
                    .font(.system(size: 12)).foregroundStyle(Island.tertiary)
                if let earlier {
                    Text("Your request before it (turn \(turn ?? 0)): \(earlier.trimmingCharacters(in: .whitespacesAndNewlines))")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Island.secondary)
                        .lineLimit(expanded ? 12 : lines)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            case .linked(let text), .inferred(let text), .supplied(let text), .unknownSource(let text):
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Island.secondary)
                    .lineLimit(expanded ? 12 : lines)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            case .unavailable(let why):
                Text(why.isEmpty ? "Unavailable" : "Unavailable: \(why)").font(.system(size: 12)).foregroundStyle(Island.tertiary)
            }
        }
        .padding(Island.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).fill(Island.card))
        .accessibilityElement(children: .contain)
    }

    private var canExpand: Bool {
        switch facts.task {
        case .linked(let t), .inferred(let t), .supplied(let t), .unknownSource(let t): return t.count > 110 || t.contains("\n")
        case .automated(let t?, _): return t.count > 80 || t.contains("\n")
        case .automated, .unavailable: return false
        }
    }
}

/// Claude's answer, rendered from Markdown, scrolling inside the card: the
/// pointer over it scrolls only the answer. A different answer starts at its
/// top again. View Full Report opens the reader; every copy uses the
/// original text, never what is drawn here.
struct ResponseCard: View {
    let model: AppModel
    let presentation: NotchPresentation
    let facts: ReportFacts
    /// Height of the answer's own scroll area (Details computes it).
    var scrollHeight: CGFloat? = nil
    let openFull: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Caption("Response")
                if let n = facts.characters, n > 0 {
                    Text("\(n.formatted()) characters").font(.system(size: 10.5)).foregroundStyle(Island.tertiary)
                }
                Spacer(minLength: 0)
                if model.selectedImport == nil, let turn = model.selectedTurn { AnswerStepper(model: model, turn: turn) }
            }
            if let blocker = facts.blocker {
                Text(model.selectedTurn?.error?.message ?? blocker)
                    .font(.system(size: 12.5))
                    .foregroundStyle(model.selectedTurn?.status == .apiError ? Island.error : Island.secondary)
            } else {
                let text = facts.text ?? ""
                BoundedScroll(maxHeight: scrollHeight ?? Self.scrollHeight(presentation, hasAttachments: !model.attachments(for: model.currentRef).isEmpty || model.attachmentMessage != nil)) {
                    MarkdownBlocksView(blocks: Markdown.blocks(text), codeLineLimit: nil, fontSize: 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 6)   // room for the scroller
                        .textSelection(.enabled)
                }
                .id(Self.scrollIdentity(ref: model.currentRef, text: text))
                .islandFrame("response.scroll")
                .accessibilityLabel("Response")
                Button(action: openFull) {
                    HStack(spacing: 4) {
                        Text("View Full Report").font(.system(size: 11.5, weight: .medium))
                        Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                    }
                    .foregroundStyle(Island.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .islandFrame("response.full")
                .accessibilityLabel("View Full Report")
                .help("Read the complete report with more room")
            }
        }
        .padding(Island.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).fill(Island.card))
        .islandFrame("card.response")
    }

    /// Height of the answer's scroll area: what Home has left on this display
    /// after its other rows (measured: about 290 pt, plus a line of copy
    /// feedback and the image strip when shown), within a comfortable range.
    @MainActor static func scrollHeight(_ presentation: NotchPresentation, hasAttachments: Bool) -> CGFloat {
        let compact = IslandMetrics.of(presentation).compact
        let chrome: CGFloat = (compact ? 290 : 322) + (hasAttachments ? AttachmentStrip.rowHeight(compact: compact) : 0)
        return min(max(presentation.maxContentHeight - chrome, 60), 260)
    }

    /// Changes with the answer shown, so a different answer starts at its top
    /// (and again once its full text replaces the preview).
    static func scrollIdentity(ref: ReportRef?, text: String) -> String {
        "\(ref.map { String(describing: $0) } ?? "none")#\(text.utf8.count)"
    }
}

/// The first blocks of the answer, clipped to a few lines with a fade. Display only.
struct ResponsePreview: View {
    let text: String
    let lines: Int

    var body: some View {
        let blocks = Array(Markdown.blocks(String(text.prefix(1800))).prefix(6))
        MarkdownBlocksView(blocks: blocks, codeLineLimit: 4, fontSize: 13)
            .frame(maxWidth: .infinity, maxHeight: CGFloat(lines) * 19, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.75),
                                         .init(color: .black.opacity(0.2), location: 1)],
                                 startPoint: .top, endPoint: .bottom))
    }
}

/// Copy Response (the one white accent) and Copy for ChatGPT.
struct CopyActions: View {
    let model: AppModel
    let blocked: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.copySelectedResponse() }
            } label: {
                Label(copied(.response) ? "Copied" : "Copy Response",
                      systemImage: copied(.response) ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(IslandPillStyle(prominent: true))
            .disabled(blocked)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .accessibilityLabel("Copy Response")
            .accessibilityHint("Copies Claude's complete final answer, unchanged")
            .help("Copy Claude's complete answer, exactly as written (⇧⌘C)")

            Button {
                Task { await model.copySelectedContext() }
            } label: {
                Label(copied(.context) ? "Copied" : "Copy for ChatGPT",
                      systemImage: copied(.context) ? "checkmark" : "checklist")
            }
            .buttonStyle(IslandPillStyle(prominent: false))
            .disabled(blocked)
            .keyboardShortcut("c", modifiers: [.command, .option])
            .accessibilityLabel("Copy for ChatGPT")
            .help("Copy the task, the complete answer, the observed work and the attachment list, with a request for an independent review (⌥⌘C)")
        }
        .animation(.easeOut(duration: 0.15), value: model.copyFeedback)
    }

    private func copied(_ kind: AppModel.CopyKind) -> Bool {
        if case .copied(kind, _) = model.copyFeedback { return true }
        return false
    }
}

/// One line after a copy: what exactly went to the clipboard.
struct CopyFeedbackLine: View {
    let model: AppModel

    var body: some View {
        Group {
            switch model.copyFeedback {
            case .copied(.response, let n): line("Copied the complete response: \(n.formatted()) characters.", Island.accent)
            case .copied(.context, let n): line("Copied for ChatGPT: \(n.formatted()) characters.", Island.accent)
            case .copied(.image, _): line("Copied the image.", Island.accent)
            case .copied(.files, let n): line(n == 1 ? "Copied the file." : "Copied \(n) files.", Island.accent)
            case .copied(.responseWithImages, let n):
                line("Copied \(n.formatted()) characters and the images. Check that the images arrive where you paste.", Island.accent)
            case .failed(let reason): line(reason, Island.error)
            default: EmptyView()
            }
        }
        .transition(.opacity)
    }

    private func line(_ text: String, _ tint: Color) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(tint).lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }
}

/// Copies, History and Import on the left; Settings and Quit in the corner.
struct HomeFooter: View {
    let model: AppModel
    let actions: SurfaceActions

    var body: some View {
        HStack(spacing: 6) {
            FooterLink(title: "Copies", symbol: "clock.arrow.circlepath", help: "Your last five copies") { model.navigate(to: .copies) }
            FooterLink(title: "History", symbol: "tray.full", help: "Every captured and imported report, with search") {
                model.navigate(to: .history)
            }
            FooterLink(title: "Import", symbol: "square.and.arrow.down", help: "Import a report from a Claude Code cloud session") {
                model.navigate(to: .importReport)
            }
            Spacer(minLength: 4)
            Button { model.navigate(to: .settings) } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 26)
                    .overlay(alignment: .topTrailing) {
                        if !AppBuild.otherBuildsRunning().isEmpty {
                            Circle().fill(Island.warning).frame(width: 5, height: 5).offset(x: -4, y: 4)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityLabel("Settings")
            .help("Settings (⌘,)")
            QuitButton(actions: actions)
        }
        .foregroundStyle(Island.secondary)
    }
}

struct FooterLink: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 9).frame(height: 26)
                .background(Capsule().fill(hovering ? Island.cardRaised : Island.card))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Quit asks once more: the first click turns it into "Quit?" for a few seconds.
struct QuitButton: View {
    let actions: SurfaceActions
    @State private var armed = false

    var body: some View {
        Button {
            if armed { actions.quit() } else {
                armed = true
                Task { try? await Task.sleep(nanoseconds: 3_000_000_000); armed = false }
            }
        } label: {
            Group {
                if armed {
                    Text("Quit?").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Island.error).padding(.horizontal, 6)
                } else {
                    Image(systemName: "power").font(.system(size: 12, weight: .medium))
                }
            }
            .frame(minWidth: 28, minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(armed ? "Confirm: quit Prompt Relay" : "Quit Prompt Relay")
        .help("Quit Prompt Relay")
        .animation(.easeOut(duration: 0.15), value: armed)
    }
}

// MARK: - Quick Peek

struct PeekContent: View {
    let model: AppModel
    let presentation: NotchPresentation
    let interaction: NotchInteraction

    var body: some View {
        let facts = ReportFacts(model: model)
        VStack(alignment: .leading, spacing: 0) {
            IslandBand(presentation: presentation) {
                if presentation.showsMascot {
                    MascotView(state: presentation.mascot, size: MascotView.size(notchHeight: presentation.notchSize.height), reduceMotion: presentation.reduceMotion)
                            .islandFrame("band.mascot")
                }
            } trailing: {
                BandStatus(model: model)
            }
            VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
                if facts.source == nil {
                    HStack(alignment: .center) {
                        Text(model.projects.value?.isEmpty == true ? "Click to choose a project to capture." : "No answer yet.")
                            .font(.system(size: 12.5)).foregroundStyle(Island.secondary)
                        Spacer()
                        expandButton
                    }
                } else {
                    // 1. project · session · status and time
                    HStack(spacing: 5) {
                        Text(model.selectedImport.map { $0.projectName ?? "Cloud import" }
                             ?? model.selectedProject.map(Wording.projectName) ?? "Prompt Relay")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Island.primary)
                            .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                        if let session = model.selectedImport == nil ? model.selectedSession.map(Wording.sessionTitle) : "imported" {
                            Text("· " + session).font(.system(size: 12)).foregroundStyle(Island.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(statusLine).font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1).layoutPriority(1)
                    }
                    // 2. the task, 3. the start of Claude's own answer
                    switch facts.task {
                    case .linked(let task), .inferred(let task), .supplied(let task):
                        Text(task.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 12)).foregroundStyle(Island.primary).lineLimit(1)
                    case .unknownSource(let task):
                        Text("Source not established · " + task.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 12)).foregroundStyle(Island.primary).lineLimit(1)
                    case .automated(let earlier, _):
                        Text(earlier.map { "Started automatically · after: " + $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                             ?? "Started automatically by Claude Code")
                            .font(.system(size: 12)).foregroundStyle(Island.primary).lineLimit(1)
                    case .unavailable: EmptyView()
                    }
                    if let blocker = facts.blocker {
                        Text(model.selectedTurn?.error?.message ?? blocker).font(.system(size: 11.5)).foregroundStyle(Island.secondary)
                            .lineLimit(1)
                    } else {
                        Text(Self.firstLine(facts.text ?? "")).font(.system(size: 11.5)).foregroundStyle(Island.secondary)
                            .lineLimit(1).islandFrame("peek.preview")
                    }
                    // 4. facts and materials, one line each at most
                    let summary = model.materialSummary(for: model.currentRef)
                    if model.selectedImport == nil || !summary.isEmpty {
                        HStack(spacing: 5) {
                            if model.selectedImport == nil { ObservedChips(observed: model.selectedTurn?.observed) }
                            if !summary.isEmpty {
                                Text(summary.line).font(.system(size: 10.5)).foregroundStyle(Island.secondary).lineLimit(1)
                            }
                            if summary.needsVisualReview {
                                Text("Visual review required").font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color(red: 0.73, green: 0.65, blue: 1)).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    // 5. the two copies and Details
                    HStack(spacing: 8) {
                        CopyActions(model: model, blocked: facts.blocker != nil)
                        Spacer(minLength: 0)
                        detailsButton
                    }
                    .islandFrame("peek.actions")
                    CopyFeedbackLine(model: model)
                }
            }
            .islandPadding(presentation)
        }
    }

    /// The status in words; the band already shows how long ago.
    private var statusLine: String {
        if model.selectedImport != nil { return "Imported" }
        guard let turn = model.selectedTurn else { return "" }
        switch turn.status {
        case .awaitingResponse: return "Working"
        case .apiError: return "API error"
        case .stopReceivedBackgroundTasksPending: return "Stopped · background work"
        default: return "Stopped"
        }
    }

    /// The first non-empty line of the answer, without Markdown markers. Display only.
    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !$0.hasPrefix("```") } ?? ""
        return line.replacingOccurrences(of: #"^[#>*\-\s]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
    }

    private var detailsButton: some View {
        Button { interaction.focus() } label: {
            HStack(spacing: 4) {
                Text("Details")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 11).frame(height: 28)
            .background(Capsule().fill(Island.control))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Island.primary)
        .accessibilityLabel("Details")
        .help("Open Details: the whole answer, observed work, attachments, sessions and settings")
    }

    private var expandButton: some View {
        Button { interaction.focus() } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Island.control))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Island.primary)
        .accessibilityLabel("Expand Prompt Relay")
        .help("Show the task, the full report, history and settings")
    }
}

// MARK: - Shared pieces

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Island.tertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

struct Tag: View {
    let text: String
    let tint: Color
    init(_ text: String, tint: Color) { self.text = text; self.tint = tint }

    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(tint)
            .padding(.horizontal, 6).frame(height: 16)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

struct MessageCard: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let action: (String, () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(tint).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Island.primary)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Island.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let action {
                Button(action.0, action: action.1).buttonStyle(IslandPillStyle(prominent: false)).padding(.leading, 30)
            }
        }
        .padding(Island.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).fill(Island.card))
    }
}

/// White capsule (the main action) or a quiet graphite one.
struct IslandPillStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: prominent ? .semibold : .medium))
            .padding(.horizontal, 14).frame(height: 30)
            .foregroundStyle(prominent ? Color.black : Island.primary)
            .background(Capsule().fill(prominent ? Color.white.opacity(enabled ? 1 : 0.3) : Island.control))
            .opacity(configuration.isPressed ? 0.75 : (enabled || prominent ? 1 : 0.45))
            .contentShape(Capsule())
            .fixedSize()
    }
}

/// ‹ 2/5 ›: earlier answers of the selected session.
struct AnswerStepper: View {
    let model: AppModel
    let turn: Turn

    var body: some View {
        let answers = NotchRootView.answerTurns(model)
        if answers.count > 1, let index = answers.firstIndex(of: turn.index) {
            let position = index + 1
            HStack(spacing: 1) {
                step("chevron.left", label: "Older answer", enabled: position < answers.count) { NotchRootView.step(model, by: 1) }
                Text("\(position)/\(answers.count)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Island.tertiary)
                step("chevron.right", label: "Newer answer", enabled: position > 1) { NotchRootView.step(model, by: -1) }
            }
        }
    }

    private func step(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(enabled ? 0.8 : 0.25))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// Rows: a soft highlight on hover, no blue selection.
struct IslandRowStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, selected: selected)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Island.selected : (hovering || configuration.isPressed ? Island.hover : .clear)))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

/// A small switch in the island's colors (accent when on, no system blue);
/// still a Toggle for keyboard and VoiceOver.
struct IslandSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                configuration.label
                Spacer(minLength: 0)
                Capsule()
                    .fill(configuration.isOn ? Island.accent : Color.white.opacity(0.18))
                    .frame(width: 30, height: 18)
                    .overlay(Circle().fill(Color.white).frame(width: 14, height: 14).offset(x: configuration.isOn ? 6 : -6))
                    .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// A scroll view as tall as its content, up to `maxHeight`; longer content
/// scrolls inside the island and fades at the bottom edge.
struct BoundedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        // The content's height is read after layout (no preference: a
        // preference that changes the frame it measures updated several
        // times per frame). The scroller does not depend on the measurement:
        // with legacy scrollers (a mouse attached) showing it only when
        // "too tall" narrowed the content, which changed its height again.
        ScrollView {
            content.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { new in
                if abs(new - height) >= 0.5 { height = new }
            }
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(height, 1), maxHeight))
        .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                     .init(color: .black, location: height > maxHeight ? 0.9 : 1),
                                     .init(color: height > maxHeight ? .clear : .black, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }
}

/// A grouped list card: rows separated by hairlines, like a macOS form.
struct GroupCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).fill(Island.card))
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Island.hairline).frame(height: 1).padding(.horizontal, 12) }
}

// MARK: - Attachments

struct AttachButton: View {
    let model: AppModel

    var body: some View {
        Button { model.chooseAttachments() } label: {
            Image(systemName: "paperclip").font(.system(size: 12, weight: .medium))
                .frame(width: 30, height: 30).background(Circle().fill(Island.control))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Island.primary)
        .disabled(model.reportStore == nil || model.currentRef == nil || model.isPresentingSystemDialog)
        .islandFrame("home.attach")
        .accessibilityLabel("Add images to this report")
        .help("Add screenshots or other images to this report. They are copied into Prompt Relay's private folder.")
    }
}

/// The report's images as compact file cards (thumbnail, name, type and
/// size, actions, ×), in one row that scrolls sideways: any number of images
/// adds one fixed-height row to Home. Images are never inside the text.
struct AttachmentStrip: View {
    let model: AppModel
    var compact = false

    static func cardHeight(compact: Bool) -> CGFloat { compact ? 40 : 52 }
    /// Home's extra height when a report has images (caption + row + spacing).
    static func rowHeight(compact: Bool) -> CGFloat { compact ? 70 : 86 }

    var body: some View {
        let attachments = model.attachments(for: model.currentRef)
        if !attachments.isEmpty || model.attachmentMessage != nil {
            VStack(alignment: .leading, spacing: 7) {
                if !attachments.isEmpty {
                    HStack(spacing: 10) {
                        Caption("Images · \(attachments.count)")
                        Spacer(minLength: 0)
                        Button("Show in Finder") { model.revealAttachmentsForHandoff(attachments) }
                            .help("Opens the images under their original names, selected: drag them into ChatGPT after pasting the text.")
                        Button("Copy Text + Images") { Task { await model.copyResponseWithImages() } }
                            .help("The complete text and the images in one copy. Some apps paste only the text; then paste the text and drag the images.")
                    }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Island.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachments) { AttachmentCard(model: model, attachment: $0, compact: compact) }
                        }
                    }
                    .frame(height: Self.cardHeight(compact: compact))
                    .mask(HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 18)
                    })
                    .islandFrame("home.attachments")
                }
                if let message = model.attachmentMessage {
                    Text(message).font(.system(size: 11)).foregroundStyle(Island.warning)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// One image: a small thumbnail, its original name, type and size; the ⋯
/// menu (Open, Copy Image, Copy File, Show in Finder) and × to remove it from
/// the report. Drag the card into another app to give it the file.
struct AttachmentCard: View {
    let model: AppModel
    let attachment: ReportAttachment
    var compact = false
    @State private var hovering = false

    var body: some View {
        let url = model.attachmentURL(attachment)
        HStack(spacing: 9) {
            Group {
                if let url, let thumb = Thumbnails.image(for: url) {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Island.warning)
                }
            }
            .frame(width: compact ? 30 : 40, height: compact ? 30 : 40)
            .background(Island.code)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Island.hairline))
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.originalFilename)
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Island.primary)
                    .lineLimit(1).truncationMode(.middle)
                if !compact || url == nil {
                    Text(url == nil ? "Missing" : Self.detail(attachment))
                        .font(.system(size: 10.5)).foregroundStyle(url == nil ? Island.warning : Island.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 104, alignment: .leading)
            Menu {
                Button("Open") { if let url { NSWorkspace.shared.open(url) } }.disabled(url == nil)
                Button("Copy Image") { model.copyAttachment(attachment) }.disabled(url == nil)
                Button("Copy File") { model.copyAttachmentFiles([attachment]) }.disabled(url == nil)
                Button("Show in Finder") { model.revealAttachmentsForHandoff([attachment]) }.disabled(url == nil)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(attachment.originalFilename)")
            Button { model.removeAttachment(attachment) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18).background(Circle().fill(Island.control))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Island.secondary)
            .accessibilityLabel("Remove \(attachment.originalFilename) from this report")
            .help("Remove from this report (the text stays as it is)")
        }
        .padding(.leading, 6).padding(.trailing, 8)
        .frame(height: AttachmentStrip.cardHeight(compact: compact))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Island.cardRaised : Island.card))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if let url { NSWorkspace.shared.open(url) } }
        .onDrag { model.dragFile(for: attachment).flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
        .help("\(attachment.originalFilename) · drag into another app, double-click to open")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image \(attachment.originalFilename)")
    }

    static func detail(_ a: ReportAttachment) -> String {
        let type = a.mimeType.split(separator: "/").last.map { String($0).uppercased() } ?? "IMAGE"
        return "\(type) · \(ByteCountFormatter.string(fromByteCount: Int64(a.byteCount), countStyle: .file))"
    }
}

/// Small thumbnails decoded once at display size (never the full image).
@MainActor
enum Thumbnails {
    private static var cache: [URL: NSImage] = [:]

    static func image(for url: URL, maxPixels: Int = 96) -> NSImage? {
        if let hit = cache[url] { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                                                         kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if cache.count > 64 { cache.removeAll() }
        cache[url] = image
        return image
    }
}

// MARK: - Projects

struct ProjectsView: View {
    let model: AppModel
    let presentation: NotchPresentation

    private var rows: [AppModel.ProjectRow] {
        model.projectRows.sorted { a, b in
            let da = Wording.date(a.lastEventAt) ?? .distantPast, db = Wording.date(b.lastEventAt) ?? .distantPast
            if da != db { return da > db }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            Text("Capture keeps Claude Code's final answers from a folder. New projects start with capture off; turning it off keeps their history.")
                .font(.system(size: 11.5)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
            if let error = model.projects.error, model.projects.value == nil {
                MessageCard(title: error.title, detail: error.detail, symbol: "exclamationmark.triangle", tint: Island.warning, action: nil)
            } else if !rows.isEmpty {
                BoundedScroll(maxHeight: presentation.listHeight(chrome: 120)) {
                    GroupCard {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            if i > 0 { Hairline() }
                            ProjectRowView(model: model, row: row)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Button { model.chooseProjects() } label: { Label("Add Project…", systemImage: "plus") }
                    .buttonStyle(IslandPillStyle(prominent: rows.isEmpty))
                feedback
                Spacer(minLength: 0)
            }
        }
        .islandPadding(presentation)
    }

    @ViewBuilder
    private var feedback: some View {
        switch model.captureChange {
        case .working: ProgressView().controlSize(.small)
        case .failed(_, let message): Text(message).font(.system(size: 11)).foregroundStyle(Island.warning).lineLimit(2)
        case .done(_, let message): Text(message).font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(2)
        case nil: EmptyView()
        }
    }
}

struct ProjectRowView: View {
    let model: AppModel
    let row: AppModel.ProjectRow

    private var inherited: Bool { row.captureEnabled && !row.explicitlyEnabled }
    private var busy: Bool { if case .working = model.captureChange { return true } else { return false } }
    private var selected: Bool { row.path == model.selectedProjectPath && model.selectedImport == nil }

    var body: some View {
        HStack(spacing: 8) {
            Button { model.openProject(row.path) } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? Island.accent : Island.tertiary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Island.primary)
                                .lineLimit(1).truncationMode(.middle)
                            if model.hasNewAnswer(inProject: row.path) { Tag("New", tint: Island.accent) }
                        }
                        Text(detail).font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(IslandRowStyle())
            .help(row.path)
            .contextMenu {
                if row.isAddedOnly { Button("Remove from List") { model.removeAddedProject(row.path) } }
            }
            Toggle(isOn: Binding(get: { row.captureEnabled },
                                 set: { on in Task { await model.setCapture(on, for: row.path) } })) {
                Text(inherited ? "Via parent" : "Capture").font(.system(size: 11)).foregroundStyle(Island.tertiary)
            }
            .toggleStyle(IslandSwitchStyle())
            .fixedSize()
            .disabled(busy || inherited)
            .opacity(inherited ? 0.55 : 1)
            .accessibilityLabel("Capture for \(row.name)")
            .help(inherited ? "Captured because a parent folder is on; change it there." : "Keep Claude Code answers from this folder")
            .padding(.trailing, 12)
        }
        .padding(.horizontal, 2)
    }

    private var detail: String {
        let imports = model.imports.filter { $0.projectPath == row.path }.count
        var parts: [String] = []
        if row.sessionCount > 0 {
            parts.append(row.sessionCount == 1 ? "1 session" : "\(row.sessionCount) sessions")
            parts.append("last \(Wording.relative(row.lastEventAt))")
        } else {
            parts.append(row.captureEnabled ? "No answers yet" : "Capture is off")
        }
        if imports > 0 { parts.append(imports == 1 ? "1 cloud import" : "\(imports) cloud imports") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Recent Copies

struct CopiesView: View {
    let model: AppModel
    let presentation: NotchPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            Text("The last \(AppModel.copyHistoryLimit) copies you made here. Copy Again fetches the original text again; nothing outside Prompt Relay is watched.")
                .font(.system(size: 11.5)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
            if model.copyHistory.isEmpty {
                MessageCard(title: "Nothing copied yet", detail: "Copy a response or a Review Pack and it appears here.",
                            symbol: "clock.arrow.circlepath", tint: Island.secondary, action: nil)
            } else {
                GroupCard {
                    ForEach(Array(model.copyHistory.enumerated()), id: \.element.id) { i, record in
                        if i > 0 { Hairline() }
                        row(record)
                    }
                }
            }
            CopyFeedbackLine(model: model)
        }
        .islandPadding(presentation)
    }

    private func row(_ record: CopyRecord) -> some View {
        let available = model.isAvailable(record.ref)
        return HStack(spacing: 8) {
            Button { model.open(record.ref) } label: {
                HStack(spacing: 10) {
                    Image(systemName: record.kind == .response ? "doc.on.doc" : "checklist")
                        .font(.system(size: 12)).foregroundStyle(Island.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(record.kind.title) · \(record.projectName)").font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Island.primary).lineLimit(1)
                        Text(available ? "\(record.label) · \(Wording.relative(record.at))" : "No longer in history")
                            .font(.system(size: 11)).foregroundStyle(available ? Island.tertiary : Island.warning).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(IslandRowStyle())
            .disabled(!available)
            Button("Copy Again") { Task { await model.copyAgain(record) } }
                .buttonStyle(IslandPillStyle(prominent: false))
                .disabled(!available)
                .padding(.trailing, 10)
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - History

struct HistoryView: View {
    let model: AppModel
    let presentation: NotchPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            searchField
            BoundedScroll(maxHeight: presentation.listHeight(chrome: 90)) {
                VStack(alignment: .leading, spacing: 8) {
                    if model.historyQuery.trimmingCharacters(in: .whitespaces).isEmpty { browse } else { results }
                }
            }
        }
        .islandPadding(presentation)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Island.tertiary)
            TextField("Search", text: Binding(get: { model.historyQuery }, set: { model.historyQuery = $0 }),
                      prompt: Text("Search tasks and answers").foregroundStyle(Island.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Island.primary)
            if !model.historyQuery.isEmpty {
                Button { model.historyQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Island.tertiary).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Island.card))
    }

    @ViewBuilder
    private var results: some View {
        switch model.historyHits {
        case .loaded(let hits) where hits.isEmpty:
            Text("No reports match. Search covers imported reports in full and the first lines of captured tasks and answers.")
                .font(.system(size: 12)).foregroundStyle(Island.secondary).fixedSize(horizontal: false, vertical: true)
        case .loaded(let hits):
            GroupCard {
                ForEach(Array(hits.enumerated()), id: \.element.id) { i, hit in
                    if i > 0 { Hairline() }
                    HistoryRow(model: model, ref: hit.ref, source: hit.source, title: hit.title,
                               detail: "\(hit.projectName) · \(Wording.relative(hit.at))")
                }
            }
        default:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var browse: some View {
        let pins = model.pinned.filter(model.isAvailable)
        if !pins.isEmpty {
            Caption("Pinned")
            GroupCard {
                ForEach(Array(pins.enumerated()), id: \.element) { i, ref in
                    if i > 0 { Hairline() }
                    let described = model.describe(ref)
                    HistoryRow(model: model, ref: ref, source: ref.isImport ? .cloudManualImport : .localClaudeCode,
                               title: described.label, detail: described.project)
                }
            }
        }
        if !model.imports.isEmpty {
            Caption("Cloud imports")
            GroupCard {
                ForEach(Array(model.imports.enumerated()), id: \.element.id) { i, report in
                    if i > 0 { Hairline() }
                    HistoryRow(model: model, ref: report.ref, source: .cloudManualImport,
                               title: AppModel.oneLine(report.task ?? report.text),
                               detail: "\(report.projectName ?? "No project") · \(Wording.relative(report.importedAt))")
                        .contextMenu { Button("Delete Import") { model.deleteImport(report.id) } }
                }
            }
        }
        ForEach(model.sessionsByProject, id: \.project) { group in
            Caption(group.name)
            GroupCard {
                ForEach(Array(group.sessions.enumerated()), id: \.element.id) { i, session in
                    if i > 0 { Hairline() }
                    sessionRow(session)
                    if session.sessionKey == model.selectedSessionKey, model.selectedImport == nil { answers }
                }
            }
        }
        if model.sessionsByProject.isEmpty, model.imports.isEmpty {
            Text("No reports yet.").font(.system(size: 12)).foregroundStyle(Island.secondary)
        }
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        let open = session.sessionKey == model.selectedSessionKey && model.selectedImport == nil
        return Button { model.focusSession(session) } label: {
            HStack(spacing: 8) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Island.tertiary).frame(width: 12)
                Text(Wording.sessionTitle(session)).font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Island.primary)
                Text(session.turnCount == 1 ? "1 turn" : "\(session.turnCount) turns")
                    .font(.system(size: 11)).foregroundStyle(Island.tertiary)
                Spacer(minLength: 6)
                Text(Wording.relative(session.lastEventAt)).font(.system(size: 11)).foregroundStyle(Island.tertiary)
                    .padding(.trailing, 4)
            }
        }
        .buttonStyle(IslandRowStyle())
        .padding(.horizontal, 2)
        .help(session.sessionID ?? session.sessionKey)
        .accessibilityLabel("\(Wording.sessionTitle(session)), \(open ? "expanded" : "collapsed")")
    }

    @ViewBuilder
    private var answers: some View {
        let turns = model.turnsNewestFirst.filter { $0.finalResponse != nil || $0.status == .apiError }
        if model.turns.value == nil {
            ProgressView().controlSize(.small).padding(.leading, 34).padding(.vertical, 4)
        } else if turns.isEmpty {
            Text("No answers in this session yet").font(.system(size: 11)).foregroundStyle(Island.tertiary)
                .padding(.leading, 34).padding(.vertical, 4)
        } else if let key = model.selectedSessionKey {
            ForEach(turns) { turn in
                HistoryRow(model: model, ref: .local(sessionKey: key, turn: turn.index), source: .localClaudeCode,
                           title: AppModel.oneLine(turn.userRequestPreview ?? turn.finalResponse?.preview ?? turn.error?.message ?? ""),
                           detail: "#\(turn.index) · \(Wording.relative(turn.finalResponse?.receivedAt ?? turn.request?.receivedAt))",
                           failed: turn.status == .apiError)
                    .padding(.leading, 18)
            }
        }
    }
}

/// One report in History: open, pin, copy.
struct HistoryRow: View {
    let model: AppModel
    let ref: ReportRef
    let source: ReportSource
    let title: String
    let detail: String
    var failed = false

    var body: some View {
        HStack(spacing: 2) {
            Button { model.open(ref) } label: {
                HStack(spacing: 10) {
                    Image(systemName: source == .cloudManualImport ? "icloud.and.arrow.down" : "laptopcomputer")
                        .font(.system(size: 11)).foregroundStyle(Island.tertiary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title.isEmpty ? "Untitled" : title).font(.system(size: 12.5))
                            .foregroundStyle(failed ? Island.error : Island.primary).lineLimit(1)
                        Text(detail).font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(IslandRowStyle(selected: model.currentRef == ref))
            Button { model.togglePin(ref) } label: {
                Image(systemName: model.isPinned(ref) ? "pin.fill" : "pin").font(.system(size: 11))
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isPinned(ref) ? Island.accent : Island.tertiary)
            .accessibilityLabel(model.isPinned(ref) ? "Unpin" : "Pin")
            .help(model.isPinned(ref) ? "Unpin" : "Pin to the top of History")
            Button { Task { await model.copyResponse(ref) } } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 11))
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Island.secondary)
            .disabled(failed)
            .opacity(failed ? 0.3 : 1)
            .accessibilityLabel("Copy Response")
            .help("Copy this complete response")
            .padding(.trailing, 8)
        }
        .padding(.horizontal, 2)
    }
}

extension ReportRef {
    var isImport: Bool { if case .imported = self { return true } else { return false } }
}

// MARK: - Import (Cloud, manual)

/// Paste a report from a Claude Code cloud session. The text comes only from
/// an explicit Paste and is kept exactly as pasted (it is not editable here).
struct ImportView: View {
    let model: AppModel
    let presentation: NotchPresentation
    @State private var text = ""
    @State private var task = ""
    @State private var session = ""
    @State private var projectPath: String?
    @State private var outcome: AppModel.ImportOutcome?

    var body: some View {
        BoundedScroll(maxHeight: presentation.listHeight(chrome: 20)) {
            VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
                Text("Cloud sessions run on Anthropic's servers, so the capture on this Mac can't see them. Copy Claude's final report there, then paste it here. It is saved on this Mac exactly as pasted and marked as imported.")
                    .font(.system(size: 11.5)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
                reportCard
                field("Task (optional)", text: $task, prompt: "What you asked Claude, for the Review Pack", lines: 3)
                HStack(alignment: .top, spacing: 10) {
                    projectMenu
                    field("Cloud session (optional)", text: $session, prompt: "ID or link", lines: 1)
                }
                HStack(spacing: 10) {
                    Button("Import Report") { save() }
                        .buttonStyle(IslandPillStyle(prominent: true))
                        .disabled(text.isEmpty)
                    if case .failed(let message) = outcome {
                        Text(message).font(.system(size: 11)).foregroundStyle(Island.error)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, IslandMetrics.of(presentation).leading)
        }
        .islandPadding(presentation, horizontal: false)
    }

    private func save() {
        let result = model.importReport(text: text, task: task, projectPath: projectPath, sessionLabel: session)
        outcome = result
        if case .failed = result { return }
        text = ""; task = ""; session = ""
    }

    private var reportCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Caption("Report")
                if !text.isEmpty {
                    Text("\(text.unicodeScalars.count.formatted()) characters, kept exactly").font(.system(size: 10.5)).foregroundStyle(Island.tertiary)
                }
                Spacer()
                if !text.isEmpty {
                    Button("Clear") { text = "" }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Island.secondary)
                }
            }
            if text.isEmpty {
                Button { paste() } label: { Label("Paste Report from Clipboard", systemImage: "doc.on.clipboard") }
                    .buttonStyle(IslandPillStyle(prominent: false))
                Text("Reads the clipboard once, when you click.").font(.system(size: 10.5)).foregroundStyle(Island.tertiary)
            } else {
                ResponsePreview(text: text, lines: 5)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).fill(Island.card))
    }

    private func paste() {
        outcome = nil
        text = NSPasteboard.general.string(forType: .string) ?? ""
        if text.isEmpty { outcome = .failed("The clipboard has no text.") }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Caption(title)
            TextField(title, text: text, prompt: Text(prompt).foregroundStyle(Island.tertiary), axis: .vertical)
                .lineLimit(1...lines)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Island.primary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Island.card))
        }
    }

    private var projectMenu: some View {
        VStack(alignment: .leading, spacing: 4) {
            Caption("Project")
            Menu {
                Button("None") { projectPath = nil }
                ForEach(model.projectRows) { row in Button(row.name) { projectPath = row.path } }
            } label: {
                HStack(spacing: 4) {
                    Text(projectPath.flatMap { p in model.projectRows.first { $0.path == p }?.name } ?? "None").lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 12.5)).foregroundStyle(Island.primary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 10).frame(height: 31)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Island.card))
        }
    }
}

// MARK: - Full Report

/// The whole report, scrolling inside the island: formatted, or the exact
/// plain text. It always shows everything the report contains.
struct ReaderView: View {
    let model: AppModel
    let presentation: NotchPresentation
    @State private var plain = false

    var body: some View {
        let facts = ReportFacts(model: model)
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            HStack(spacing: 8) {
                Text([facts.source?.label, facts.characters.map { "\($0.formatted()) characters" }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5)).foregroundStyle(Island.tertiary).lineLimit(1)
                Spacer(minLength: 0)
                Picker("Show as", selection: $plain) {
                    Text("Formatted").tag(false)
                    Text("Plain Text").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            if let text = fullText {
                Group {
                    if plain {
                        VerbatimTextView(text, textColor: NSColor.white.withAlphaComponent(0.92), fontSize: 12.5)
                            .padding(6)
                            .frame(height: presentation.listHeight(chrome: 92))
                    } else {
                        BoundedScroll(maxHeight: presentation.listHeight(chrome: 92)) {
                            MarkdownBlocksView(blocks: Markdown.blocks(text), codeLineLimit: nil, fontSize: 13)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).fill(Island.card))
                .clipShape(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous))
                HStack(spacing: 8) {
                    CopyActions(model: model, blocked: false)
                    Spacer(minLength: 0)
                }
                CopyFeedbackLine(model: model)
            } else if model.detail.isLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 8)
            } else {
                MessageCard(title: "No report text", detail: facts.blocker ?? "This turn has no final response.",
                            symbol: "doc.text", tint: Island.secondary, action: nil)
            }
        }
        .islandPadding(presentation)
    }

    /// The complete text: the import, or the Core's full `final_response.text`.
    private var fullText: String? {
        if let report = model.selectedImport { return report.text }
        return model.selectedResponseText
    }
}
