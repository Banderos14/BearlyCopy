import AppKit
import SwiftUI

// Phase 5 views of the island: Details (two columns: the report on the left,
// what goes to ChatGPT on the right), the project and session switcher, the
// observed work of a turn, attachments with mockup states, clipboard images
// and step 2 of the hand-off. Facts only; Claude's claims stay in its answer.

// MARK: - Layout

/// Heights of Details on this display, from the island's height budget.
@MainActor
struct DetailsLayout {
    let presentation: NotchPresentation

    var metrics: IslandMetrics { IslandMetrics.of(presentation) }
    /// Content width inside the island's visible sides.
    var contentWidth: CGFloat { presentation.islandWidth - 2 * metrics.leading }
    /// Two columns when there is room; one column (with a switch) otherwise.
    var twoColumns: Bool { contentWidth >= 520 && presentation.maxContentHeight >= 300 }
    var rightColumn: CGFloat { contentWidth >= 600 ? 252 : 232 }
    /// Height for the columns: the island's content height minus the header,
    /// the action row, the feedback line and paddings.
    var columns: CGFloat {
        let chrome: CGFloat = 22 + 32 + 16 + metrics.top + metrics.bottom + 3 * metrics.spacing
        return max(170, presentation.maxContentHeight - chrome)
    }
    /// The answer's scroll area inside the left column.
    func responseScroll(taskLines: Int) -> CGFloat {
        let task: CGFloat = taskLines == 1 ? 52 : 68
        let chrome: CGFloat = task + metrics.spacing + 24 + 18 + 22 + 8
        return max(60, columns - chrome)
    }
}

// MARK: - Details

struct DetailsView: View {
    let model: AppModel
    let presentation: NotchPresentation
    let actions: SurfaceActions
    @State private var taskExpanded = false
    @State private var pane: Pane = .report
    enum Pane: String, CaseIterable { case report = "Response", handoff = "Handoff" }

