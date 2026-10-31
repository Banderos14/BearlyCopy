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

/// The island's design tokens: colors by role, spacing, radii and motion.
/// Dark only for now (the island merges with the black camera housing);
/// a light theme replaces the color roles here and nothing else.
enum Island {
    /// The active theme's roles; set by `NotchSettings.theme` (main thread).
    nonisolated(unsafe) static var palette: IslandPalette = IslandTheme.warmCocoa.palette

    // Text
    static var primary: Color { palette.primary.color }
    static var secondary: Color { palette.secondary.color }
    static var tertiary: Color { palette.tertiary.color }
    // Surfaces: graphite on the black island, a step lighter for what is interactive.
    static var card: Color { palette.card.color }
    static var cardRaised: Color { palette.cardRaised.color }
    static var code: Color { palette.code.color }
    static var control: Color { palette.control.color }
    static let hover = Color.white.opacity(0.06)
    static var selected: Color { palette.accent.color.opacity(0.16) }
    static let hairline = Color.white.opacity(0.07)
    // Roles
    /// Interactive accent: new answers, selection, what is on.
    static var accent: Color { palette.accent.color }
    /// A copy that succeeded, a command that completed.
    static var success: Color { palette.success.color }
    static var warning: Color { palette.warning.color }
    static var error: Color { palette.error.color }
    /// Visual review, attachments and other materials.
    static var review: Color { palette.review.color }
    /// The main button (Copy Answer).
    static var prominent: Color { palette.prominent.color }
    static var onProminent: Color { palette.onProminent.color }
    // Shape and spacing
    static let cardRadius: CGFloat = 12
    static let controlHeight: CGFloat = 28
    /// Inner padding of a card: its text never runs into the rounded edge.
    static let cardPadding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let l: CGFloat = 10
    }
    // Motion
    /// Geometry changes (a card taking its new height): short, no bounce.
    /// 280 ms, inside the 220–320 ms range asked for; one value for cards,
    /// the island and History/Task disclosure, so they move together. Not
    /// yet judged on the real screen (owner check).
    static let geometryDuration: Double = 0.28
    static func geometry(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .smooth(duration: geometryDuration) }
    /// Content replaced in place (another answer): a cross-fade.
    static func fade(reduceMotion: Bool) -> Animation { .easeInOut(duration: reduceMotion ? 0.1 : 0.2) }
}

/// Reduce Motion as the island applies it (the system setting or the app's own).
struct IslandReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var islandReduceMotion: Bool {
        get { self[IslandReduceMotionKey.self] }
        set { self[IslandReduceMotionKey.self] = newValue }
    }
}

/// Offers its one child the island's whole height budget and takes the
/// height the child uses, never more than the budget. Scroll areas inside
/// take what is left after the fixed rows (header, footer), so nothing can
/// grow past the island and draw over the rows below it — the cause of
/// Phase 5's overlaps, where estimated heights left the real content taller
/// than its frame.
struct HeightBudget: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: maxHeight))
        return CGSize(width: proposal.width ?? size.width, height: min(size.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// In Details' paired rows a card fills its row (so the two cards of a row
/// end at the same line); elsewhere it is as tall as its content.
struct CardFillsRowKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var cardFillsRow: Bool {
        get { self[CardFillsRowKey.self] }
        set { self[CardFillsRowKey.self] = newValue }
    }
}

/// The one card style: padding, width, row filling, surface.
struct IslandCardModifier: ViewModifier {
    @Environment(\.cardFillsRow) private var fills
    func body(content: Content) -> some View {
        content
            .padding(Island.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).fill(Island.card))
    }
}

extension View {
    func islandCard() -> some View { modifier(IslandCardModifier()) }
}

