import AppKit
import SwiftUI

// Phase 5 views of the island: Details (two columns: the report on the left,
// what goes to ChatGPT on the right), the project and session switcher, the
// observed work of a turn, attachments with mockup states, clipboard images
// and step 2 of the hand-off. Facts only; Claude's claims stay in its answer.

// MARK: - Layout

/// Details on this display: two columns when there is room, else one with a
/// switch. Heights are not estimated here: the island offers its whole
/// height budget (`HeightBudget`), the header and footer take what they
/// need and the scroll areas share the rest.
@MainActor
struct DetailsLayout {
    let presentation: NotchPresentation

    var metrics: IslandMetrics { IslandMetrics.of(presentation) }
    /// Content width inside the island's visible sides.
    var contentWidth: CGFloat { presentation.islandWidth - 2 * metrics.leading }
    /// Two paired rows need about 330 pt (both rows at their smallest plus
    /// the step-2 footer); shorter displays switch between the two columns.
    var twoColumns: Bool { contentWidth >= 520 && presentation.maxContentHeight >= 330 }
    var rightColumn: CGFloat { contentWidth >= 600 ? 276 : 264 }
}

/// Details' two columns as two rows: Task | Copy with Context, then
/// Answer | Attachments. Each row is as tall as the taller of its two cards'
/// natural heights, so the cards of a row end on the same line; the rows
/// share the height the island offers (`HeightBudget`). Nothing is a fixed
/// height: a short answer without files gives a short row; long content
/// scrolls inside its card. The top row never takes the room the bottom row
/// needs for a readable Answer (`minBottom`).
struct PairedRows: Layout {
    var rightWidth: CGFloat
    var columnSpacing: CGFloat
    var rowSpacing: CGFloat
    var minBottom: CGFloat = 140
    /// Phase 14.2: the top row's cap (below) used to be only Task's own
    /// natural height or 32 % of the budget — at common compact heights
    /// that gave Copy with Context one row and "+N more" with the rest of
    /// its own card empty, even though the budget had slack (the Answer's
    /// `minBottom` floor was not actually binding). These three describe
    /// the right card's own row geometry, so the top row is also floored at
    /// enough height for `rightMinRows` of them — never more than the right
    /// card would ever need, and never at the Answer's `minBottom` expense.
    var rightMinRows: Int = 0
    var rightRowHeight: CGFloat = 0
    var rightRowSpacing: CGFloat = 0

    struct Rows { let left: CGFloat; let top: CGFloat; let bottom: CGFloat }