    var body: some View {
        let layout = DetailsLayout(presentation: presentation)
        let facts = ReportFacts(model: model)
        VStack(alignment: .leading, spacing: layout.metrics.spacing) {
            if let error = model.projects.error, model.projects.value == nil, model.selectedImport == nil {
                MessageCard(title: "Prompt Relay can't read its history", detail: error.detail,
                            symbol: "exclamationmark.triangle", tint: Island.warning,
                            action: ("Diagnostics", { model.navigate(to: .settings) }))
            } else if facts.source == nil {
                SessionHeader(model: model, facts: facts)
                emptyState
            } else {
                SessionHeader(model: model, facts: facts).islandFrame("details.header")
                if layout.twoColumns {
                    HStack(alignment: .top, spacing: 10) {
                        reportColumn(layout, facts: facts)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        handoffColumn(layout)
                            .frame(width: layout.rightColumn, alignment: .topLeading)
                    }
                    .frame(height: layout.columns, alignment: .top)
                } else {
                    Picker("", selection: $pane) {
                        ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    Group {
                        if pane == .report { reportColumn(layout, facts: facts) } else { handoffColumn(layout) }
                    }
                    .frame(height: layout.columns - 30, alignment: .top)
                }
                if model.handoffStep != nil {
                    HandoffStepBar(model: model).islandFrame("details.handoff")
                } else {
                    DetailsActions(model: model, actions: actions, blocked: facts.blocker != nil).islandFrame("home.actions")
                }
                CopyFeedbackLine(model: model)
            }
            if facts.source == nil { HomeFooter(model: model, actions: actions).islandFrame("home.footer") }
        }
        .islandPadding(presentation)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.projects.value?.isEmpty == true {
            MessageCard(title: "Choose a project to capture",
                        detail: "Prompt Relay keeps Claude Code's final answers for projects you turn on. Nothing is captured until you do.",
                        symbol: "folder.badge.plus", tint: Island.accent,
                        action: ("Capture Settings", { model.navigate(to: .capture) }))
        } else {
            MessageCard(title: "No answer yet",
                        detail: "When Claude Code finishes in a captured project, its answer appears here.",
                        symbol: "text.bubble", tint: Island.secondary, action: nil)
        }
    }

    private func reportColumn(_ layout: DetailsLayout, facts: ReportFacts) -> some View {
        let lines = layout.metrics.compact || layout.columns < 230 ? 1 : 2
        return VStack(alignment: .leading, spacing: layout.metrics.spacing) {
            TaskCard(facts: facts, expanded: $taskExpanded, lines: lines).islandFrame("card.task")
            ResponseCard(model: model, presentation: presentation, facts: facts,
                         scrollHeight: layout.responseScroll(taskLines: taskExpanded ? 2 : lines)) {
                model.navigate(to: .reader)
            }
        }
    }

    private func handoffColumn(_ layout: DetailsLayout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
                        .lineLimit(1).truncationMode(.middle)
                    if let session = sessionTitle {
                        Text("·").foregroundStyle(Island.tertiary)
                        Text(session).font(.system(size: 12.5)).foregroundStyle(Island.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Island.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Project \(projectTitle), session \(sessionTitle ?? "none"). Choose project and session")
            .help("Choose a project and a Claude Code session")
            Spacer(minLength: 6)
            if let other = model.newAnswerElsewhere {
                NewElsewhereChip(model: model, answer: other)
            } else if facts.source != nil {
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
            .help("Another session finished. Open its answer; this one stays in History.")
            Button { model.dismissNewAnswerElsewhere() } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Island.tertiary)
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .frame(maxWidth: 240, alignment: .trailing)
    }

    private var label: String {
        let session = model.allSessions.first { $0.sessionKey == answer.sessionKey }
        let title = session.map(Wording.sessionTitle) ?? answer.projectName
        return title.count > 26 ? String(title.prefix(25)) + "…" : title
    }
}

/// Copy Response, Copy for ChatGPT, then History and the rest.
struct DetailsActions: View {
    let model: AppModel
    let actions: SurfaceActions
    let blocked: Bool

    var body: some View {
        HStack(spacing: 8) {
            CopyActions(model: model, blocked: blocked)
            Spacer(minLength: 4)
            FooterLink(title: "History", symbol: "tray.full", help: "Every captured and imported report, with search") {
                model.navigate(to: .history)
            }
            IconLink(symbol: "clock.arrow.circlepath", label: "Recent Copies", help: "Your last five copies") {
                model.navigate(to: .copies)
            }
            IconLink(symbol: "square.and.arrow.down", label: "Import Report", help: "Import a report from a Claude Code cloud session") {
                model.navigate(to: .importReport)
            }
            IconLink(symbol: "gearshape", label: "Settings", help: "Settings (⌘,)", badge: !AppBuild.otherBuildsRunning().isEmpty) {
                model.navigate(to: .settings)
            }
            .keyboardShortcut(",", modifiers: .command)
            QuitButton(actions: actions)
        }
        .foregroundStyle(Island.secondary)
    }
}

struct IconLink: View {
    let symbol: String
    let label: String
    let help: String
    var badge = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .medium))
                .frame(width: 26, height: 26)
                .overlay(alignment: .topTrailing) {
                    if badge { Circle().fill(Island.warning).frame(width: 5, height: 5).offset(x: -3, y: 3) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(help)
    }
}

// MARK: - What goes to ChatGPT

struct HandoffContentsCard: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Caption("In Copy for ChatGPT")
            row(symbol: "text.quote", title: "Task and the complete answer", detail: "once, unchanged")
            if model.selectedImport != nil {
                row(symbol: "icloud.and.arrow.down", title: "Imported: nothing observed", detail: nil)
            } else if let turn = model.selectedTurn {
                let observed = turn.observed
                Button { model.navigate(to: .activity) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal").frame(width: 14).foregroundStyle(Island.tertiary)
                        Text("Observed work").foregroundStyle(Island.primary)
                        Spacer(minLength: 2)
                        ObservedChips(observed: observed)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Island.tertiary)
                    }
                    .font(.system(size: 11.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Commands, exit codes and durations Prompt Relay observed in this turn")
                if let observed, observed.filesChanged > 0 {
                    row(symbol: "doc.badge.ellipsis", title: "Files Claude changed",
                        detail: "\(observed.filesChanged)")
                }
                row(symbol: "arrow.triangle.branch", title: "Git state", detail: "read when copied")
            }
        }
        .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Island.card))
    }

    private func row(symbol: String, title: String, detail: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).frame(width: 14).foregroundStyle(Island.tertiary)
            Text(title).foregroundStyle(Island.primary).lineLimit(1)
            Spacer(minLength: 2)
            if let detail { Text(detail).foregroundStyle(Island.tertiary).lineLimit(1) }
        }
        .font(.system(size: 11.5))
    }
}