struct BudgetModifier: ViewModifier {
    let maxHeight: CGFloat
    func body(content: Content) -> some View { HeightBudget(maxHeight: maxHeight) { content } }
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
                case .clipboard, .copies: ClipboardView(model: model, presentation: presentation)
                case .history: HistoryView(model: model, presentation: presentation)
                case .importReport: ImportView(model: model, presentation: presentation)
                case .settings: IslandSettingsView(model: model, presentation: presentation, settings: settings, notifier: notifier,
                                                   actions: actions)
                case .reader: ReaderView(model: model, presentation: presentation)
                case .taskReader: TaskReaderView(model: model, presentation: presentation)
                case .evidence: EvidenceView(model: model, presentation: presentation)
                case .packagePreview: PackagePreviewView(model: model, presentation: presentation)
                case .attachmentPreview: AttachmentPreviewView(model: model, presentation: presentation)
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
        .islandHelp("Back (Esc)")
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

    /// Claude Code started the turn itself (never shown as the user's request).
    var isAutomated: Bool { if case .automated = task { return true } else { return false } }

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
            return .automated(earlier: turn.earlierUserRequest.map { $0.displayPreview ?? Wording.requestForDisplay($0.preview).text },
                              turn: turn.earlierUserRequest?.turn)
        case .unknown? where turn.request != nil:
            return .unknownSource(model.selectedRequestText.map { Wording.requestForDisplay($0).text } ?? turn.request!.readablePreview)
        default: break
        }
        // The whole request once `show` has loaded it (Phase 7: More showed
        // only the Core's 200-character preview of a long request).
        let readable = model.selectedRequestText.map { Wording.requestForDisplay($0).text } ?? turn.request?.readablePreview
        switch (turn.link, readable) {
        case (.promptID, let text?): return .linked(text)
        case (_, let text?): return .inferred(text)
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
                    .islandHelp("New answers from this project are not recorded. Turn capture on in Projects.")
            }
            if model.selectedImport == nil, let turn = model.selectedTurn, turn.status == .stopReceivedBackgroundTasksPending {
                // A fact about the Stop, not about now: the work may have ended since.
                Text("· background work at Stop").foregroundStyle(Island.warning)
                    .islandHelp("When Claude stopped, background tasks were still running. Monitors (such as an artifact's live updates) are not counted.")
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Island.tertiary)
        .lineLimit(1)
    }
}