    func rows(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Rows {
        let width = proposal.width ?? 600
        let left = max(0, width - rightWidth - columnSpacing)
        func natural(_ i: Int, _ w: CGFloat) -> CGFloat {
            i < subviews.count ? subviews[i].sizeThatFits(ProposedViewSize(width: w, height: nil)).height : 0
        }
        let topNatural = max(natural(0, left), natural(1, rightWidth))
        let bottomNatural = max(natural(2, left), natural(3, rightWidth))
        let budget = proposal.height ?? .infinity
        // Never below what the two top cards need at their smallest (their
        // fixed rows and padding): a smaller slot let a card draw past it.
        func smallest(_ i: Int, _ w: CGFloat) -> CGFloat {
            i < subviews.count ? subviews[i].sizeThatFits(ProposedViewSize(width: w, height: 0)).height : 0
        }
        // The Answer matters most: when space is short the top row is only
        // as tall as Task needs (or 32 % of the space); the context rows
        // then scroll inside their card. Phase 14.2: also at least enough
        // for `rightMinRows` rows of the right card, derived from its own
        // measurements (its smallest size is one row plus its chrome), so
        // this never assumes a fixed header height that could drift from
        // the real view.
        let topMin = max(smallest(0, left), smallest(1, rightWidth))
        // The bottom cards' fixed rows (the Answer's header, its smallest
        // scroll and the Full Report row) never get less than they need:
        // a smaller slot let the card draw onto the footer (Phase 8).
        let bottomMin = max(smallest(2, left), smallest(3, rightWidth))
        let heights = split(budget: budget, leftNatural: natural(0, left), rightNatural: natural(1, rightWidth),
                            rightSmallest: smallest(1, rightWidth), topMin: topMin, topNatural: topNatural,
                            bottomMin: bottomMin, bottomNatural: bottomNatural)
        return Rows(left: left, top: heights.top, bottom: heights.bottom)
    }

    /// The pure height arithmetic of `rows` (Phase 15: separated so tests
    /// check the real numbers, including the one-row fallback).
    func split(budget: CGFloat, leftNatural: CGFloat, rightNatural: CGFloat, rightSmallest: CGFloat, topMin: CGFloat,
               topNatural: CGFloat, bottomMin: CGFloat, bottomNatural: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        var topCap = max(leftNatural, budget * 0.32)
        if rightMinRows > 1, rightRowHeight > 0 {
            let chrome = max(0, rightSmallest - rightRowHeight)
            let floorForRows = chrome + CGFloat(rightMinRows) * rightRowHeight + CGFloat(rightMinRows - 1) * rightRowSpacing
            // Never ask for more than the right card would ever use (its own
            // full natural height, e.g. fewer rows exist than rightMinRows).
            topCap = max(topCap, min(floorForRows, rightNatural))
        }
        let top = max(topMin, min(topNatural, topCap, max(0, budget - rowSpacing - max(bottomMin, min(bottomNatural, minBottom)))))
        let bottom = max(min(bottomNatural, bottomMin), min(bottomNatural, max(0, budget - rowSpacing - top)))
        return (top, bottom)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let r = rows(proposal, subviews)
        return CGSize(width: proposal.width ?? r.left + columnSpacing + rightWidth, height: r.top + rowSpacing + r.bottom)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = rows(ProposedViewSize(width: bounds.width, height: bounds.height), subviews)
        let x2 = bounds.minX + r.left + columnSpacing, y2 = bounds.minY + r.top + rowSpacing
        let frames = [CGRect(x: bounds.minX, y: bounds.minY, width: r.left, height: r.top),
                      CGRect(x: x2, y: bounds.minY, width: rightWidth, height: r.top),
                      CGRect(x: bounds.minX, y: y2, width: r.left, height: r.bottom),
                      CGRect(x: x2, y: y2, width: rightWidth, height: r.bottom)]
        for (view, frame) in zip(subviews, frames) {
            view.place(at: frame.origin, anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

// MARK: - Details

/// Three regions that never overlap: the header (project, session, source),
/// the content (Task, Response, what goes to ChatGPT, attachments) and the
/// footer (the copies and navigation, or step 2 of the hand-off instead).
struct DetailsView: View {
    let model: AppModel
    let presentation: NotchPresentation
    let actions: SurfaceActions
    @State private var pane: Pane = .report
    @Environment(\.islandReduceMotion) private var reduceMotion
    enum Pane: String, CaseIterable { case report = "Answer", handoff = "For Review" }

    var body: some View {
        let layout = DetailsLayout(presentation: presentation)
        let facts = ReportFacts(model: model)
        VStack(alignment: .leading, spacing: layout.metrics.spacing) {
            if let error = model.projects.error, model.projects.value == nil, model.selectedImport == nil {
                MessageCard(title: "Prompt Relay can't read its history", detail: error.detail,
                            symbol: "exclamationmark.triangle", tint: Island.warning,
                            action: ("Diagnostics", { model.navigate(to: .settings) }))
                DetailsFooter(model: model, actions: actions, blocked: true, showsCopies: false)
            } else if facts.source == nil {
                SessionHeader(model: model, facts: facts)
                ClipboardNotice(model: model)
                    .islandExtraHeight("clipboard.notice", spacing: layout.metrics.spacing)
                emptyState
                DetailsFooter(model: model, actions: actions, blocked: true, showsCopies: false)
                    .islandFrame("home.footer")
            } else {
                SessionHeader(model: model, facts: facts).islandFrame("details.header")
                ClipboardNotice(model: model)
                    .islandExtraHeight("clipboard.notice", spacing: layout.metrics.spacing)
                content(layout, facts: facts)
                DetailsFooter(model: model, actions: actions, blocked: facts.blocker != nil)
                    .islandFrame("details.footer")
            }
        }
        .islandPadding(presentation)
        .animation(Island.geometry(reduceMotion: reduceMotion), value: model.activeHandoff)
        // Another answer: the Task, Answer and Attachments cards move to their
        // new sizes together with the island (same curve and duration).
        .animation(Island.geometry(reduceMotion: reduceMotion), value: model.currentRef)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.projects.value?.isEmpty == true {
            MessageCard(title: "Set up Prompt Relay",
                        detail: "Connect Claude Code or Codex and choose a project. Nothing is captured until you do.",
                        symbol: "folder.badge.plus", tint: Island.accent,
                        action: ("Set Up", { model.navigate(to: .setup) }))
        } else {
            MessageCard(title: "No answer yet",
                        detail: "When a connected agent finishes in a captured project, its answer appears here.",
                        symbol: "text.bubble", tint: Island.secondary,
                        action: ("Check Setup", { model.navigate(to: .setup) }))
        }
    }

    @ViewBuilder
    private func content(_ layout: DetailsLayout, facts: ReportFacts) -> some View {
        if layout.twoColumns {
            PairedRows(rightWidth: layout.rightColumn, columnSpacing: Island.Space.l, rowSpacing: layout.metrics.spacing,
                      rightMinRows: 2, rightRowHeight: HandoffContentsCard.rowHeight, rightRowSpacing: HandoffContentsCard.rowSpacing) {
                TaskCard(facts: facts, expanded: Binding(get: { model.taskExpanded }, set: { model.taskExpanded = $0 }), lines: layout.metrics.compact ? 1 : 2,
                         viewFull: { model.navigate(to: .taskReader) }).islandFrame("card.task")
                HandoffContentsCard(model: model).islandFrame("card.handoff")
                ResponseCard(model: model, facts: facts) { model.navigate(to: .reader) }
                AttachmentsCard(model: model).islandFrame("card.attachments")
            }
            .environment(\.cardFillsRow, true)
        } else {
            VStack(alignment: .leading, spacing: layout.metrics.spacing) {
                Picker("", selection: $pane) {
                    ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()   // its own width, left-aligned with the cards (was centred in 220 pt)
                if pane == .report { reportColumn(layout, facts: facts) } else { handoffColumn(layout, facts: facts) }
            }
        }
    }

    /// Short displays, one column: while step 2 is the footer, the Task card
    /// moves to the For Review pane. Header, picker, Task, Answer and step 2
    /// did not fit the 300-pt floor together (step 2 ended 15 pt below the
    /// island, Phase 7.1); the Answer keeps its room.
    private var taskInReviewPane: Bool { model.activeHandoff != nil }

    private func reportColumn(_ layout: DetailsLayout, facts: ReportFacts) -> some View {
        VStack(alignment: .leading, spacing: layout.metrics.spacing) {
            if !taskInReviewPane { taskCard(layout, facts: facts) }
            ResponseCard(model: model, facts: facts) { model.navigate(to: .reader) }
        }
    }

    private func taskCard(_ layout: DetailsLayout, facts: ReportFacts) -> some View {
        TaskCard(facts: facts, expanded: Binding(get: { model.taskExpanded }, set: { model.taskExpanded = $0 }), lines: layout.metrics.compact ? 1 : 2,
                 viewFull: { model.navigate(to: .taskReader) }, inline: presentation.maxContentHeight < 300 && !taskInReviewPane)
            .islandFrame("card.task")
    }

    private func handoffColumn(_ layout: DetailsLayout, facts: ReportFacts) -> some View {
        VStack(alignment: .leading, spacing: Island.Space.m) {
            if taskInReviewPane { taskCard(layout, facts: facts) }
            HandoffContentsCard(model: model).islandFrame("card.handoff")
            AttachmentsCard(model: model).islandFrame("card.attachments")
        }
    }
}

/// Project ⌄ · session ⌄ on the left; source and time on the right; the
/// "New in …" chip when another session finished meanwhile.
struct SessionHeader: View {
    let model: AppModel
    let facts: ReportFacts

    var body: some View {
        HStack(spacing: 6) {
            Button { model.navigate(to: .projects) } label: {
                HStack(spacing: 5) {
                    Text(projectTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Island.primary)
                        .lineLimit(1).truncationMode(.middle).layoutPriority(2)
                    if let session = sessionTitle {
                        Text("·").foregroundStyle(Island.tertiary)
                        // Lowest priority: the session title truncates before source and status.
                        Text(session).font(.system(size: 12.5)).foregroundStyle(Island.secondary)
                            .lineLimit(1).truncationMode(.tail).layoutPriority(0)
                    }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Island.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Project \(projectTitle), session \(sessionTitle ?? "none"). Choose project and session")
            .islandHelp("Switch project or conversation")
            Spacer(minLength: 6)
            // Phase 17: pinned / not on the newest answer is always said
            // here, with the way back — never only in a tooltip or Settings.
            if model.sessionPinned || (model.isOffLatest && model.newAnswerElsewhere == nil) {
                LatestChip(model: model, pinOnly: model.newAnswerElsewhere != nil)
            }
            if let other = model.newAnswerElsewhere {
                NewElsewhereChip(model: model, answer: other)
            } else if facts.source != nil, !model.sessionPinned, !model.isOffLatest {
                SourceLine(model: model, facts: facts)
            }
        }
    }

    private var projectTitle: String {
        if let report = model.selectedImport { return report.projectName ?? "Cloud import" }
        return model.selectedProject.map(Wording.projectName) ?? "Prompt Relay"
    }

    private var sessionTitle: String? {
        if model.selectedImport != nil { return "imported report" }
        return model.selectedSession.map(Wording.sessionTitle)
    }
}

struct NewElsewhereChip: View {
    let model: AppModel
    let answer: AppModel.ReadyAnswer

    var body: some View {
        HStack(spacing: 4) {
            Button { model.openNewAnswerElsewhere() } label: {
                HStack(spacing: 4) {
                    Circle().fill(Island.accent).frame(width: 6, height: 6)
                    Text("New in \(label)").lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Island.accent)
                .padding(.horizontal, 8).frame(height: 20)
                .background(Capsule().fill(Island.accent.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .islandHelp("Open the new answer")
            Button { model.dismissNewAnswerElsewhere() } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Island.tertiary)
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .islandHelp("Dismiss")
        }
        .frame(maxWidth: 240, alignment: .trailing)
    }

    private var label: String {
        let session = model.allSessions.first { $0.sessionKey == answer.sessionKey }
        let title = session.map(Wording.sessionTitle) ?? answer.projectName
        return title.count > 26 ? String(title.prefix(25)) + "…" : title
    }
}

/// The footer: the two copies and the navigation icons, or, after Copy for
/// ChatGPT with files, step 2 in their place (never on top of the content).
struct DetailsFooter: View {
    let model: AppModel
    let actions: SurfaceActions
    let blocked: Bool
    var showsCopies = true

    var body: some View {
        VStack(alignment: .leading, spacing: Island.Space.s) {
            if showsCopies, let step = model.activeHandoff {
                HandoffFooter(model: model, step: step)
                    .islandFrame("details.handoff")
                    .transition(.opacity)
            } else {
                HStack(spacing: Island.Space.m) {
                    if showsCopies { CopyActions(model: model, blocked: blocked) }
                    Spacer(minLength: 4)
                    NavigationIcons(model: model, actions: actions)
                }
                .islandFrame("home.actions")
                .transition(.opacity)
            }
            CopyFailureLine(model: model)
        }
    }
}

/// History, Clipboard and Settings as icons; Import and Quit in the ⋯ menu.
struct NavigationIcons: View {
    let model: AppModel
    let actions: SurfaceActions

    var body: some View {
        HStack(spacing: 2) {
            IconLink(symbol: "tray", label: "Results Inbox", help: "Final results of every agent, newest first · ⌘I",
                     badge: model.unreadResultCount > 0, badgeTint: Island.success) {
                model.navigate(to: .inbox)
            }
            IconLink(symbol: "tray.full", label: "History", help: "Browse previous tasks and answers") {
                model.navigate(to: .history)
            }
            IconLink(symbol: "doc.on.clipboard", label: "Clipboard",
                     help: "Your recent copied text and images") {
                model.navigate(to: .clipboard)
            }
            IconLink(symbol: "gearshape", label: "Settings", help: "Customize Prompt Relay", badge: !AppBuild.otherBuildsRunning().isEmpty) {
                model.navigate(to: .settings)
            }
            .keyboardShortcut(",", modifiers: .command)
            Menu {
                Button(Labels.importAIResult + "…") { model.navigate(to: .importReport) }
                Divider()
                if let ref = model.currentRef {
                    Button(model.isInPack(ref) ? "Remove from Context Pack" : "Add to Context Pack") { model.togglePack(ref) }
                }
                Button("Context Pack (\(model.packRefs.count))…") { model.openContextPack() }
                Button("Quick Tour…") { model.startTour() }
                Button("Handoff History…") { model.navigate(to: .handoffHistory) }
                    .disabled(model.handoffHistory.isEmpty)
                Divider()
                Button("Quit Prompt Relay") { actions.quit() }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More")
            .islandHelp("Import an AI result, Context Pack, or quit")
        }
        .foregroundStyle(Island.secondary)
    }
}

struct IconLink: View {
    let symbol: String
    let label: String
    let help: String
    var badge = false
    var badgeTint: Color = Island.warning
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .medium))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: Island.rowRadius, style: .continuous).fill(hovering ? Island.hover : .clear))
                .overlay(alignment: .topTrailing) {
                    if badge { Circle().fill(badgeTint).frame(width: 5, height: 5).offset(x: -3, y: 3) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .islandHelp(help)
    }
}

/// Only failures need words; a success shows on the button itself.
struct CopyFailureLine: View {
    let model: AppModel

    var body: some View {
        if case .failed(let reason) = model.copyFeedback {
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(Island.error)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
                .islandExtraHeight("copy.failure", spacing: Island.Space.s)
        }
    }
}

// MARK: - What goes to ChatGPT

/// What Copy with Context puts together for this report, one row per part
/// with a short plain fact. "Show details" explains each part and its
/// limits in place (no second screen, no second formatter): the package
/// itself is built only when you copy.
struct HandoffContentsCard: View {
    let model: AppModel
    /// The one part whose explanation is open (one at a time).
    @State private var explained: String?
    /// Phase 14: the rows' viewport, to say how many rows are below it.
    @State private var visibleHeight: CGFloat?
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Phase 7.2: the title keeps its natural width and "Preview" never
            // wraps; when the column is narrow the button is just the eye.
            // (Before, a Standard/Full control squeezed them: the title took
            // three lines and "Preview" broke inside the word.)
            HStack(spacing: 6) {
                Caption(Labels.copyWithContext, role: Island.accent)
                    .lineLimit(1).fixedSize()
                    .layoutPriority(2)
                    .islandFrame("handoff.title")
                Spacer(minLength: 4)
                let hidden = Self.hiddenRows(count: Self.rows(model: model).count, visibleHeight: visibleHeight, explained: explained != nil)
                if hidden > 0 {
                    // Rows below the card's edge are never drawn half; this
                    // says they are there (scroll or Preview shows them).
                    Text("+\(hidden) more").font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1).fixedSize()
                        .accessibilityLabel("\(hidden) more parts below; scroll to see them")
                        .islandFrame("handoff.more")
                }
                ViewThatFits(in: .horizontal) {
                    previewButton(label: true)
                    previewButton(label: false)
                }
                .layoutPriority(1)
                .islandFrame("handoff.preview")
            }
            .islandFrame("handoff.header")
            let rows = Self.rows(model: model)
            BoundedScroll(minHeight: Self.rowHeight, onVisibleHeight: { visibleHeight = $0 }, frameID: "handoff.viewport") {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(rows, id: \.title) { row in
                HStack(spacing: 4) {
                    if row.opensActivity {
                        Button { model.navigate(to: .activity) } label: { label(row) }
                            .buttonStyle(.plain)
                            .islandHelp("Inspect recorded commands")
                    } else {
                        label(row)
                    }
                    Button {
                        withAnimation(Island.geometry(reduceMotion: reduceMotion)) { explained = explained == row.title ? nil : row.title }
                    } label: {
                        Image(systemName: explained == row.title ? "info.circle.fill" : "info.circle")
                            .font(.system(size: 10)).foregroundStyle(explained == row.title ? Island.accent : Island.tertiary)
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(explained == row.title ? "Hide explanation" : "Explain \(row.title)")
                }
                .scrollRow(row.title)
                .islandFrame("handoff.row.\(row.title)")
            }
            if let open = rows.first(where: { $0.title == explained }) {
                BoundedScroll(maxHeight: 96) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(open.explanation.lines, id: \.0) { label, text in
                            (Text(label + "  ").font(.system(size: 11, weight: .semibold)).foregroundStyle(Island.tertiary)
                             + Text(text).font(.system(size: 11)).foregroundStyle(Island.secondary))
                                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.trailing, 4)
                }
                .padding(7)
                .background(RoundedRectangle(cornerRadius: Island.rowRadius, style: .continuous).fill(Island.cardRaised))
                .transition(.opacity)
                .scrollRow("explanation")
                .islandFrame("handoff.explanation")
            }
            }
            .padding(.trailing, 2)
            }
            .islandFrame("handoff.rows")
        }
        .islandCard()
        .onChange(of: model.currentRef) { explained = nil }
    }

    static let rowHeight: CGFloat = 22
    static let rowSpacing: CGFloat = 5

    /// Rows that do not fit the viewport (whole rows only are shown).
    static func hiddenRows(count: Int, visibleHeight: CGFloat?, explained: Bool) -> Int {
        guard let h = visibleHeight, !explained else { return 0 }
        let fit = Int(((h + rowSpacing + 0.5) / (rowHeight + rowSpacing)).rounded(.down))
        return max(0, count - fit)
    }

    private func previewButton(label: Bool) -> some View {
        Button { Task { await model.openPackPreview() } } label: {
            HStack(spacing: 3) {
                Image(systemName: "eye").font(.system(size: 9.5, weight: .semibold))
                if label { Text("Preview").font(.system(size: 11, weight: .medium)).lineLimit(1) }
            }
            .fixedSize()
            .frame(minWidth: 18, minHeight: 18)
            .foregroundStyle(Island.secondary).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.currentRef == nil)
        .accessibilityLabel("Preview full context")
        .islandHelp("Preview exactly what will be copied")
    }

    struct Row: Equatable {
        let symbol: String
        let title: String
        let detail: String
        var alert = false
        var opensActivity = false
        let explanation: Explanation
    }

    /// Phase 8: every ⓘ answers the same four questions, in this order.
    struct Explanation: Equatable {
        /// What this part of the package is.
        let what: String
        /// Where its data comes from.
        let source: String
        /// What Prompt Relay itself read or checked on this Mac.
        let checked: String
        /// What it does not know.
        let unknown: String

        var lines: [(String, String)] { [("What", what), ("Source", source), ("Checked here", checked), ("Not known", unknown)] }
    }

    /// The parts of the package for the report shown, as plain facts.
    @MainActor static func rows(model: AppModel) -> [Row] {
        var rows: [Row] = []
        let task = ReportFacts(model: model).task
        let taskDetail: String = {
            switch task {
            case .unavailable: return "answer only"
            case .automated: return "automatic turn"
            default: return "original text"
            }
        }()
        let imported = model.selectedImport != nil
        rows.append(Row(symbol: "text.quote", title: "Request & answer", detail: taskDetail, explanation: Explanation(
            what: "Your request and the agent's complete answer, each included once, character for character.",
            source: imported ? "The text you pasted into Import AI Result." : "The source adapter's prompt and final-response events, stored on this Mac.",
            checked: imported ? "Nothing beyond storing it as you pasted it." : "That both belong to this session and turn (by prompt id or order, as labelled).",
            unknown: "Whether what the answer claims is true: those claims are marked “Reported by agent”.")))
        if model.selectedImport != nil {
            rows.append(Row(symbol: "terminal", title: "Commands", detail: "not available", explanation: Explanation(
                what: "Commands the assistant ran.",
                source: "None: an imported result comes from a place Prompt Relay could not watch.",
                checked: "Nothing.",
                unknown: "Which commands ran, and with what result.")))
        } else if let turn = model.selectedTurn {
            let captureOn = model.selectedProject?.captureEnabled ?? true
            let observedDetail = model.selectedObservedDetail ?? turn.observedDetail
            let failed = turn.observed.map { max($0.commandsNonzero ?? 0, $0.runsNonzero) } ?? 0
            rows.append(Row(symbol: "terminal", title: "Commands", detail: commands(turn.observed, captureOn: captureOn, detail: observedDetail),
                            alert: failed > 0, opensActivity: true, explanation: turn.observed == nil
                                ? Explanation(what: "Commands observed during this answer.",
                                              source: captureOn ? "None recorded (plugin before 0.3.0, or captured before tool events)." : "None: capture is off for this project.",
                                              checked: "Nothing.",
                                              unknown: "Whether the agent ran any commands; no record does not mean none ran.")
                                : Explanation(what: "Each observed shell command: its text, exit code and duration; › opens Failure Inspector.",
                                              source: "The source adapter's observed tool events on this Mac.",
                                              checked: "The exit code of each command as the hook reported it; for a failed test or build, its last lines after a secret scan.",
                                              unknown: "Whether the task is done. With a pipe or `;` the exit code is the last process's. Full output is not kept.")))
            if let observed = turn.observed {
                rows.append(Row(symbol: "doc.badge.ellipsis", title: "Files changed",
                                detail: observed.filesChanged == 0 ? "none seen" : Labels.filesChanged(observed.filesChanged).replacingOccurrences(of: " changed", with: ""),
                                explanation: Explanation(
                                    what: "Files the agent edited or wrote during this answer.",
                                    source: "Paths from observed file operations.",
                                    checked: "Only that an edit tool ran on each path. The files were not opened or compared.",
                                    unknown: "Whether the edits are correct, still on disk, or the only changes. Files the answer merely mentions are not listed here.")))
            }
            rows.append(Row(symbol: "arrow.triangle.branch", title: "Git status", detail: "checked when you copy", explanation: Explanation(
                what: "Branch, HEAD and uncommitted files of the project.",
                source: "Git, run read-only on this Mac when the package is built.",
                checked: "The repository's state at that moment (no fetch, no hooks run).",
                unknown: "Which of those changes the agent made, and anything that changed after the copy.")))
        }
        let n = model.handoffAttachments(for: model.currentRef).count
        rows.append(Row(symbol: "paperclip", title: "Attachments", detail: n == 0 ? "none chosen" : "\(n) chosen", explanation: Explanation(
            what: n == 0 ? "Files you choose below are named in the text and handed over after it." : "The chosen files: named in the text, handed over after it as files.",
            source: "Snapshots you added, stored by Prompt Relay (not the live files).",
            checked: "That each snapshot exists when the package is built; a missing one is reported, not skipped silently.",
            unknown: "Whether the other assistant received them: Prompt Relay cannot see another app.")))
        return rows
    }

    /// One fact, failures first. Distinguishes nothing recorded (older
    /// plugin, capture off) from no tools used. Phase 14.2: with the per-
    /// command detail loaded, failures are named by kind — "1 test failed"
    /// is never conflated with "1 command failed" (a diagnostic grep,
    /// plutil, or similar shell call that is not a test or a build).
    static func commands(_ o: ObservedCounts?, captureOn: Bool, detail: ObservedDetail? = nil) -> String {
        guard let o else { return captureOn ? "not recorded" : "capture off" }
        if o.toolEvents == 0 { return "none run" }
        if let detail {
            let main = detail.commands.filter { $0.agentType == nil }
            let breakdown = FailureBreakdown.make(main)
            if !breakdown.isEmpty { return breakdown.summary }
            // Phase 15.1: an exit 0 counts as completed only when it is the
            // test's/build's own; `swift test | tee log` is "unclear".
            let passed = main.filter { FailureBreakdown.stageResult($0) == .passed }.count
            let unclear = main.filter { FailureBreakdown.stageResult($0) == .unclear }.count
            if passed + unclear > 0 {
                return [passed > 0 ? "\(passed) completed" : nil, unclear > 0 ? "\(unclear) unclear" : nil].compactMap { $0 }.joined(separator: " · ")
            }
        } else {
            let failed = max(o.commandsNonzero ?? 0, o.runsNonzero)
            if failed > 0 { return "\(failed) command\(failed == 1 ? "" : "s") failed" }
        }
        if o.runsExitZero > 0 { return "\(o.runsExitZero) completed" }
        return o.toolEvents == 1 ? "1 event" : "\(o.toolEvents) events"
    }

    private func label(_ row: Row) -> some View {
        HStack(spacing: 6) {
            Image(systemName: row.symbol).font(.system(size: 10.5)).frame(width: 14).foregroundStyle(Island.tertiary)
            Text(row.title).foregroundStyle(Island.primary).lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            Text(row.detail).font(.system(size: 11)).foregroundStyle(row.alert ? Island.error : Island.tertiary)
                .lineLimit(1).truncationMode(.tail)
            if row.opensActivity { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Island.tertiary) }
        }
        .font(.system(size: 11.5))
        .contentShape(Rectangle())
    }
}

// MARK: - Attachments

struct AttachmentsCard: View {
    let model: AppModel

    var body: some View {
        let ref = model.currentRef
        let files = model.attachments(for: ref).filter { $0.mockupID == nil }
        let materials = model.materials(for: ref)
        let suggestions = model.suggestions
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Caption("Attachments", role: Island.review)
                let summary = model.materialSummary(for: ref)
                if !summary.isEmpty { Text("\(summary.documents + summary.images + summary.mockups + summary.links) selected")
                    .font(.system(size: 11)).foregroundStyle(Island.tertiary) }
                Spacer(minLength: 0)
                Menu {
                    Button("Files…") { model.chooseFiles() }
                    Button("From Clipboard…") { model.openClipboard(.images) }
                    Button("Capture Final Window…") { model.captureFinalWindow() }
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 22).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(model.reportStore == nil || ref == nil || model.isPresentingSystemDialog)
                .accessibilityLabel("Add attachments")
                .islandHelp("Attach files to this answer")
            }
            BoundedScroll(minHeight: 34) {
                VStack(alignment: .leading, spacing: 3) {
                    // Phase 16: the outcome of the last Add first, where it is seen
                    // without scrolling (it was the last row and often out of view).
                    if let message = model.attachmentMessage {
                        Label(message, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(Island.warning)
                            .fixedSize(horizontal: false, vertical: true).scrollRow("attachments.problem")
                            .accessibilityLabel(message)
                    } else if let notice = model.attachmentNotice, model.attachmentNoticeKey == ref?.key {
                        Label(notice, systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(Island.secondary)
                            .fixedSize(horizontal: false, vertical: true).scrollRow("attachments.notice")
                            .accessibilityLabel(notice)
                    }
                    CompletenessLine(model: model).scrollRow("completeness")
                    AutoCaptureStatusLine(model: model).scrollRow("autocapture")
                    if !suggestions.isEmpty {
                        HStack {
                            Text("From this turn").font(.system(size: 11, weight: .semibold)).foregroundStyle(Island.tertiary)
                            Spacer()
                            if suggestions.filter(\.attachable).count > 1 {
                                Button("Add all") { model.acceptAll(suggestions.filter(\.attachable)) }.buttonStyle(.plain)
                                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Island.accent)
                            }
                        }
                        .scrollRow("suggestions.header")
                        ForEach(suggestions) { SuggestionRow(model: model, suggestion: $0).scrollRow("s.\($0.id)") }
                    }
                    ForEach(materials.filter { $0.kind == .mockup }) { MockupRow(model: model, material: $0).scrollRow("m.\($0.id)") }
                    ForEach(files) { AttachmentRow(model: model, attachment: $0).scrollRow("a.\($0.id)").islandFrame("attachment.row.\($0.id)") }
                    ForEach(materials.filter { $0.kind == .link }) { LinkRow(model: model, material: $0).scrollRow("l.\($0.id)") }
                    if suggestions.isEmpty && files.isEmpty && materials.isEmpty {
                        Text("Nothing attached. Documents, images and mockups the agent prepares appear here.")
                            .font(.system(size: 11)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.trailing, 4)
            }
        }
        .islandCard()
    }
}

/// Phase 14: why an answer has no auto screenshot, when the user can do
/// something about it. Nothing when all is well (the image is listed).
/// Phase 14 / 14.1: why an answer has no auto screenshot, and the one-click
/// recovery for the most common case (Screen Recording permission). A
/// compact title + one short sentence, never a paragraph; the buttons say
/// what to do, so the explanation does not have to.
struct AutoCaptureStatusLine: View {
    let model: AppModel
    /// Set while "Check Again" is awaiting a real capture (disables the
    /// button; never shown as "granted" before that result is back).
    @State private var checking = false

    var body: some View {
        if let status = model.autoCaptureStatus(for: model.currentRef), status != .captured {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: symbol(for: status))
                        .font(.system(size: 10)).foregroundStyle(Island.tertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        if let title = status.title {
                            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Island.secondary)
                        }
                        if let detail = status.detail {
                            Text(detail).font(.system(size: 11)).foregroundStyle(status == .pending ? Island.tertiary : Island.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // Phase 14.1: a Debug and a Release copy show as two
                        // separate apps in Screen Recording — name which one
                        // this is, so the grant lands on the right copy.
                        if (status.offersPermissionRecovery || status.offersRestartRecovery), AppBuild.isDebugBuild {
                            Text(AutoCaptureStatus.debugBuildPermissionHint)
                                .font(.system(size: 10.5)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if status.offersPermissionRecovery {
                    HStack(spacing: 10) {
                        Button("Open Screen Recording Settings") { model.openScreenRecordingSettings() }
                        checkAgainButton
                    }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Island.accent)
                    .islandFrame("autocapture.permission.actions")
                } else if status.offersRestartRecovery {
                    HStack(spacing: 10) {
                        Button("Quit Prompt Relay") { model.quitApp() }
                        checkAgainButton
                    }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Island.accent)
                    .islandFrame("autocapture.restart.actions")
                } else if status.offersLink {
                    HStack(spacing: 10) {
                        Button("Link Window…") { model.linkAutoCaptureWindowToConversation() }
                            .disabled(model.autoCaptureBlocker != nil || model.isPresentingSystemDialog)
                            .islandHelp("Pick the window that shows this conversation; its next final answers are captured automatically")
                        Button("Capture Now…") { model.captureFinalWindow() }
                            .disabled(model.isPresentingSystemDialog)
                            .islandHelp("Take one picture of a window now, without linking it")
                        if status.offersRecheck { checkAgainButton }
                    }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Island.accent)
                    .islandFrame("autocapture.link.actions")
                }
                // Phase 15.2: always reachable, even when the problem looks
                // like a missing link (the owner could not find it there).
                if status.offersSettingsShortcut && !status.offersPermissionRecovery {
                    Button("Open Screen Recording Settings") { model.openScreenRecordingSettings() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Island.accent)
                        .islandHelp("System Settings → Privacy & Security → Screen & System Audio Recording")
                        .islandFrame("autocapture.settings.shortcut")
                }
            }
            .padding(.vertical, 2)
            .islandFrame("attachments.autocapture")
        }
    }

    private var checkAgainButton: some View {
        Button(checking ? "Checking…" : "Check Again") {
            checking = true
            Task {
                _ = await model.checkAutoCaptureAccess(for: model.currentRef)
                checking = false
            }
        }
        .disabled(checking)
        .accessibilityLabel(checking ? "Checking permission" : "Check permission again")
    }

    private func symbol(for status: AutoCaptureStatus) -> String {
        switch status {
        case .pending: return "camera.viewfinder"
        case .permissionRequired, .restartRequired: return "lock.shield"
        default: return "camera.metering.unknown"
        }
    }
}

struct SelectBox: View {
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .font(.system(size: 12)).foregroundStyle(selected ? Island.accent : Island.tertiary)
                .frame(width: 16, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selected ? "Included in the hand-off" : "Not included")
        .islandHelp(selected ? "Included in the file transfer" : "Not included")
    }
}

struct AttachmentRow: View {
    let model: AppModel
    let attachment: ReportAttachment

    var body: some View {
        let url = model.attachmentURL(attachment)
        let available = model.isAttachmentAvailable(attachment)
        let memory = attachment.isInMemory
        HStack(spacing: 6) {
            SelectBox(selected: attachment.isSelected) { model.setSelected(attachment, !attachment.isSelected) }
            Button { model.openAttachmentPreview(attachment) } label: {
                HStack(spacing: 6) {
                    KindIcon(kind: attachment.effectiveKind, url: url,
                             memory: memory ? model.attachmentData(attachment).map { (attachment.id, $0) } : nil)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(attachment.originalFilename).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Island.primary)
                            .lineLimit(1).truncationMode(.middle)
                        let drift = available ? model.snapshotDrift(attachment) : nil
                        Text(!available ? (memory ? "No longer in memory" : "Missing")
                             : drift == .changed ? "Snapshot from the answer · the original has changed since"
                             : drift == .missing ? "\(AppModel.attachmentStatus(attachment)) · original no longer there"
                             : "\(AppModel.attachmentStatus(attachment)) · \(ReviewPack.type(attachment)) · \(ReviewPack.size(attachment.byteCount))\(memory ? " · in memory" : "")")
                            .font(.system(size: 11)).foregroundStyle(!available || drift == .changed ? Island.warning : Island.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!available)
            .accessibilityLabel("Preview \(attachment.originalFilename)")
            Menu {
                Button("Preview") { model.openAttachmentPreview(attachment) }.disabled(!available)
                if memory {
                    // Phase 10: a snapshot in memory has no file to open or show.
                    Button("Copy Image") { model.copyAttachment(attachment) }.disabled(!available)
                    // Phase 14: recapture by hand (the macOS picker), added beside it.
                    Button("Capture Window Again…") { model.captureFinalWindow() }.disabled(model.isPresentingSystemDialog)
                } else {
                    Button("Open in Default App") { if let url { NSWorkspace.shared.open(url) } }.disabled(url == nil)
                    Button("Show in Finder") { model.revealAttachmentsForHandoff([attachment]) }.disabled(url == nil)
                    Button("Copy File") { model.copyAttachmentFiles([attachment]) }.disabled(url == nil)
                }
                Divider()
                Button("Remove from This Report") { model.removeAttachment(attachment) }
            } label: {
                // Phase 11: a 24 × 24 pt target (was the ~16 pt glyph alone).
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Actions for \(attachment.originalFilename)")
        }
        .frame(height: 30)
        .padding(.horizontal, 3)
        .background(RoundedRectangle(cornerRadius: Island.rowRadius, style: .continuous).fill(attachment.isSelected ? Island.selected : .clear))
        .onDrag { model.dragProvider(for: attachment) }
        .islandHelp(memory ? (attachment.effectiveSource == .windowCapture
                              ? "Auto screenshot taken by Prompt Relay, kept in memory only — not a file the agent made"
                              : "Window snapshot kept in memory only — not saved as a file") : "Preview this attachment")
    }
}

struct KindIcon: View {
    let kind: AttachmentKind
    let url: URL?
    /// Phase 10: (id, bytes) of an in-memory snapshot.
    var memory: (id: String, data: Data)? = nil

    var body: some View {
        Group {
            if kind == .image, let memory, let thumb = Thumbnails.image(data: memory.data, key: memory.id, maxPixels: 64) {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
            } else if kind == .image, let url, let thumb = Thumbnails.image(for: url, maxPixels: 64) {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: kind == .pdf ? "doc.richtext" : kind == .document ? "doc.text" : "photo")
                    .font(.system(size: 11)).foregroundStyle(Island.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .background(Island.code)
        .clipShape(RoundedRectangle(cornerRadius: Island.smallRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Island.smallRadius, style: .continuous))   // the `.fill` overflow takes no clicks
    }
}

struct SuggestionRow: View {
    let model: AppModel
    let suggestion: AppModel.Suggestion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: suggestion.kind == .mockup ? "rectangle.on.rectangle" : "doc.badge.plus")
                .font(.system(size: 11)).foregroundStyle(Island.accent).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(suggestion.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Island.primary)
                    .lineLimit(1).truncationMode(.middle)
                Text(suggestion.statusLine)
                    .font(.system(size: 11)).foregroundStyle(suggestion.isWarning ? Island.warning : Island.tertiary)
                    .lineLimit(1).truncationMode(.tail)
                    .islandHelp(suggestion.statusLine)
                    .accessibilityLabel(suggestion.statusLine)
            }
            Spacer(minLength: 0)
            Button("Add") { model.accept(suggestion) }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Island.accent)
                .disabled(!suggestion.attachable)
                .islandHelp(suggestion.kind == .mockup ? "Add this mockup"
                      : "Attach a copy of this file to this answer (selected for Copy with Context and drag)")
                .accessibilityLabel("Attach \(suggestion.title)")
        }
        .frame(height: 30)
    }
}

struct MockupRow: View {
    let model: AppModel
    let material: ReportMaterial