/// "2 runs exit 0 · 1 run exit 1": facts about single commands, never a verdict.
struct ObservedChips: View {
    let observed: ObservedCounts?

    var body: some View {
        HStack(spacing: 4) {
            if let o = observed, o.toolEvents > 0 {
                if o.runsExitZero > 0 { chip("\(o.runsExitZero)× exit 0", Island.accent) }
                if o.runsNonzero > 0 { chip("\(o.runsNonzero)× exit ≠ 0", Island.error) }
                if o.runsExitZero + o.runsNonzero == 0 { chip("\(o.toolEvents) events", Island.secondary) }
            } else {
                chip("none observed", Island.tertiary)
            }
        }
    }

    private func chip(_ text: String, _ tint: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(tint)
            .padding(.horizontal, 6).frame(height: 17).background(Capsule().fill(Island.cardRaised))
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
                Caption("Attachments")
                let summary = model.materialSummary(for: ref)
                if !summary.isEmpty { Text("\(summary.documents + summary.images + summary.mockups + summary.links) selected")
                    .font(.system(size: 10.5)).foregroundStyle(Island.tertiary) }
                Spacer(minLength: 0)
                Menu {
                    Button("Files…") { model.chooseFiles() }
                    if model.clipboardHistoryEnabled { Button("From Clipboard Images…") { model.navigate(to: .clipboard) } }
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(model.reportStore == nil || ref == nil || model.isPresentingSystemDialog)
                .accessibilityLabel("Add attachments")
                .help("Add documents, PDFs or images to this report (copied as snapshots)")
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 3) {
                    if !suggestions.isEmpty {
                        HStack {
                            Text("Prepared by Claude").font(.system(size: 10, weight: .semibold)).foregroundStyle(Island.tertiary)
                            Spacer()
                            if suggestions.count > 1 {
                                Button("Add all") { model.acceptAll(suggestions) }.buttonStyle(.plain)
                                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Island.accent)
                            }
                        }
                        ForEach(suggestions) { SuggestionRow(model: model, suggestion: $0) }
                    }
                    ForEach(materials.filter { $0.kind == .mockup }) { MockupRow(model: model, material: $0) }
                    ForEach(files) { AttachmentRow(model: model, attachment: $0) }
                    ForEach(materials.filter { $0.kind == .link }) { LinkRow(model: model, material: $0) }
                    if suggestions.isEmpty && files.isEmpty && materials.isEmpty {
                        Text("Nothing attached. Documents, images and mockups Claude prepares appear here.")
                            .font(.system(size: 11)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let message = model.attachmentMessage {
                        Text(message).font(.system(size: 10.5)).foregroundStyle(Island.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.trailing, 4)
            }
            .scrollIndicators(.automatic)
        }
        .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 9))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Island.card))
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
        .help(selected ? "Included in Copy for ChatGPT and the files" : "Not included")
    }
}

struct AttachmentRow: View {
    let model: AppModel
    let attachment: ReportAttachment