/// The request: one or two lines; expanded, the whole text scrolls inside
/// the card (at most `expandedHeight`), so a long pasted request never
/// pushes the Response out. Task and Response scroll independently.
struct TaskCard: View {
    let facts: ReportFacts
    @Binding var expanded: Bool
    @Environment(\.islandReduceMotion) private var reduceMotion
    var lines = 2
    /// Opens View Full Task; nil where there is no room for it.
    var viewFull: (() -> Void)?
    static let expandedHeight: CGFloat = 168

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
                if let viewFull, hasText {
                    Button(action: viewFull) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9, weight: .bold))
                            .frame(width: 22, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Island.secondary)
                    .accessibilityLabel(Labels.viewFullTask)
                    .islandHelp("\(Labels.viewFullTask): the whole request on its own screen, Formatted or Markdown Source")
                }
                if canExpand {
                    Button { withAnimation(Island.geometry(reduceMotion: reduceMotion)) { expanded.toggle() } } label: {
                        HStack(spacing: 3) {
                            Text(expanded ? "Less" : "More").font(.system(size: 10.5, weight: .medium))
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                        .padding(.horizontal, 6).frame(height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Island.secondary)
                    .accessibilityLabel(expanded ? "Show less of the task" : "Show the whole task")
                    .islandHelp(expanded ? "Collapse the task" : "Show the whole task; it scrolls inside this card")
                }
            }
            switch facts.task {
            case .automated(let earlier, let turn):
                Text("Claude Code started this turn itself; you did not write its message.")
                    .font(.system(size: 12)).foregroundStyle(Island.tertiary)
                if let earlier {
                    body(text: "Your request before it (turn \(turn ?? 0)): \(earlier.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            case .linked(let text), .inferred(let text), .supplied(let text), .unknownSource(let text):
                body(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
            case .unavailable(let why):
                Text(why.isEmpty ? "Unavailable" : "Unavailable: \(why)").font(.system(size: 12)).foregroundStyle(Island.tertiary)
            }
        }
        .islandCard()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    /// One scroll view for both states (Phase 6 visual pass): collapsed it
    /// shows `lines` lines, expanded the whole text scrolling inside at most
    /// `expandedHeight`. Swapping a Text for a new scroll view made the card
    /// snap to 0 pt first and only then animate.
    private func body(text: String) -> some View {
        BoundedScroll(maxHeight: expanded ? Self.expandedHeight : .infinity, minHeight: expanded ? 36 : 0) {
            Text(text).font(.system(size: 12.5)).foregroundStyle(Island.secondary)
                .lineLimit(expanded ? nil : lines).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.trailing, expanded ? 6 : 0)
                // A new identity for the text only: inside a scroll view a
                // changed line limit alone was not measured again (stayed at
                // 2 lines). The scroll view, and its animated height, stay.
                .id(expanded)
        }
        .scrollDisabled(!expanded)
        .islandFrame("task.body")
    }

    private var hasText: Bool {
        if case .unavailable = facts.task { return false }
        return true
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
/// pointer over it scrolls only the answer. Another answer starts at its
/// top; the card takes its new height smoothly and the text cross-fades.
/// View Full Report opens the reader; every copy uses the original text,
/// never what is drawn here.
struct ResponseCard: View {
    let model: AppModel
    let facts: ReportFacts
    let openFull: () -> Void
    @Environment(\.islandReduceMotion) private var reduceMotion
    /// The answer on screen. While the next answer's full text loads, the
    /// previous one stays (dimmed) instead of jumping to the short preview
    /// and then again to the full text: one change, animated once.
    @State private var shown: Shown?
    struct Shown: Equatable { let ref: ReportRef?; let text: String }

    /// The full text of the selected answer is here, or none is coming.
    /// Right after a switch the loaded detail still belongs to the previous
    /// answer for a moment; that counts as "not ready", not as "no text".
    private var ready: Bool {
        if model.selectedImport != nil || model.selectedResponseText != nil { return true }
        let stale = model.detail.value.map { $0.turn.index != model.selectedTurnIndex || $0.session.sessionKey != model.selectedSessionKey } ?? false
        return !(model.detail.isLoading || stale)
    }

    private var display: Shown {
        let current = Shown(ref: model.currentRef, text: facts.text ?? "")
        if !ready, let shown, shown.ref != current.ref { return shown }
        return current
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Island.Space.m) {
            HStack(spacing: 6) {
                Caption("Answer")
                if let n = facts.characters, n > 0 {
                    Text("\(n.formatted()) characters" + (facts.at.map { " · " + Wording.clock($0) } ?? ""))
                        .font(.system(size: 10.5)).foregroundStyle(Island.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if model.selectedImport == nil, let turn = model.selectedTurn { AnswerStepper(model: model, turn: turn) }
            }
            if let blocker = facts.blocker {
                Text(model.selectedTurn?.error?.message ?? blocker)
                    .font(.system(size: 12.5))
                    .foregroundStyle(model.selectedTurn?.status == .apiError ? Island.error : Island.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let display = self.display
                BoundedScroll(minHeight: 32, resetID: display.ref) {
                    MarkdownBlocksView(blocks: Markdown.blocks(display.text), codeLineLimit: nil, fontSize: 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 6)   // room for the scroller
                        .textSelection(.enabled)
                        .id(display.ref)
                        .transition(.opacity)
                }
                .opacity(display.ref == model.currentRef ? 1 : 0.55)
                .animation(Island.fade(reduceMotion: reduceMotion), value: display)
                .onChange(of: display, initial: true) { _, new in if new.ref == model.currentRef { shown = new } }
                .islandFrame("response.scroll")
                .accessibilityLabel("Answer")
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
                .islandHelp("Open Full Report: the complete answer, Formatted or Markdown Source")
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) { EvidenceChip(model: model) }
            }
        }
        .islandCard()
        .islandFrame("card.response")
    }
}

/// The first blocks of the answer, clipped to a few lines. Display only.
struct ResponsePreview: View {
    let text: String
    let lines: Int

    var body: some View {
        let blocks = Array(Markdown.blocks(String(text.prefix(1800))).prefix(6))
        MarkdownBlocksView(blocks: blocks, codeLineLimit: 4, fontSize: 13)
            .frame(maxWidth: .infinity, maxHeight: CGFloat(lines) * 19, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
    }
}

/// Copy Answer (the one white button) and Copy with Context. A copy that the
/// clipboard read-back confirmed shows "Copied!" with a check on its own
/// button for 2 s, and the size of what was copied beside it when there is
/// room (never widening the row). A failure is never shown as a success
/// (see `CopyFailureLine`).
struct CopyActions: View {
    let model: AppModel
    let blocked: Bool

    var body: some View {
        let ref = model.currentRef
        let answer = model.isCopied(AppModel.answerToken(ref)), review = model.isCopied(AppModel.reviewToken(ref))
        HStack(spacing: Island.Space.m) {
            Button {
                Task { await model.copySelectedResponse() }
            } label: {
                Label(answer ? Labels.copied : Labels.copyAnswer, systemImage: answer ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(IslandPillStyle(prominent: true))
            .disabled(blocked)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .accessibilityLabel(Labels.copyAnswer)
            .islandHelp(Labels.copyAnswerHelp)

            Button {
                Task { await model.copySelectedContext() }
            } label: {
                Label(review ? Labels.copied : Labels.copyWithContext, systemImage: review ? "checkmark" : "checklist")
            }
            .buttonStyle(IslandPillStyle(prominent: false))
            .disabled(blocked)
            .keyboardShortcut("c", modifiers: [.command, .option])
            .accessibilityLabel(Labels.copyWithContext)
            .islandHelp(Labels.copyWithContextHelp)

            if answer || review, case .copied(_, let n) = model.copyFeedback, n > 0 {
                // "· 12,486 characters", "12,486 chars" when narrow, or nothing:
                // never wider than the room left, so nothing grows.
                ViewThatFits(in: .horizontal) {
                    Text("· \(n.formatted()) characters").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Island.tertiary)
                        .fixedSize()
                    Text(Labels.chars(n)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Island.tertiary)
                        .fixedSize()
                    EmptyView()
                }
                .accessibilityLabel("Copied \(Labels.chars(n))")
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.copiedToken)
    }
}

// MARK: - Quick Peek

/// Answers four questions without Details: which session, what Claude just
/// reported (its own first line, never a summary), what else there is
/// (failures, documents, images, mockups) and what each copy does.
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
                if let at = facts.at { Text(Wording.relative(at)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Island.tertiary) }
            }
            VStack(alignment: .leading, spacing: Island.Space.m) {
                if facts.source == nil {
                    HStack(alignment: .center) {
                        Text(model.projects.value?.isEmpty == true ? "Click to choose a project to capture." : "No answer yet.")
                            .font(.system(size: 12.5)).foregroundStyle(Island.secondary)
                        Spacer()
                        expandButton
                    }
                } else {
                    header
                    VStack(alignment: .leading, spacing: 3) {
                        taskLine(facts)
                        answerLine(facts)
                    }
                    factsLine
                    if let step = model.activeHandoff {
                        HandoffFooter(model: model, step: step).islandFrame("peek.handoff")
                    } else {
                        HStack(spacing: Island.Space.m) {
                            CopyActions(model: model, blocked: facts.blocker != nil)
                            Spacer(minLength: 0)
                            detailsButton
                        }
                        .islandFrame("peek.actions")
                    }
                    CopyFailureLine(model: model)
                }
            }
            .islandPadding(presentation)
        }
        .animation(.easeOut(duration: 0.15), value: model.activeHandoff)
    }

    /// Project · session, and the turn's state as a chip.
    private var header: some View {
        HStack(spacing: 5) {
            Text(model.selectedImport.map { $0.projectName ?? "Cloud import" }
                 ?? model.selectedProject.map(Wording.projectName) ?? "Prompt Relay")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Island.primary)
                .lineLimit(1).truncationMode(.middle).layoutPriority(1)
            if let session = model.selectedImport == nil ? model.selectedSession.map(Wording.sessionTitle) : "imported report" {
                Text("· " + session).font(.system(size: 12)).foregroundStyle(Island.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let turn = model.selectedTurn, model.selectedImport == nil,
               let (position, count) = AnswerStepper.position(model, turn: turn.index), count > 1 {
                Text("\(position)/\(count)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Island.tertiary)
                    .accessibilityLabel("Answer \(position) of \(count)")
            }
            let (label, tint) = status
            if !label.isEmpty { Tag(label, tint: tint).layoutPriority(1) }
        }
        .islandFrame("peek.header")
    }

    private func taskLine(_ facts: ReportFacts) -> some View {
        let text: String? = {
            switch facts.task {
            case .linked(let t), .inferred(let t), .supplied(let t): return t
            case .unknownSource(let t): return "Source not established · " + t
            case .automated(let earlier, _):
                return earlier.map { "Started automatically · after: " + $0 } ?? "Started automatically by Claude Code"
            case .unavailable: return nil
            }
        }()
        return Group {
            if let text {
                HStack(spacing: 5) {
                    Image(systemName: facts.isAutomated ? "gearshape.2" : "person").font(.system(size: 9.5))
                        .foregroundStyle(Island.tertiary).frame(width: 12)
                    Text(Self.oneLine(text)).font(.system(size: 11.5)).foregroundStyle(Island.tertiary).lineLimit(1)
                }
                .accessibilityLabel(facts.isAutomated ? "Started automatically" : "Your task: \(text)")
            }
        }
    }

    private func answerLine(_ facts: ReportFacts) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "text.bubble").font(.system(size: 9.5)).foregroundStyle(Island.tertiary).frame(width: 12)
            if let blocker = facts.blocker {
                Text(model.selectedTurn?.error?.message ?? blocker).font(.system(size: 12.5))
                    .foregroundStyle(model.selectedTurn?.status == .apiError ? Island.error : Island.secondary).lineLimit(2)
            } else {
                Text(Self.firstLine(facts.text ?? "")).font(.system(size: 12.5)).foregroundStyle(Island.primary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .islandFrame("peek.preview")
    }

    /// What there is beyond the text, in plain words and only what was
    /// really observed or attached; nothing at all otherwise. Exit codes,
    /// commands and durations stay in Details (Observed Work). What each
    /// copy contains is in the buttons' tooltips, not repeated here.
    @ViewBuilder
    private var factsLine: some View {
        let facts = Self.facts(observed: model.selectedImport == nil ? model.selectedTurn?.observed : nil,
                               summary: model.materialSummary(for: model.currentRef))
        if !facts.isEmpty {
            HStack(spacing: 5) {
                ForEach(facts, id: \.text) { Tag($0.text, tint: $0.tint) }
                Spacer(minLength: 0)
            }
            .frame(height: 17)
            .islandFrame("peek.facts")
        }
    }

    struct Fact: Equatable { let text: String; let tint: Color }

    /// "1 failed command · 3 commands completed · 2 files changed · 1 document · 2 images".
    /// "Completed" means exit 0 of a test or build command, never "tests passed".
    static func facts(observed: ObservedCounts?, summary: AppModel.MaterialSummary) -> [Fact] {
        var out: [Fact] = []
        if let o = observed {
            let failed = max(o.commandsNonzero ?? 0, o.runsNonzero)
            if failed > 0 { out.append(Fact(text: Labels.failedCommands(failed), tint: Island.error)) }
            if o.runsExitZero > 0 { out.append(Fact(text: Labels.completedCommands(o.runsExitZero), tint: Island.success)) }
            if o.filesChanged > 0 { out.append(Fact(text: Labels.filesChanged(o.filesChanged), tint: Island.secondary)) }
        }
        out += summary.parts.map { Fact(text: $0, tint: Island.review) }
        if summary.needsVisualReview { out.append(Fact(text: "Visual review required", tint: Island.review)) }
        return out
    }

    /// The turn's state; "New answer" while unseen.
    private var status: (String, Color) {
        if model.selectedImport != nil { return ("Imported", Island.secondary) }
        guard let turn = model.selectedTurn else { return ("", Island.tertiary) }
        if model.hasUnseenAnswer { return ("New answer", Island.accent) }
        switch turn.status {
        case .awaitingResponse: return ("Working", Island.warning)
        case .apiError: return ("API error", Island.error)
        case .stopReceivedBackgroundTasksPending: return ("Stopped · background work", Island.warning)
        default: return ("Stopped", Island.secondary)
        }
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
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
            .padding(.horizontal, 11).frame(height: Island.controlHeight)
            .background(Capsule().fill(Island.control))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Island.primary)
        .accessibilityLabel("Details")
        .islandHelp("Open Details: the whole answer, observed work, attachments, sessions and settings")
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
        .islandHelp("Show the task, the full report, history and settings")
    }
}

// MARK: - Shared pieces

struct Caption: View {
    let text: String
    /// The card's role color, used only where the theme tints captions.
    var role: Color?
    init(_ text: String, role: Color? = nil) { self.text = text; self.role = role }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Island.palette.tintedCaptions ? (role ?? Island.tertiary) : Island.tertiary)
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
            .foregroundStyle(prominent ? Island.onProminent : Island.primary)
            .background(Capsule().fill(prominent ? Island.prominent.opacity(enabled ? 1 : 0.3) : Island.control))
            .opacity(configuration.isPressed ? 0.75 : (enabled || prominent ? 1 : 0.45))
            .contentShape(Capsule())
            .fixedSize()
    }
}

/// ‹ 7/8 ›: the answers of the selected session in the order they came,
/// 1 the first and N the newest (Phase 5 counted newest first, so the
/// newest showed as 1/N, and as 2/N when Claude Code started a later turn
/// itself). Automatic turns are counted and marked, never hidden.
struct AnswerStepper: View {
    let model: AppModel
    let turn: Turn

    /// 1-based position in chronological order and the number of answers.
    @MainActor static func position(_ model: AppModel, turn index: Int) -> (position: Int, count: Int)? {
        let answers = NotchRootView.answerTurns(model)
        guard let i = answers.firstIndex(of: index) else { return nil }
        return (answers.count - i, answers.count)
    }

    var body: some View {
        if let (position, count) = Self.position(model, turn: turn.index), count > 1 {
            HStack(spacing: 1) {
                step("chevron.left", label: "Previous answer", enabled: position > 1) { NotchRootView.step(model, by: 1) }
                HStack(spacing: 3) {
                    if turn.requestOrigin == .automated {
                        Image(systemName: "gearshape.2").font(.system(size: 8.5)).islandHelp("Claude Code started this turn itself")
                    }
                    Text("\(position)/\(count)").font(.system(size: 10.5).monospacedDigit())
                }
                .foregroundStyle(Island.tertiary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Answer \(position) of \(count)")
                step("chevron.right", label: "Next answer", enabled: position < count) { NotchRootView.step(model, by: -1) }
            }
        }
    }

    private func step(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Island.primary.opacity(enabled ? 0.85 : 0.25))
        .disabled(!enabled)
        .accessibilityLabel(label)
        .islandHelp(label + (symbol == "chevron.left" ? " (←)" : " (→)"))
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

/// A scroll view as tall as its content, up to `maxHeight` and up to the
/// height its parent offers (see `HeightBudget`); longer content scrolls
/// inside it. When `resetID` changes (another answer) it returns to the top
/// and takes the new height smoothly; the scroll view itself is kept, so
/// its height never drops to nothing between two answers.
struct BoundedScroll<Content: View>: View {
    var maxHeight: CGFloat = .infinity
    /// Never squeezed below this (or below the content, if shorter).
    var minHeight: CGFloat = 0
    var resetID: AnyHashable? = nil
    @ViewBuilder let content: Content
    @State private var height: CGFloat?
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        // The content's height is read after layout (no preference: a
        // preference that changes the frame it measures updated several
        // times per frame). The scroller does not depend on the measurement:
        // with legacy scrollers (a mouse attached) showing it only when
        // "too tall" narrowed the content, which changed its height again.
        // No fade mask: it darkened the last lines (Phase 6).
        let natural = min(height ?? 0, maxHeight)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.top)
                    content
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { new in
                    guard abs(new - (height ?? -1)) >= 0.5 else { return }
                    if height == nil { height = new } else {
                        withAnimation(Island.geometry(reduceMotion: reduceMotion)) { height = new }
                    }
                }
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: resetID) { proxy.scrollTo(Self.top, anchor: .top) }
        }
        .frame(minHeight: max(1, min(minHeight, natural)), idealHeight: max(1, natural), maxHeight: max(1, natural))
    }

    private static var top: String { "bounded-scroll-top" }
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

/// Small thumbnails decoded once at display size (never the full image).
@MainActor
enum Thumbnails {
    /// Keyed by file and size: a 64 px thumbnail is never reused where 240 px is drawn.
    private static var cache: [String: NSImage] = [:]

    static func image(for url: URL, maxPixels: Int = 96) -> NSImage? {
        let key = "\(maxPixels)@\(url.path)"
        if let hit = cache[key] { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                                                         kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if cache.count > 64 { cache.removeAll() }
        cache[key] = image
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
            .islandHelp(row.path)
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
            .islandHelp(inherited ? "Captured because a parent folder is on; change it there." : "Keep Claude Code answers from this folder")
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

// MARK: - History

struct HistoryView: View {
    let model: AppModel
    let presentation: NotchPresentation
    @Environment(\.islandReduceMotion) private var reduceMotion

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
                    if session.sessionKey == model.historyExpandedKey, session.sessionKey == model.selectedSessionKey {
                        answers.transition(.opacity)
                    }
                }
            }
        }
        if model.sessionsByProject.isEmpty, model.imports.isEmpty {
            Text("No reports yet.").font(.system(size: 12)).foregroundStyle(Island.secondary)
        }
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        let open = session.sessionKey == model.historyExpandedKey
        return Button {
            withAnimation(Island.geometry(reduceMotion: reduceMotion)) { model.toggleHistorySession(session) }
        } label: {
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
        .islandHelp(session.sessionID ?? session.sessionKey)
        .accessibilityLabel("\(Wording.sessionTitle(session)), \(open ? "expanded" : "collapsed")")
        .accessibilityHint(open ? "Collapse" : "Show its answers")
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
            .islandHelp(model.isPinned(ref) ? "Unpin" : "Pin to the top of History")
            let copied = model.isCopied(AppModel.answerToken(ref))
            Button { Task { await model.copyResponse(ref) } } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: copied ? .bold : .regular))
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? Island.success : Island.secondary)
            .animation(.easeOut(duration: 0.15), value: copied)
            .disabled(failed)
            .opacity(failed ? 0.3 : 1)
            .accessibilityLabel(Labels.copyAnswer)
            .islandHelp(copied ? "Copied" : "Copy this complete answer")
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
                Text("For a finished result from Claude Cloud, ChatGPT, Gemini or another AI that the hooks on this Mac cannot see: paste its answer (and, if you like, your request). It is saved on this Mac exactly as pasted and marked “imported by you”, never as captured locally. Files you attach later go with it; nothing else is read.")
                    .font(.system(size: 11.5)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
                reportCard
                field("Task (optional)", text: $task, prompt: "What you asked the assistant", lines: 3)
                HStack(alignment: .top, spacing: 10) {
                    projectMenu
                    field("Source or session (optional)", text: $session, prompt: "e.g. ChatGPT, a session ID or link", lines: 1)
                }
                HStack(spacing: 10) {
                    Button("Import") { save() }
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

/// The whole report, scrolling inside the island: Formatted (the Markdown
/// rendered, the default) or Markdown Source (the exact characters, markup
/// included). Both are drawn from the same original text in one viewport
/// that keeps its size, so switching never changes the island's height
/// (Phase 5: back to Formatted, the island collapsed to 93 pt and cut the
/// report off; see `NotchPresentation.reportContentHeight`).
struct ReaderView: View {
    let model: AppModel
    let presentation: NotchPresentation
    @State private var source = false

    var body: some View {
        let facts = ReportFacts(model: model)
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            HStack(spacing: 8) {
                Text([facts.source?.label, facts.characters.map { "\($0.formatted()) characters" }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5)).foregroundStyle(Island.tertiary).lineLimit(1)
                Spacer(minLength: 0)
                ReaderModePicker(source: $source)
            }
            if let text = fullText {
                ReaderBody(text: text, plain: source)
                    .frame(minHeight: 120, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).fill(Island.card))
                    .clipShape(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous))
                    .islandFrame("reader.body")
                HStack(spacing: 8) {
                    CopyActions(model: model, blocked: false)
                    Spacer(minLength: 0)
                }
                .islandFrame("reader.actions")
                CopyFailureLine(model: model)
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

/// Formatted / Markdown Source, the same control in both readers.
struct ReaderModePicker: View {
    @Binding var source: Bool

    var body: some View {
        Picker("Show as", selection: $source) {
            Text("Formatted").tag(false)
            Text(Labels.markdownSource).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .islandHelp("Formatted renders the Markdown; Markdown Source shows the exact characters, markup included. Both copy the same original.")
    }
}

/// View Full Task: the whole request of the answer, from what is stored
/// (no new capture, no AI). Formatted hides the blocks Claude Code adds;
/// Markdown Source and Copy Original Task are the stored text exactly. An
/// automatic turn's message is never presented as the user's request.
struct TaskReaderView: View {
    let model: AppModel
    let presentation: NotchPresentation
    @State private var source = false

    var body: some View {
        let facts = ReportFacts(model: model)
        let task = model.fullTask
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            HStack(spacing: 8) {
                Text([facts.source?.label, task?.characters.map { "\($0.formatted()) characters" }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5)).foregroundStyle(Island.tertiary).lineLimit(1)
                if let task, !task.complete { Tag("incomplete", tint: Island.warning) }
                if task?.origin == .automated { Tag("started automatically", tint: Island.warning) }
                Spacer(minLength: 0)
                if task?.display != nil { ReaderModePicker(source: $source) }
            }
            if let task, let original = task.original {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(task.notes, id: \.self) { note in
                        Text(note).font(.system(size: 11)).foregroundStyle(Island.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let earlier = task.earlierRequest {
                        Text("Your request before it (first characters): \(earlier)").font(.system(size: 11))
                            .foregroundStyle(Island.secondary).lineLimit(2)
                    }
                }
                .islandFrame("task.notes")
                ReaderBody(text: source || task.display == nil ? original : task.display!, plain: source || task.display == nil)
                    .frame(minHeight: 100, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).fill(Island.card))
                    .clipShape(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous))
                    .islandFrame("task.reader.body")
                HStack(spacing: 8) {
                    Button {
                        model.copyOriginalTask()
                    } label: {
                        Label(model.isCopied(AppModel.taskToken(model.currentRef)) ? Labels.copied : Labels.copyOriginalTask,
                              systemImage: model.isCopied(AppModel.taskToken(model.currentRef)) ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(IslandPillStyle(prominent: true))
                    .disabled(!task.canCopy)
                    .islandHelp(task.canCopy ? "Copy the request exactly as it was stored, every character"
                                             : "Claude Code wrote this message, not you: there is no original task to copy")
                    Spacer(minLength: 0)
                }
                .islandFrame("task.reader.actions")
                CopyFailureLine(model: model)
            } else if model.detail.isLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 8)
            } else {
                MessageCard(title: "No task text", detail: task?.notes.first ?? "No answer is selected.",
                            symbol: "text.bubble", tint: Island.secondary, action: nil)
            }
        }
        .islandPadding(presentation)
    }
}

/// One viewport, two renderings of the same text. Each fills the viewport
/// (no measured height), so the switch is a swap inside a fixed frame.
struct ReaderBody: View {
    let text: String
    let plain: Bool

    var body: some View {
        if plain {
            VerbatimTextView(text, textColor: NSColor.white.withAlphaComponent(0.92), fontSize: 12.5)
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                MarkdownBlocksView(blocks: Markdown.blocks(text), codeLineLimit: nil, fontSize: 13)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
