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
    var twoColumns: Bool { contentWidth >= 520 && presentation.maxContentHeight >= 300 }
    var rightColumn: CGFloat { contentWidth >= 600 ? 276 : 264 }
}

// MARK: - Details

/// Three regions that never overlap: the header (project, session, source),
/// the content (Task, Response, what goes to ChatGPT, attachments) and the
/// footer (the copies and navigation, or step 2 of the hand-off instead).
struct DetailsView: View {
    let model: AppModel
    let presentation: NotchPresentation
    let actions: SurfaceActions
    @State private var taskExpanded = false
    @State private var pane: Pane = .report
    @Environment(\.islandReduceMotion) private var reduceMotion
    enum Pane: String, CaseIterable { case report = "Response", handoff = "For ChatGPT" }

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
                emptyState
                DetailsFooter(model: model, actions: actions, blocked: true, showsCopies: false)
                    .islandFrame("home.footer")
            } else {
                SessionHeader(model: model, facts: facts).islandFrame("details.header")
                ClipboardNotice(model: model)
                content(layout, facts: facts)
                DetailsFooter(model: model, actions: actions, blocked: facts.blocker != nil)
                    .islandFrame("details.footer")
            }
        }
        .islandPadding(presentation)
        .animation(Island.geometry(reduceMotion: reduceMotion), value: model.activeHandoff)
        .onChange(of: model.currentRef) { taskExpanded = false }
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

    @ViewBuilder
    private func content(_ layout: DetailsLayout, facts: ReportFacts) -> some View {
        if layout.twoColumns {
            HStack(alignment: .top, spacing: Island.Space.l) {
                reportColumn(layout, facts: facts)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                handoffColumn
                    .frame(width: layout.rightColumn, alignment: .topLeading)
            }
        } else {
            VStack(alignment: .leading, spacing: layout.metrics.spacing) {
                Picker("", selection: $pane) {
                    ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                if pane == .report { reportColumn(layout, facts: facts) } else { handoffColumn }
            }
        }
    }

    private func reportColumn(_ layout: DetailsLayout, facts: ReportFacts) -> some View {
        VStack(alignment: .leading, spacing: layout.metrics.spacing) {
            TaskCard(facts: facts, expanded: $taskExpanded, lines: layout.metrics.compact ? 1 : 2).islandFrame("card.task")
            ResponseCard(model: model, facts: facts) { model.navigate(to: .reader) }
        }
    }

    private var handoffColumn: some View {
        VStack(alignment: .leading, spacing: Island.Space.m) {
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
            .help("Dismiss")
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
            IconLink(symbol: "tray.full", label: "History", help: "History: every captured and imported report") {
                model.navigate(to: .history)
            }
            IconLink(symbol: "doc.on.clipboard", label: "Clipboard",
                     help: "Clipboard: your last copies and copied images") {
                model.navigate(to: .clipboard)
            }
            IconLink(symbol: "gearshape", label: "Settings", help: "Settings (⌘,)", badge: !AppBuild.otherBuildsRunning().isEmpty) {
                model.navigate(to: .settings)
            }
            .keyboardShortcut(",", modifiers: .command)
            Menu {
                Button("Import Report…") { model.navigate(to: .importReport) }
                Divider()
                Button("Quit Prompt Relay") { actions.quit() }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More")
            .help("More: Import Report, Quit")
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
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .medium))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Island.hover : .clear))
                .overlay(alignment: .topTrailing) {
                    if badge { Circle().fill(Island.warning).frame(width: 5, height: 5).offset(x: -3, y: 3) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .help(help)
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
        }
    }
}

// MARK: - What goes to ChatGPT