    var body: some View {
        let url = model.attachmentURL(attachment)
        HStack(spacing: 6) {
            SelectBox(selected: attachment.isSelected) { model.setSelected(attachment, !attachment.isSelected) }
            KindIcon(kind: attachment.effectiveKind, url: url)
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.originalFilename).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Island.primary)
                    .lineLimit(1).truncationMode(.middle)
                Text(url == nil ? "Missing" : "\(ReviewPack.type(attachment)) · \(ReviewPack.size(attachment.byteCount)) · \(attachment.effectiveSource.label)")
                    .font(.system(size: 10)).foregroundStyle(url == nil ? Island.warning : Island.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Open") { if let url { NSWorkspace.shared.open(url) } }.disabled(url == nil)
                Button("Show in Finder") { model.revealAttachmentsForHandoff([attachment]) }.disabled(url == nil)
                Button("Copy File") { model.copyAttachmentFiles([attachment]) }.disabled(url == nil)
                Divider()
                Button("Remove from This Report") { model.removeAttachment(attachment) }
            } label: { Image(systemName: "ellipsis").font(.system(size: 10, weight: .semibold)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Actions for \(attachment.originalFilename)")
        }
        .frame(height: 30)
        .onDrag { model.dragFile(for: attachment).flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
        .help(attachment.originalPath.map { "\(attachment.provenance) · \($0)" } ?? attachment.provenance)
    }
}

struct KindIcon: View {
    let kind: AttachmentKind
    let url: URL?

    var body: some View {
        Group {
            if kind == .image, let url, let thumb = Thumbnails.image(for: url, maxPixels: 64) {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: kind == .pdf ? "doc.richtext" : kind == .document ? "doc.text" : "photo")
                    .font(.system(size: 11)).foregroundStyle(Island.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .background(Island.code)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
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
                Text(suggestion.exists || suggestion.kind == .mockup ? suggestion.reason : "File no longer exists")
                    .font(.system(size: 10)).foregroundStyle(suggestion.exists || suggestion.kind == .mockup ? Island.tertiary : Island.warning)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("Add") { model.accept(suggestion) }
                .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Island.accent)
                .disabled(!(suggestion.exists || suggestion.kind == .mockup))
                .help(suggestion.kind == .mockup ? "Keep it as a mockup: its declared states are listed; images are added by you"
                      : "Copy a snapshot of this file into Prompt Relay")
        }
        .frame(height: 30)
        .help(suggestion.path ?? suggestion.title)
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
                .frame(width: 24, height: 24).background(Island.code).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 0) {
                Text(material.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Island.primary).lineLimit(1)
                Text("Mockup · \(material.states.count) states · \(captured) saved").font(.system(size: 10))
                    .foregroundStyle(Island.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { model.openMockup(material) } label: {
                HStack(spacing: 2) { Text("States"); Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)) }
            }
            .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Island.secondary)
        }
        .frame(height: 30)
        .help("Visual mockup — review required. \(material.provenance)")
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
                    .font(.system(size: 10)).foregroundStyle(material.isPrivateLink ? Island.warning : Island.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { model.removeMaterial(material) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(Island.tertiary).accessibilityLabel("Remove link")
        }
        .frame(height: 30)
    }
}

// MARK: - Step 2 of the hand-off

struct HandoffStepBar: View {
    let model: AppModel