    var body: some View {
        let captured = material.states.filter { $0.status == .captured }.count
        HStack(spacing: 6) {
            SelectBox(selected: material.selected) { model.setSelected(material, !material.selected) }
            Image(systemName: "rectangle.on.rectangle").font(.system(size: 11)).foregroundStyle(Island.secondary)
                .frame(width: 24, height: 24).background(Island.code).clipShape(RoundedRectangle(cornerRadius: Island.smallRadius))
            VStack(alignment: .leading, spacing: 0) {
                Text(material.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Island.primary).lineLimit(1)
                Text("\(captured) of \(material.states.count) states saved").font(.system(size: 11))
                    .foregroundStyle(Island.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { model.openMockup(material) } label: {
                HStack(spacing: 2) { Text("States"); Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)) }
            }
            .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Island.secondary)
        }
        .frame(height: 30)
        .islandHelp("Review this mockup")
    }
}

struct LinkRow: View {
    let model: AppModel
    let material: ReportMaterial

    var body: some View {
        HStack(spacing: 6) {
            SelectBox(selected: material.selected) { model.setSelected(material, !material.selected) }
            Image(systemName: "link").font(.system(size: 11)).foregroundStyle(Island.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(material.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Island.primary).lineLimit(1)
                Text(material.isPrivateLink ? "Private link: the reviewer cannot open it" : "Link, not opened by Prompt Relay")
                    .font(.system(size: 11)).foregroundStyle(material.isPrivateLink ? Island.warning : Island.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { model.removeMaterial(material) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(Island.tertiary).accessibilityLabel("Remove link")
        }
        .frame(height: 30)
    }
}

// MARK: - Step 2 of the hand-off

/// Step 2, in place of the footer: the text is on the clipboard; now the
/// files chosen at the copy. When the choice changed since, nothing old is
/// handed over: the step asks for a new Copy for ChatGPT.
struct HandoffFooter: View {
    let model: AppModel
    let step: AppModel.HandoffStep
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        // One row when it fits (it saves a line on short displays), else two.
        // One row, then status over the buttons, then (narrow, larger
        // text) the buttons on two rows: never wider than the island.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Island.Space.m) {
                status(short: true).fixedSize()
                buttons(compact: true)
            }
            VStack(alignment: .leading, spacing: Island.Space.s) {
                status(short: false)
                HStack(spacing: Island.Space.m) { buttons(compact: false) }
            }
            VStack(alignment: .leading, spacing: Island.Space.s) {
                status(short: true)
                HStack(spacing: Island.Space.m) { fileButtons; Spacer(minLength: 0) }
                HStack(spacing: Island.Space.m) { textAgain(compact: false); Spacer(minLength: 0); done }
            }
        }
        .padding(.horizontal, Island.Space.l).padding(.vertical, Island.Space.m)
        .islandExtraHeight("handoff", replacing: Island.controlHeight)
        .background(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).fill(Island.card))
        .animation(Island.geometry(reduceMotion: reduceMotion), value: model.copiedToken)
    }

    private func status(short: Bool) -> some View {
        let changed = model.handoffSelectionChanged
        let replaced = model.handoffTextReplaced
        return HStack(spacing: 6) {
            Image(systemName: changed || replaced ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(changed || replaced ? Island.warning : Island.success)
            Text(changed ? (short ? "Files changed" : "The chosen files changed after the text was copied.")
                 : Self.statusText(step, replaced: replaced, short: short))
                .foregroundStyle(Island.primary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .monospacedDigit()
            if !short { Spacer(minLength: 0) }
        }
        .font(.system(size: 11.5))
        .accessibilityElement(children: .combine)
        .islandFrame("handoff.status")
    }

    /// "Text copied · 12,486 characters · Now 3 files"; compact
    /// "12,486 chars copied · 3 files next"; after a close "Continue Transfer
    /// · 3 Files". The count is of the text the clipboard confirmed.
    static func statusText(_ step: AppModel.HandoffStep, replaced: Bool, short: Bool) -> String {
        let n = step.characters.formatted()
        let files = step.fileCount == 1 ? "1 file" : "\(step.fileCount) files"
        if replaced { return short ? "Text replaced on clipboard" : "The clipboard no longer holds the text (\(n) characters)." }
        if step.resumed { return "Continue Transfer · \(step.fileCount == 1 ? "1 File" : "\(step.fileCount) Files")" + (short ? "" : " · text \(n) characters") }
        return short ? "\(n) chars copied · \(files) next" : "Text copied · \(n) characters · Now \(files)"
    }

    @ViewBuilder
    private func buttons(compact: Bool) -> some View {
        textAgain(compact: compact)
        fileButtons
        Spacer(minLength: 0)
        done
    }

    /// Compact (one-row layout): an icon, so step 2 keeps one line.
    @ViewBuilder
    private func textAgain(compact: Bool) -> some View {
        if !model.handoffSelectionChanged, model.handoffTextReplaced || step.resumed, compact {
            IconLink(symbol: model.isCopied(AppModel.reviewToken(step.ref)) ? "checkmark" : "text.badge.checkmark",
                     label: "Copy Text Again",
                     help: "Copy the same text again") {
                model.copyHandoffTextAgain()
            }
            .foregroundStyle(model.handoffTextReplaced ? Island.warning : Island.secondary)
        } else if !model.handoffSelectionChanged, model.handoffTextReplaced || step.resumed {
            Button { model.copyHandoffTextAgain() } label: {
                Label(model.isCopied(AppModel.reviewToken(step.ref)) ? Labels.copied : "Copy Text Again", systemImage: "text.badge.checkmark")
            }
            .buttonStyle(IslandPillStyle(prominent: model.handoffTextReplaced))
            .islandHelp("Copy the same text again")
        }
    }

    @ViewBuilder
    private var fileButtons: some View {
        if model.handoffSelectionChanged {
            Button { Task { await model.copySelectedContext() } } label: {
                Label(Labels.copyWithContext + " Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(IslandPillStyle(prominent: true))
            .islandHelp("Update the copied text with selected files")
        } else {
            Button { model.copyHandoffFiles() } label: {
                Label(filesCopied ? Labels.copied : (step.fileCount == 1 ? "Copy File" : "Copy \(step.fileCount) Files"),
                      systemImage: filesCopied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(IslandPillStyle(prominent: true))
            .islandHelp("Copy the selected files")
            FileDragButton(title: step.fileCount == 1 ? "Drag" : "Drag \(step.fileCount)",
                           help: "Drag the files into ChatGPT, Gemini or another app", payloads: { model.handoffDragPayloads() })
            IconLink(symbol: "folder", label: "Show in Finder", help: "Show the files in Finder") { model.revealHandoffFiles() }
        }
    }

    private var done: some View {
        Button("Done") { model.endHandoff() }
            .buttonStyle(IslandPillStyle(prominent: false))
            .islandHelp("Finish this transfer")
    }

    private var filesCopied: Bool { model.isCopied(AppModel.handoffToken) }
}

/// The step-2 wording, for tests.
enum DetailsHandoffText {
    static func status(_ step: AppModel.HandoffStep) -> String { HandoffFooter.statusText(step, replaced: false, short: false) }
    static func compact(_ step: AppModel.HandoffStep) -> String { HandoffFooter.statusText(step, replaced: false, short: true) }
}

/// Drag several files at once (in order) into another app.
struct FileDragButton: View {
    let title: String
    let help: String
    let payloads: @MainActor () -> [DragPayload]

    init(title: String, help: String, payloads: @escaping @MainActor () -> [DragPayload]) {
        self.title = title; self.help = help; self.payloads = payloads
    }

    init(title: String, help: String, urls: @escaping @MainActor () -> [URL]) {
        self.init(title: title, help: help, payloads: { urls().map(DragPayload.file) })
    }

    var body: some View {
        Label(title, systemImage: "hand.draw")
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).frame(height: Island.controlHeight)
            .background(Capsule().fill(Island.control))
            .foregroundStyle(Island.primary)
            .fixedSize()
            .overlay(FileDragSource(payloads: payloads))
            .islandHelp(help)
            .accessibilityLabel(title)
    }
}

/// An AppKit drag source for several files (SwiftUI's onDrag carries one).
/// Phase 10: in-memory snapshots are dragged as image data (no file).
struct FileDragSource: NSViewRepresentable {
    let payloads: @MainActor () -> [DragPayload]

    func makeNSView(context: Context) -> DragView { DragView(payloads: payloads) }
    func updateNSView(_ view: DragView, context: Context) { view.payloads = payloads }

    final class DragView: NSView, NSDraggingSource {
        var payloads: @MainActor () -> [DragPayload]
        /// Tests: records the session instead of starting a real one.
        var beginSession: ((_ items: [NSDraggingItem], _ event: NSEvent) -> Void)?
        init(payloads: @escaping @MainActor () -> [DragPayload]) { self.payloads = payloads; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        // Phase 12.2: the island opens on hover without becoming key. AppKit
        // used the first press on this view to make the panel key and did not
        // deliver it (acceptsFirstMouse defaults to false), so the first drag
        // never started and only a second attempt worked. Only this drag
        // source opts in; buttons and menus keep their own handling.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /// The press must not reorder or activate anything before the drag.
        override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }

        /// Movement (in points) before a press becomes a drag: a click is never a drag.
        static let dragThreshold: CGFloat = 3
        private var pressAt: NSPoint?
        private var sessionStarted = false

        override func mouseDown(with event: NSEvent) {
            pressAt = event.locationInWindow
            sessionStarted = false
        }

        override func mouseUp(with event: NSEvent) {
            pressAt = nil
            sessionStarted = false
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            sessionEnded()
        }

        /// Dropped, or cancelled with Esc (no operation): ready for the next drag.
        func sessionEnded() {
            pressAt = nil
            sessionStarted = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !sessionStarted else { return }
            if let start = pressAt {
                let p = event.locationInWindow
                guard hypot(p.x - start.x, p.y - start.y) >= Self.dragThreshold else { return }
            }
            let all = MainActor.assumeIsolated { payloads() }
            guard !all.isEmpty else { return }
            sessionStarted = true
            let items = all.enumerated().map { i, payload -> NSDraggingItem in
                let item: NSDraggingItem
                let icon: NSImage
                switch payload {
                case .file(let url):
                    item = NSDraggingItem(pasteboardWriter: url as NSURL)
                    icon = NSWorkspace.shared.icon(forFile: url.path)
                case .image(let image):
                    item = NSDraggingItem(pasteboardWriter: image.item())
                    icon = NSImage(data: image.data) ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage()
                }
                item.setDraggingFrame(NSRect(x: CGFloat(i) * 4, y: 0, width: 32, height: 32), contents: icon)
                return item
            }
            if let beginSession { beginSession(items, event) } else { beginDraggingSession(with: items, event: event, source: self) }
        }
    }
}

// MARK: - Observed during this turn

struct ActivityView: View {
    let model: AppModel
    let presentation: NotchPresentation
    @State private var filter: CommandFilter = .all

    var body: some View {
        let detail = model.detail.value?.turn.observedDetail
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            if let detail, !detail.commands.isEmpty || !detail.filesChanged.isEmpty {
                let main = detail.commands
                let sub = detail.commands.filter { $0.agentType != nil }
                let shown = main.filter(filter.includes)
                HStack {
                    Text(CommandDiagnostics.summary(main))
                        .font(.system(size: 11)).foregroundStyle(Island.secondary)
                    Spacer(minLength: 4)
                    Button("Review readiness") { model.navigate(to: .evidence) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Island.accent)
                }
                Picker("Commands", selection: $filter) {
                    ForEach(CommandFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .islandFrame("commands.filters")
                BoundedScroll(maxHeight: presentation.listHeight(chrome: 120), resetID: filter) {
                    VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
                    if filter == .all || filter == .failed { FailureSection(inspector: FailureInspector(commands: shown)) }
                    GroupCard {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(shown.enumerated()), id: \.element) { i, c in
                                if i > 0 { Hairline() }
                                CommandRow(command: c, copy: { model.copyObservedCommand(c) })
                            }
                            if !sub.isEmpty {
                                Hairline()
                                Text("Subagents (\(Set(sub.compactMap(\.agentType)).sorted().joined(separator: ", "))): \(sub.count) commands, "
                                     + "\(sub.filter { $0.outcome != "ok" }.count) not successful")
                                    .font(.system(size: 11)).foregroundStyle(Island.secondary).padding(10)
                            }
                            if !detail.filesChanged.isEmpty {
                                Hairline()
                                VStack(alignment: .leading, spacing: 2) {
                                    Caption("Observed file changes")
                                    ForEach(detail.filesChanged, id: \.path) { f in
                                        Text(AppModel.displayPath(f.path, root: model.selectedProjectPath) + (f.count > 1 ? " (\(f.count))" : ""))
                                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Island.secondary).lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                .padding(10)
                            }
                        }
                    }
                    }
                    .padding(.trailing, 2)
                }
                Button("Back to summary") { model.goBack() }.buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(Island.accent)
                Text("Observed commands, not proof the task is complete. Pipeline exit 0 may hide earlier failures. CI not connected.")
                    .font(.system(size: 11)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                MessageCard(title: "No work observed for this answer",
                            detail: model.selectedImport != nil
                                ? "Imported reports come from cloud sessions that Prompt Relay cannot observe."
                                : "Tool events need the Prompt Relay plugin 0.3.0 or later with capture on. Answers captured before that have none.",
                            symbol: "terminal", tint: Island.secondary, action: nil)
            }
        }
        .islandPadding(presentation)
    }
}

struct CommandRow: View {
    let command: ObservedCommand
    var copy: (() -> Void)? = nil
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
                    Text(Wording.clock(command.at)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Island.tertiary)
                    Text(CommandDiagnostics.safeText(command).map { $0.split(separator: "\n").first.map(String.init) ?? $0 }
                         ?? "(withheld: \(command.commandWithheld ?? "unavailable"))")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Island.primary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(Wording.duration(command.durationMs)).font(.system(size: 11)).foregroundStyle(Island.tertiary)
                    result
                }
            }.buttonStyle(.plain)
            .accessibilityLabel("Command: " + (CommandDiagnostics.safeText(command) ?? "Text withheld"))
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                if let text = CommandDiagnostics.safeText(command) {
                    Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let copy { Button("Copy Command", action: copy).buttonStyle(.plain).foregroundStyle(Island.accent) }
                }
                if FailureInspector.isFailure(command) {
                    Text(FailureInspector.meaning(command)).font(.system(size: 11)).foregroundStyle(Island.secondary)
                }
                ForEach(FailureInspector.caveats(command), id: \.self) { caveat in
                    Text(caveat).font(.system(size: 11)).foregroundStyle(Island.tertiary)
                }
                Text(CommandDiagnostics.output(command)).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Island.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Island.smallRadius).fill(Island.code))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .contentShape(Rectangle())
        .islandHelp(command.command == nil ? "Command hidden to protect sensitive data" : "Recorded command and result")
    }

    @ViewBuilder private var result: some View {
        if command.background {
            tag("background · not observed", Island.warning)
        } else if command.outcome == "interrupted" {
            tag("interrupted", Island.warning)
        } else if let code = command.exitCode {
            tag("exit \(code)" + (command.compound ? " ¹" : "") + (command.outputTail != nil ? (expanded ? " ⌃" : " ⌄") : ""),
                code == 0 ? Island.accent : (FailureInspector.likelyNotAnError(command) ? Island.tertiary : Island.error))
        } else {
            tag("exit ?", Island.tertiary)
        }
        if command.afterStop { tag("after Stop", Island.tertiary) }
    }

    private func tag(_ text: String, _ tint: Color) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(tint).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).frame(height: 17).background(Capsule().fill(Island.cardRaised))
    }
}