/// What Copy for ChatGPT puts together for this report, one row per part,
/// with a short fact each. "Not captured" and "no tools used" are told apart.
struct HandoffContentsCard: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Caption("Copy for ChatGPT")
            row(symbol: "text.quote", title: "Task & Response", detail: taskDetail, help: "Your request and Claude's complete answer, verbatim, once")
            if model.selectedImport != nil {
                row(symbol: "terminal", title: "Commands & Checks", detail: "not observed",
                    help: "Imported reports come from cloud sessions that Prompt Relay cannot observe")
            } else if let turn = model.selectedTurn {
                Button { model.navigate(to: .activity) } label: {
                    rowLabel(symbol: "terminal", title: "Commands & Checks", detail: Self.commands(turn.observed, captureOn: captureOn),
                             tint: failed(turn.observed) > 0 ? Island.error : Island.tertiary, chevron: true)
                }
                .buttonStyle(.plain)
                .help(turn.observed == nil
                      ? "No tool events were captured for this turn (plugin before 0.3.0, or capture was off then). This is not the same as Claude using no tools."
                      : "The commands, exit codes and durations Prompt Relay observed in this turn. An exit code describes one command, not the task.")
                if let observed = turn.observed {
                    row(symbol: "doc.badge.ellipsis", title: "Changed Files",
                        detail: observed.filesChanged == 0 ? "none observed" : (observed.filesChanged == 1 ? "1 file" : "\(observed.filesChanged) files"),
                        help: "Files Claude edited or wrote, as observed by the tool hooks")
                }
                row(symbol: "arrow.triangle.branch", title: "Git State", detail: "read when you copy",
                    help: "Branch and uncommitted changes, read locally at the moment of the copy (read-only)")
            }
            let n = model.handoffAttachments(for: model.currentRef).count
            row(symbol: "paperclip", title: "Attachments", detail: n == 0 ? "none selected" : "\(n) selected",
                help: "The files you selected below; their names are listed in the text, the files follow in step 2")
        }
        .padding(Island.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).fill(Island.card))
    }

    private var captureOn: Bool { model.selectedProject?.captureEnabled ?? true }

    private var taskDetail: String {
        switch ReportFacts(model: model).task {
        case .unavailable: return "answer only"
        case .automated: return "automatic turn"
        default: return "verbatim"
        }
    }

    private func failed(_ o: ObservedCounts?) -> Int { o.map { max($0.commandsNonzero ?? 0, $0.runsNonzero) } ?? 0 }

    /// A fact, never a verdict. Distinguishes: no tool events captured for
    /// this turn (older plugin, or capture off) from tools not used at all.
    static func commands(_ o: ObservedCounts?, captureOn: Bool) -> String {
        guard let o else { return captureOn ? "not captured" : "capture off" }
        if o.toolEvents == 0 { return "no tools used" }
        let failed = max(o.commandsNonzero ?? 0, o.runsNonzero)
        // One fact fits the row; failures come first. The rest is in Observed Work.
        if failed > 0 { return "\(failed) failed" }
        if o.runsExitZero > 0 { return "\(o.runsExitZero)× exit 0" }
        return o.toolEvents == 1 ? "1 event" : "\(o.toolEvents) events"
    }

    private func row(symbol: String, title: String, detail: String, help: String) -> some View {
        rowLabel(symbol: symbol, title: title, detail: detail, tint: Island.tertiary, chevron: false).help(help)
    }

    private func rowLabel(symbol: String, title: String, detail: String, tint: Color, chevron: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10.5)).frame(width: 14).foregroundStyle(Island.tertiary)
            Text(title).foregroundStyle(Island.primary).lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            Text(detail).font(.system(size: 10.5)).foregroundStyle(tint).lineLimit(1).truncationMode(.tail)
            if chevron { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Island.tertiary) }
        }
        .font(.system(size: 11.5))
        .contentShape(Rectangle())
    }
}

/// "1× exit ≠ 0 · 2× exit 0": facts about single commands, never a verdict.
/// Nothing at all when no command was observed (no "none" that reads like
/// an error).
struct ObservedChips: View {
    let observed: ObservedCounts?
    /// One chip only (a narrow row): failures first.
    var compact = false

    var body: some View {
        if let o = observed, o.toolEvents > 0 {
            HStack(spacing: 4) {
                // A failure of any command shows; exit 0 is counted for tests and builds only.
                let failed = max(o.commandsNonzero ?? 0, o.runsNonzero)
                if failed > 0 { chip(failed == 1 ? "1 failed run" : "\(failed) failed runs", Island.error).help("Shell commands that exited non-zero") }
                if o.runsExitZero > 0 && !(compact && failed > 0) {
                    chip("\(o.runsExitZero)× exit 0", Island.success).help("Test and build commands that exited 0 (not proof that the task is done)")
                }
                if failed + o.runsExitZero == 0 { chip("\(o.toolEvents) tool events", Island.secondary) }
            }
        }
    }