    var body: some View {
        if let step = model.handoffStep {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Island.accent)
                    Text("Text copied (\(step.characters.formatted()) characters). Paste it in ChatGPT, then add "
                         + (step.fileCount == 1 ? "the file." : "the \(step.fileCount) files."))
                        .foregroundStyle(Island.primary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5))
                HStack(spacing: 8) {
                    Button { model.copyHandoffFiles() } label: {
                        Label(step.fileCount == 1 ? "Copy File" : "Copy \(step.fileCount) Files", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(IslandPillStyle(prominent: true))
                    DragAllButton(model: model, count: step.fileCount)
                    Button("Show in Finder") { model.revealHandoffFiles() }.buttonStyle(IslandPillStyle(prominent: false))
                    Spacer(minLength: 0)
                    Button("Done") { model.endHandoff() }.buttonStyle(.plain).font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Island.secondary)
                }
                Text(step.filesCopied
                     ? "Files are on the clipboard. Paste them in ChatGPT; Prompt Relay cannot see whether they arrive."
                     : "Files are prepared, not sent. Pasting several files at once is not verified for every app.")
                    .font(.system(size: 10.5)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Drag every hand-off file at once (in order) into another app.
struct DragAllButton: View {
    let model: AppModel
    let count: Int

    var body: some View {
        Label(count == 1 ? "Drag" : "Drag All", systemImage: "hand.draw")
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(Island.control))
            .foregroundStyle(Island.primary)
            .overlay(DragAllSource(model: model))
            .help("Drag the files into ChatGPT")
            .accessibilityLabel("Drag all files")
    }
}

/// An AppKit drag source for several files (SwiftUI's onDrag carries one).
struct DragAllSource: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> DragView { DragView(model: model) }
    func updateNSView(_ view: DragView, context: Context) { view.model = model }

    final class DragView: NSView, NSDraggingSource {
        var model: AppModel
        init(model: AppModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        override func mouseDragged(with event: NSEvent) {
            let urls = preparedURLs()
            guard !urls.isEmpty else { return }
            let items = urls.enumerated().map { i, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                item.setDraggingFrame(NSRect(x: CGFloat(i) * 4, y: 0, width: 32, height: 32), contents: icon)
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        }

        private func preparedURLs() -> [URL] {
            MainActor.assumeIsolated { model.handoffFileURLs() }
        }
    }
}

// MARK: - Observed during this turn

struct ActivityView: View {
    let model: AppModel
    let presentation: NotchPresentation
    @State private var showAll = false

    var body: some View {
        let detail = model.detail.value?.turn.observedDetail
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            if let detail, !detail.commands.isEmpty || !detail.filesChanged.isEmpty {
                let main = detail.commands.filter { $0.agentType == nil }
                let sub = detail.commands.filter { $0.agentType != nil }
                let shown = showAll ? main : main.filter(\.isImportant)
                HStack {
                    Text("\(main.count) commands observed · \(main.filter(\.isImportant).count) tests, builds, git, failures or background")
                        .font(.system(size: 11)).foregroundStyle(Island.tertiary)
                    Spacer()
                    if main.count != main.filter(\.isImportant).count {
                        Button(showAll ? "Important only" : "Show all") { showAll.toggle() }.buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Island.secondary)
                    }
                }
                BoundedScroll(maxHeight: presentation.listHeight(chrome: 92)) {
                    GroupCard {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(shown.enumerated()), id: \.offset) { i, c in
                                if i > 0 { Hairline() }
                                CommandRow(command: c)
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
                                    Caption("Files Claude changed")
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
                Text("From Claude Code's tool hooks. An exit code describes one command (with a pipe, its last process); "
                     + "it does not show that the task is complete.")
                    .font(.system(size: 10.5)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
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
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(Wording.clock(command.at)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Island.tertiary)
                Text(command.command.map { $0.split(separator: "\n").first.map(String.init) ?? $0 }
                     ?? "(withheld: \(command.commandWithheld ?? "unavailable"))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Island.primary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(Wording.duration(command.durationMs)).font(.system(size: 10.5)).foregroundStyle(Island.tertiary)
                result
            }
            if expanded, let tail = command.outputTail {
                Text(tail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Island.secondary)
                    .textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Island.code))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { if command.outputTail != nil { expanded.toggle() } }
        .help(command.command ?? "")
    }

    @ViewBuilder private var result: some View {
        if command.background {
            tag("background · not observed", Island.warning)
        } else if command.outcome == "interrupted" {
            tag("interrupted", Island.warning)
        } else if let code = command.exitCode {
            tag("exit \(code)" + (command.compound ? " ¹" : "") + (command.outputTail != nil ? (expanded ? " ⌃" : " ⌄") : ""),
                code == 0 ? Island.accent : Island.error)
        } else {
            tag("exit ?", Island.tertiary)
        }
        if command.afterStop { tag("after Stop", Island.tertiary) }
    }

    private func tag(_ text: String, _ tint: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(tint)
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
        HStack(alignment: .top, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.project) { group in
                        Button { browsing = group.project } label: {
                            HStack(spacing: 6) {
                                Text(group.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 2)
                                if model.hasNewAnswer(inProject: group.project) { Circle().fill(Island.accent).frame(width: 6, height: 6) }
                                Text("\(group.sessions.count)").font(.system(size: 11)).foregroundStyle(Island.tertiary)
                            }
                            .foregroundStyle(Island.primary)
                            .padding(.horizontal, 9).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 8).fill(group.project == current ? Island.selected : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if !model.imports.isEmpty {
                        Button { browsing = "#imports" } label: {
                            HStack {
                                Text("Cloud imports").font(.system(size: 12.5, weight: .semibold))
                                Spacer()
                                Text("\(model.imports.count)").font(.system(size: 11)).foregroundStyle(Island.tertiary)
                            }
                            .foregroundStyle(Island.secondary).padding(.horizontal, 9).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 8).fill(current == "#imports" ? Island.selected : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(5)
            }
            .frame(width: 180, height: height)
            .background(RoundedRectangle(cornerRadius: 12).fill(Island.card))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if current == "#imports" {
                        ForEach(model.imports) { report in
                            Button { model.open(report.ref) } label: {
                                SessionRowLabel(title: report.task.map { Wording.requestForDisplay($0).text } ?? "Imported report",
                                                meta: "Cloud · imported by you · \(Wording.relative(report.importedAt))",
                                                chip: nil, selected: model.selectedImportID == report.id, subtitle: nil)
                            }
                            .buttonStyle(.plain)
                        }
                    } else if let group = groups.first(where: { $0.project == current }) {
                        ForEach(group.sessions) { session in
                            Button { model.focusSession(session); model.route = .home } label: {
                                SessionRowLabel(title: Wording.sessionTitle(session), meta: Wording.sessionMeta(session),
                                                chip: session.running == true ? ("working", Island.warning) : ("stopped", Island.tertiary),
                                                selected: session.sessionKey == model.selectedSessionKey && model.selectedImport == nil,
                                                subtitle: session.claudeCodeTitle.map { "Claude Code: \($0)" })
                            }
                            .buttonStyle(.plain)
                            .help("Open the newest answer of this session")
                        }
                    } else {
                        Text("No sessions captured yet.").font(.system(size: 11.5)).foregroundStyle(Island.tertiary).padding(10)
                    }
                }
                .padding(5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 12).fill(Island.card))
        }
        .islandPadding(presentation)
    }
}

struct SessionRowLabel: View {
    let title: String
    let meta: String
    let chip: (String, Color)?
    let selected: Bool
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Island.accent) }
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Island.primary).lineLimit(1)
                Spacer(minLength: 4)
                if let chip {
                    Text(chip.0).font(.system(size: 10, weight: .medium)).foregroundStyle(chip.1)
                        .padding(.horizontal, 6).frame(height: 16).background(Capsule().fill(Island.cardRaised))
                }
            }
            if let subtitle { Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Island.tertiary).lineLimit(1) }
            Text(meta).font(.system(size: 10.5)).foregroundStyle(Island.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Island.selected : .clear))
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
                        Text(source(material)).font(.system(size: 10.5)).foregroundStyle(Island.tertiary).lineLimit(1)
                    }
                    Spacer()
                    Text("Visual mockup — review required").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(red: 0.73, green: 0.65, blue: 1)).padding(.horizontal, 7).frame(height: 18)
                        .background(Capsule().fill(Island.cardRaised))
                }
                HStack(spacing: 8) {
                    Button("Import Images…") { model.importStateImages(material) }.buttonStyle(IslandPillStyle(prominent: true))
                    if model.clipboardHistoryEnabled {
                        Button("From Clipboard…") { model.navigate(to: .clipboard) }.buttonStyle(IslandPillStyle(prominent: false))
                    }
                    Spacer()
                    Text("\(material.states.filter { $0.status == .captured }.count) of \(material.states.count) saved · order = file order")
                        .font(.system(size: 10.5)).foregroundStyle(Island.tertiary)
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
                    .font(.system(size: 10.5)).foregroundStyle(Island.tertiary)
                if let message = model.attachmentMessage {
                    Text(message).font(.system(size: 10.5)).foregroundStyle(Island.warning)
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
                        Text(state.status == .failed ? "failed" : "no image").font(.system(size: 10)).foregroundStyle(Island.tertiary)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 54).background(Island.code).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                SelectBox(selected: state.selected) { model.setStateSelected(material, state: state.id, !state.selected) }
                    .padding(3)
            }
            HStack(spacing: 4) {
                Text(String(format: "%02d · %@", number, state.title)).font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Island.primary).lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    Button("Import Image…") { model.importStateImage(material, state: state) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 9, weight: .semibold)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Text(statusText).font(.system(size: 9.5)).foregroundStyle(state.status == .captured ? Island.accent : Island.tertiary)
                .lineLimit(1)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 9).fill(Island.cardRaised))
        .help(state.summary ?? state.title)
    }

    private var statusText: String {
        switch state.status {
        case .captured: return "captured"
        case .namedOnly: return "named only"
        case .failed: return "failed: \(state.failure ?? "unknown")"
        }
    }
}