// MARK: - Project → Session

struct SessionSwitcherView: View {
    let model: AppModel
    let presentation: NotchPresentation
    @State private var browsing: String?

    var body: some View {
        let groups = model.sessionsByProject
        let current = browsing ?? model.selectedProjectPath ?? groups.first?.project
        let height = presentation.listHeight(chrome: 50)
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                WorkspaceModeMenu(model: model)
                ProviderFilterPicker(model: model).labelsHidden()
                if model.isOffLatest, let latest = model.readyAnswer {
                    Button { model.jumpToLatest() } label: {
                        HStack(spacing: 4) {
                            Circle().fill(Island.success).frame(width: 6, height: 6)
                            Text("Jump to Latest").lineLimit(1)
                        }
                    }
                    .buttonStyle(IslandPillStyle(prominent: false))
                    .islandHelp("Open the newest answer: \(latest.sourceLabel), \(latest.projectName)")
                }
            }
        if model.workspaceMode == .byAgent {
            AgentWorkspaceColumns(model: model, height: height)
        } else {
        HStack(alignment: .top, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.project) { group in
                        Button { browsing = group.project } label: {
                            HStack(spacing: 6) {
                                Text(group.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 2)
                                let fresh = model.newAnswerCount(inProject: group.project)
                                if fresh > 0 {
                                    Text("\(fresh) new").font(.system(size: 11, weight: .medium)).foregroundStyle(Island.success)
                                        .accessibilityLabel("\(fresh) new answers")
                                }
                                Text("\(group.sessions.count)").font(.system(size: 11)).foregroundStyle(Island.tertiary)
                            }
                            .foregroundStyle(Island.primary)
                            .padding(.horizontal, 9).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: Island.rowRadius).fill(group.project == current ? Island.selected : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if !model.imports.isEmpty && (model.providerFilter == nil || model.providerFilter == .imported) {
                        Button { browsing = "#imports" } label: {
                            HStack {
                                Text("Imports").font(.system(size: 12.5, weight: .semibold))
                                Spacer()
                                Text("\(model.imports.count)").font(.system(size: 11)).foregroundStyle(Island.tertiary)
                            }
                            .foregroundStyle(Island.secondary).padding(.horizontal, 9).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: Island.rowRadius).fill(current == "#imports" ? Island.selected : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(5)
            }
            .frame(width: 180, height: height)
            .background(RoundedRectangle(cornerRadius: Island.cardRadius).fill(Island.card))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if current == "#imports" {
                        ForEach(model.imports) { report in
                            Button { model.open(report.ref) } label: {
                                SessionRowLabel(title: report.task.map { Wording.requestForDisplay($0).text } ?? "Imported report",
                                                meta: "Imported by you · \(Wording.relative(report.importedAt))",
                                                chip: nil, selected: model.selectedImportID == report.id,
                                                subtitle: "\(report.assistantTitle ?? "AI") · \(report.host?.title ?? "Unknown") · pasted, not captured")
                            }
                            .buttonStyle(.plain)
                        }
                    } else if let group = groups.first(where: { $0.project == current }) {
                        ForEach(group.sessions) { session in
                            ConversationRow(model: model, session: session)
                        }
                    } else {
                        Text("No sessions captured yet.").font(.system(size: 11.5)).foregroundStyle(Island.tertiary).padding(10)
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
        .islandPadding(presentation)
    }

    /// Phase 9.3: running, answered, or stopped without an answer — `0
    /// answers` never looks finished; "answered" says nothing about success.
    static func chip(_ state: AppModel.SessionState) -> (String, Color) {
        switch state {
        case .working: return ("working", Island.warning)
        case .needsInput: return ("needs input", Island.warning)
        case .mayNeedInput: return ("needs input?", Island.tertiary)
        case .waitingBackground: return ("waiting · background", Island.warning)
        case .answered: return ("answered", Island.secondary)
        case .noAnswer: return ("no answer", Island.tertiary)
        case .failed: return ("API error", Island.error)
        }
    }
}

/// Phase 9.4: Logical project → conversation (one native agent session) →
/// its final answers. Intermediate Stops and background turns never appear.
struct ConversationRow: View {
    let model: AppModel
    let session: SessionSummary

    var body: some View {
        let open = model.expandedConversations.contains(session.sessionKey)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                Button { model.toggleConversation(session) } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(Island.tertiary)
                        .frame(width: 18, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Collapse conversation" : "Show the final answers of this conversation")
                Button { model.focusSession(session); model.route = .home } label: {
                    // By Agent names the agent in the left column already.
                    SessionRowLabel(title: model.workspaceMode == .byAgent ? Wording.sessionTitle(session)
                                        : "\(session.provider.title) · \(Wording.sessionTitle(session))",
                                    meta: meta, chip: SessionSwitcherView.chip(model.sessionState(session)),
                                    selected: session.sessionKey == model.selectedSessionKey && model.selectedImport == nil,
                                    subtitle: nil,
                                    latest: model.readyAnswer?.sessionKey == session.sessionKey && model.readyAnswer?.completion.isFinal == true)
                }
                .buttonStyle(.plain)
                .islandHelp("Open the newest final answer of this conversation")
            }
            if open { answers }
        }
    }

    /// "Claude Desktop · 5 min ago · 2 answers"; an unconfirmed host is left out.
    private var meta: String {
        var parts: [String] = []
        // Phase 12: the profile, once there is more than one to tell apart.
        if model.showsProfiles, model.workspaceMode == .byProject { parts.append(model.profileName(session.profileKey)) }
        if let host = session.source?.environment, host != .unknown { parts.append(host.title) }
        parts.append(Wording.relative(model.lastFinalAnswerAt(session) ?? session.lastEventAt))
        let n = session.answeredCount ?? 0
        parts.append(n == 1 ? "1 answer" : "\(n) answers")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var answers: some View {
        if let turns = model.conversationAnswers(session) {
            if turns.isEmpty {
                Text("No final answer yet").font(.system(size: 11)).foregroundStyle(Island.tertiary).padding(.leading, 30).padding(.vertical, 3)
            }
            ForEach(turns) { turn in
                let ref = ReportRef.local(sessionKey: session.sessionKey, turn: turn.index)
                Button { model.open(ref) } label: {
                    HStack(spacing: 6) {
                        if model.currentRef == ref { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Island.accent) }
                        Text(AppModel.oneLine(turn.userRequestPreview ?? turn.finalResponse?.preview ?? "Answer"))
                            .font(.system(size: 11.5)).foregroundStyle(Island.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        if model.readyAnswer?.sessionKey == session.sessionKey, model.readyAnswer?.turnIndex == turn.index,
                           model.readyAnswer?.completion.isFinal == true {
                            Text("Latest").font(.system(size: 11, weight: .semibold)).foregroundStyle(Island.success)
                        }
                        Text(Wording.short(turn.finalResponse?.receivedAt)).font(.system(size: 11)).foregroundStyle(Island.tertiary)
                    }
                    .padding(.leading, 30).padding(.trailing, 9).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: Island.smallRadius).fill(model.currentRef == ref ? Island.selected : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .islandHelp("Open this final answer")
            }
        } else {
            ProgressView().controlSize(.small).padding(.leading, 30).padding(.vertical, 3)
        }
    }
}

struct SessionRowLabel: View {
    let title: String
    let meta: String
    let chip: (String, Color)?
    let selected: Bool
    let subtitle: String?
    /// Phase 9.3: this session holds the newest answer of any agent.
    var latest: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Island.accent) }
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Island.primary).lineLimit(1)
                Spacer(minLength: 4)
                if latest {
                    Text("Latest").font(.system(size: 11, weight: .semibold)).foregroundStyle(Island.success)
                        .padding(.horizontal, 6).frame(height: 16).background(Capsule().fill(Island.cardRaised))
                }
                if let chip {
                    Text(chip.0).font(.system(size: 11, weight: .medium)).foregroundStyle(chip.1)
                        .padding(.horizontal, 6).frame(height: 16).background(Capsule().fill(Island.cardRaised))
                }
            }
            if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1) }
            Text(meta).font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Island.rowRadius).fill(selected ? Island.selected : .clear))
        .contentShape(Rectangle())
    }
}