    private func chip(_ text: String, _ tint: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(tint).lineLimit(1).fixedSize()
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
                    Button("From Clipboard…") { model.openClipboard(.images) }
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(model.reportStore == nil || ref == nil || model.isPresentingSystemDialog)
                .accessibilityLabel("Add attachments")
                .help("Add documents, PDFs or images to this report (copied as snapshots)")
            }
            BoundedScroll(minHeight: 34) {
                VStack(alignment: .leading, spacing: 3) {
                    if !suggestions.isEmpty {
                        HStack {
                            Text("From this turn").font(.system(size: 10, weight: .semibold)).foregroundStyle(Island.tertiary)
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
        }
        .padding(Island.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).fill(Island.card))
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
                Text("\(captured) of \(material.states.count) states saved").font(.system(size: 10))
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

/// Step 2, in place of the footer: the text is on the clipboard; now the
/// files chosen at the copy. When the choice changed since, nothing old is
/// handed over: the step asks for a new Copy for ChatGPT.
struct HandoffFooter: View {
    let model: AppModel
    let step: AppModel.HandoffStep

    var body: some View {
        let changed = model.handoffSelectionChanged
        VStack(alignment: .leading, spacing: Island.Space.s) {
            HStack(spacing: 6) {
                Image(systemName: changed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(changed ? Island.warning : Island.success)
                Text(changed
                     ? "The chosen files changed after the text was copied."
                     : "Text copied. Paste it in ChatGPT, then add " + (step.fileCount == 1 ? "the file." : "the \(step.fileCount) files."))
                    .foregroundStyle(Island.primary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5))
            HStack(spacing: Island.Space.m) {
                if changed {
                    Button { Task { await model.copySelectedContext() } } label: {
                        Label("Copy for ChatGPT Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(IslandPillStyle(prominent: true))
                    .help("Copy the text again with the files chosen now")
                } else {
                    Button { model.copyHandoffFiles() } label: {
                        Label(filesCopied ? "Copied!" : (step.fileCount == 1 ? "Copy File" : "Copy \(step.fileCount) Files"),
                              systemImage: filesCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(IslandPillStyle(prominent: true))
                    .help("Put the files on the clipboard, like ⌘C in Finder")
                    FileDragButton(title: step.fileCount == 1 ? "Drag" : "Drag \(step.fileCount)",
                                   help: "Drag the files into ChatGPT") { model.handoffFileURLs() }
                    IconLink(symbol: "folder", label: "Show in Finder", help: "Show the files in Finder") { model.revealHandoffFiles() }
                }
                Spacer(minLength: 0)
                Button("Done") { model.endHandoff() }
                    .buttonStyle(IslandPillStyle(prominent: false))
                    .help("Close step 2; the clipboard keeps what you copied")
            }
        }
        .padding(.horizontal, Island.Space.l).padding(.vertical, Island.Space.m)
        .background(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).fill(Island.card))
        .animation(.easeOut(duration: 0.15), value: model.copyFeedback)
    }

    private var filesCopied: Bool {
        if case .copied(.files, _) = model.copyFeedback { return true }
        return false
    }
}

/// Drag several files at once (in order) into another app.
struct FileDragButton: View {
    let title: String
    let help: String
    let urls: @MainActor () -> [URL]

    var body: some View {
        Label(title, systemImage: "hand.draw")
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).frame(height: Island.controlHeight)
            .background(Capsule().fill(Island.control))
            .foregroundStyle(Island.primary)
            .fixedSize()
            .overlay(FileDragSource(urls: urls))
            .help(help)
            .accessibilityLabel(title)
    }
}

/// An AppKit drag source for several files (SwiftUI's onDrag carries one).
struct FileDragSource: NSViewRepresentable {
    let urls: @MainActor () -> [URL]

    func makeNSView(context: Context) -> DragView { DragView(urls: urls) }
    func updateNSView(_ view: DragView, context: Context) { view.urls = urls }

    final class DragView: NSView, NSDraggingSource {
        var urls: @MainActor () -> [URL]
        init(urls: @escaping @MainActor () -> [URL]) { self.urls = urls; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        override func mouseDragged(with event: NSEvent) {
            let files = MainActor.assumeIsolated { urls() }
            guard !files.isEmpty else { return }
            let items = files.enumerated().map { i, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                item.setDraggingFrame(NSRect(x: CGFloat(i) * 4, y: 0, width: 32, height: 32), contents: icon)
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
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
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(tint).lineLimit(1).fixedSize()
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
                        Button("From Clipboard…") { model.openClipboard(.images) }.buttonStyle(IslandPillStyle(prominent: false))
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