// MARK: - Clipboard images

struct ClipboardImagesView: View {
    let model: AppModel
    let presentation: NotchPresentation
    @State private var chosen: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            if let history = model.clipboardImages, history.isEnabled {
                Text("The last \(ClipboardImageHistory.limit) images you copied, kept for 24 hours. Text is never read.")
                    .font(.system(size: 11)).foregroundStyle(Island.tertiary)
                if history.items.isEmpty {
                    MessageCard(title: "No images yet", detail: "Copy a screenshot (⌃⇧⌘4) or an image file; it appears here.",
                                symbol: "photo.on.rectangle", tint: Island.secondary, action: nil)
                } else {
                    HStack(spacing: 8) {
                        ForEach(history.items) { item in
                            ClipboardThumb(history: history, item: item, chosen: chosen.contains(item.id)) {
                                if chosen.contains(item.id) { chosen.remove(item.id) } else { chosen.insert(item.id) }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                HStack(spacing: 8) {
                    let items = history.items.filter { chosen.contains($0.id) }
                    Button(items.isEmpty ? "Attach" : "Attach \(items.count)") {
                        model.attachClipboardImages(items, mockup: model.backRoute == .mockup ? model.openMockupMaterial : nil)
                        chosen = []
                        model.goBack()
                    }
                    .buttonStyle(IslandPillStyle(prominent: true)).disabled(items.isEmpty || model.currentRef == nil)
                    Button("Clear All") { history.clearAll(); chosen = [] }.buttonStyle(IslandPillStyle(prominent: false))
                        .disabled(history.items.isEmpty)
                    Spacer()
                    if let message = history.message { Text(message).font(.system(size: 10.5)).foregroundStyle(Island.warning) }
                }
            } else {
                MessageCard(title: "Clipboard images are off",
                            detail: "Turn them on in Settings to keep the last five images you copy (screenshots), for attaching later. Off by default.",
                            symbol: "photo.on.rectangle", tint: Island.secondary,
                            action: ("Settings", { model.navigate(to: .settings) }))
            }
        }
        .islandPadding(presentation)
    }
}

struct ClipboardThumb: View {
    let history: ClipboardImageHistory
    let item: ClipboardImageHistory.Item
    let chosen: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let thumb = Thumbnails.image(for: history.url(for: item), maxPixels: 160) {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                    } else { Color.clear }
                }
                .frame(width: 84, height: 54).background(Island.code).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 7))
                SelectBox(selected: chosen, action: toggle).padding(3)
            }
            HStack(spacing: 2) {
                Text(item.displayName).font(.system(size: 10)).foregroundStyle(Island.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Button { history.remove(item) } label: { Image(systemName: "xmark").font(.system(size: 7, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Island.tertiary).accessibilityLabel("Delete this image")
            }
            Text(Wording.clock(ISO8601DateFormatter().string(from: item.capturedAt))).font(.system(size: 9.5))
                .foregroundStyle(Island.tertiary)
        }
        .frame(width: 84)
    }
}