// MARK: - Mockup states

struct MockupStatesView: View {
    let model: AppModel
    let presentation: NotchPresentation

    var body: some View {
        let material = model.openMockupMaterial
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            if let material {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(material.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Island.primary).lineLimit(1)
                        Text(source(material)).font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1)
                    }
                    Spacer()
                    Text("Visual mockup — review required").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Island.review).padding(.horizontal, 7).frame(height: 18)
                        .background(Capsule().fill(Island.cardRaised))
                }
                HStack(spacing: 8) {
                    Button("Import Images…") { model.importStateImages(material) }.buttonStyle(IslandPillStyle(prominent: true))
                    if model.clipboardHistoryEnabled {
                        Button("From Clipboard…") { model.openClipboard(.images) }.buttonStyle(IslandPillStyle(prominent: false))
                    }
                    Spacer()
                    Text("\(material.states.filter { $0.status == .captured }.count) of \(material.states.count) saved · order = file order")
                        .font(.system(size: 11)).foregroundStyle(Island.tertiary)
                }
                BoundedScroll(maxHeight: presentation.listHeight(chrome: 120)) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(Array(material.states.enumerated()), id: \.element.id) { n, state in
                            StateCard(model: model, material: material, state: state, number: n + 1)
                        }
                    }
                }
                if material.states.isEmpty {
                    Text("No states are known. Import images: each becomes a state named after its file.")
                        .font(.system(size: 11)).foregroundStyle(Island.tertiary)
                }
                Text("Still images cannot show transitions, animations or pointer reactions; review those in the live mockup.")
                    .font(.system(size: 11)).foregroundStyle(Island.tertiary)
                if let message = model.attachmentMessage {
                    Text(message).font(.system(size: 11)).foregroundStyle(Island.warning)
                }
            } else {
                MessageCard(title: "Mockup not found", detail: "It was removed from this report.", symbol: "questionmark",
                            tint: Island.secondary, action: nil)
            }
        }
        .islandPadding(presentation)
    }

    private func source(_ m: ReportMaterial) -> String {
        var parts = [m.isPrivateLink ? "private Claude artifact" : (m.url ?? "mockup")]
        if let path = m.sourcePath { parts.append("source: \(path)") }
        return parts.joined(separator: " · ")
    }
}

struct StateCard: View {
    let model: AppModel
    let material: ReportMaterial
    let state: MockupState
    let number: Int

    var body: some View {
        let url = state.attachmentID.flatMap { id in model.attachments(for: model.currentRef).first { $0.id == id } }
            .flatMap(model.attachmentURL)
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let url, let thumb = Thumbnails.image(for: url, maxPixels: 240) {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Text(state.status == .failed ? "failed" : "no image").font(.system(size: 11)).foregroundStyle(Island.tertiary)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 54).background(Island.code).clipped()
                .clipShape(RoundedRectangle(cornerRadius: Island.smallRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Island.smallRadius, style: .continuous))   // the `.fill` overflow takes no clicks
                SelectBox(selected: state.selected) { model.setStateSelected(material, state: state.id, !state.selected) }
                    .padding(3)
            }
            HStack(spacing: 4) {
                Text(String(format: "%02d · %@", number, state.title)).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Island.primary).lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    Button("Import Image…") { model.importStateImage(material, state: state) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Text(statusText).font(.system(size: 11)).foregroundStyle(state.status == .captured ? Island.accent : Island.tertiary)
                .lineLimit(1)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: Island.rowRadius).fill(Island.cardRaised))
        .islandHelp("Preview this mockup state")
    }

    private var statusText: String {
        switch state.status {
        case .captured: return "captured"
        case .namedOnly: return "named only"
        case .failed: return "failed: \(state.failure ?? "unknown")"
        }
    }
}
