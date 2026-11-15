import SwiftUI

// Phase 13: Context Pack — choose results (Inbox), prepare one pack, hand it
// over (text, then files), see what was done (Handoff History). Every status
// says what the user did on this Mac; none says another app received it.

// MARK: - Context Pack

struct ContextPackView: View {
    let model: AppModel
    let presentation: NotchPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            if model.packRefs.isEmpty {
                MessageCard(title: "No results chosen",
                            detail: "In the Results Inbox, press + on each result you want to hand over together. Their order here is the order in the pack.",
                            symbol: "square.stack.3d.up", tint: Island.secondary,
                            action: ("Open Results Inbox", { model.navigate(to: .inbox) }))
                historyLink
            } else {
                summary
                // The steps stay in view below; what to include scrolls above them.
                BoundedScroll(maxHeight: presentation.listHeight(chrome: model.contextPack.pack == nil ? 80 : 180)) {
                    VStack(alignment: .leading, spacing: 8) {
                        rows
                        notes
                        instructions
                        destination
                    }
                    .padding(2)
                }
                prepared
                CopyFailureLine(model: model)
            }
        }
        .islandPadding(presentation)
    }

    private var summary: some View {
        HStack(spacing: 6) {
            Caption("\(model.packRefs.count) of \(ContextPackFormat.maxResults) results", role: Island.accent)
            Text("\(model.packSelectedAttachmentCount) attachments · about \(model.packEstimatedCharacters.formatted()) characters")
                .font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1)
            Spacer(minLength: 0)
            Button("History") { model.navigate(to: .handoffHistory) }.buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Island.accent)
            Button("Clear") { model.clearPack() }.buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Island.secondary)
                .islandHelp("Empty the selection and the instructions; History and the results stay")
        }
    }

    private var rows: some View {
        let list = model.packRows
        return VStack(spacing: 1) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, row in
                HStack(alignment: .top, spacing: 7) {
                    Text("\(i + 1)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Island.tertiary).frame(width: 14, alignment: .trailing).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title.isEmpty ? "Answer" : row.title).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(row.available ? Island.primary : Island.warning).lineLimit(1)
                        Text([row.provider, row.profile, row.host, row.project].joined(separator: " · ")
                             + (row.available ? "" : " · no longer in history"))
                            .font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    rowButton("chevron.up", "Move up", disabled: i == 0) { model.movePackItem(row.ref, by: -1) }
                    rowButton("chevron.down", "Move down", disabled: i == list.count - 1) { model.movePackItem(row.ref, by: 1) }
                    rowButton("arrow.up.forward.square", "Open this result", disabled: !row.available) { model.open(row.ref) }
                    rowButton("xmark", "Remove from the pack", disabled: false) { model.removeFromPack(row.ref) }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
            }
        }
        .background(RoundedRectangle(cornerRadius: Island.cardRadius).fill(Island.card))
        .islandFrame("pack.rows")
    }

    private func rowButton(_ symbol: String, _ label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(disabled ? Island.tertiary.opacity(0.5) : Island.secondary)
        .disabled(disabled).accessibilityLabel(label).islandHelp(label)
    }

    @ViewBuilder
    private var notes: some View {
        if model.packMixesProjects {
            Label("Results from different projects: each keeps its own section; their contexts are separate.",
                  systemImage: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundStyle(Island.warning).fixedSize(horizontal: false, vertical: true)
        }
        if model.packSharesNativeSessionAcrossProfiles {
            Label("Two results report the same session id from different profiles or agents. They stay two separate results.",
                  systemImage: "person.2")
                .font(.system(size: 11)).foregroundStyle(Island.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let message = model.packMessage {
            Text(message).font(.system(size: 11)).foregroundStyle(Island.warning).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Caption("Review instructions (optional)")
            TextField("Review instructions", text: Binding(get: { model.packInstructions }, set: { model.packInstructions = $0 }),
                      prompt: Text("Your words for the receiving AI, e.g. “Check the implementation and find bugs”")
                        .foregroundStyle(Island.tertiary), axis: .vertical)
                .lineLimit(1...5).textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Island.primary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Island.rowRadius, style: .continuous).fill(Island.card))
                .accessibilityLabel("Review instructions for the receiving AI")
            Text("Shown in the pack as written by you, apart from the agents' results. Empty: Prompt Relay's standard request, labelled as such.")
                .font(.system(size: 11)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Caption("Taking it to")
                Picker("Receiver", selection: Binding(get: { model.packDestination }, set: { model.packDestination = $0 })) {
                    ForEach(HandoffDestination.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                Toggle("Add manifest", isOn: Binding(get: { model.packIncludesManifest }, set: { model.packIncludesManifest = $0 }))
                    .toggleStyle(.checkbox).font(.system(size: 11))
                    .islandHelp("Append the machine-readable manifest (no paths, ids or text) to the copied text")
            }
            HStack(spacing: 8) {
                ForEach(HandoffDestination.Capability.allCases.filter { $0 != .multipleFiles }) { c in
                    let support = model.packDestination.support(c)
                    Text("\(c.title): \(support.label)").font(.system(size: 11))
                        .foregroundStyle(support == .unsupported ? Island.warning : support == .standard ? Island.secondary : Island.tertiary)
                }
            }
            Text(model.packDestination.guidance).font(.system(size: 11)).foregroundStyle(Island.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var prepared: some View {
        switch model.contextPack {
        case .idle, .failed:
            if case .failed(let message) = model.contextPack {
                Text(message).font(.system(size: 11)).foregroundStyle(Island.warning)
            }
            Button { Task { await model.prepareContextPack() } } label: {
                Label("Prepare Context Pack", systemImage: "square.stack.3d.up")
            }
            .buttonStyle(IslandPillStyle(prominent: true)).islandFrame("pack.prepare")
        case .building:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing the pack…").font(.system(size: 12)).foregroundStyle(Island.secondary)
            }
        case .ready(let pack):
            PackStepsView(model: model, pack: pack)
        }
    }

    private var historyLink: some View {
        Button("Handoff History (\(model.handoffHistory.count))") { model.navigate(to: .handoffHistory) }
            .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Island.accent)
            .disabled(model.handoffHistory.isEmpty)
    }
}

/// What is ready, and what is left to do with it.
struct PackStepsView: View {
    let model: AppModel
    let pack: BuiltContextPack

    var body: some View {
        let stale = model.packIsStale
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Caption("Prepared \(Wording.clock(pack.builtAt))", role: stale ? Island.warning : Island.success)
                Text("\(pack.characters.formatted()) characters · \(pack.sendable.count) files"
                     + (pack.temporaryImages > 0 ? " (\(pack.temporaryImages) temporary)" : "")
                     + (pack.missingCount > 0 ? " · \(pack.missingCount) missing" : ""))
                    .font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1)
            }
            if stale {
                HStack {
                    Text("The choice changed after preparing.").font(.system(size: 11)).foregroundStyle(Island.warning)
                    Button("Prepare Again") { Task { await model.prepareContextPack() } }.buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Island.accent)
                }
            }
            if pack.isTooLargeForClipboard {
                Text("Too long to paste into a chat. Remove a result, or Export the pack to a folder.")
                    .font(.system(size: 11)).foregroundStyle(Island.warning).fixedSize(horizontal: false, vertical: true)
            } else if pack.isLong {
                Text("Long pack: some chats cut or refuse long pastes (not verified per app). Consider fewer results or Export.")
                    .font(.system(size: 11)).foregroundStyle(Island.warning).fixedSize(horizontal: false, vertical: true)
            }
            if pack.temporaryImages > 0 {
                Text("Window snapshots are in memory only: copied and dragged as image data, never saved as files here. A receiver that needs files gets them only through Export. They are lost when Prompt Relay quits.")
                    .font(.system(size: 11)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            if model.packAwaitsSensitiveConfirmation {
                sensitive
            }
            HStack(spacing: Island.Space.m) {
                Button { model.copyContextPackText() } label: {
                    Label(model.isCopied(AppModel.packTextToken) ? Labels.copied : "1 · Copy Text",
                          systemImage: model.isCopied(AppModel.packTextToken) ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(IslandPillStyle(prominent: true)).disabled(stale || pack.isTooLargeForClipboard)
                .islandHelp("The pack's exact Markdown on the clipboard")
                if !pack.sendable.isEmpty {
                    Button { model.copyContextPackFiles() } label: {
                        Label(model.isCopied(AppModel.packFilesToken) ? Labels.copied : "2 · Copy Files",
                              systemImage: model.isCopied(AppModel.packFilesToken) ? "checkmark" : "paperclip")
                    }
                    .buttonStyle(IslandPillStyle(prominent: false)).disabled(stale)
                    .islandHelp("Files as files (like ⌘C in Finder), snapshots as image data; replaces the text on the clipboard")
                    FileDragButton(title: "Drag", help: "Drag the pack's files and images into the other app",
                                   payloads: { model.contextPackDragPayloads() })
                        .disabled(stale)
                }
                Spacer(minLength: 0)
            }
            .islandFrame("pack.steps")
            HStack(spacing: 12) {
                Button("Preview") { model.navigate(to: .contextPackPreview) }
                Button("Export…") { model.exportContextPack() }.disabled(stale)
                Button("Copy Manifest") { model.copyContextPackManifest() }
            }
            .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Island.accent)
            Text(progressLine).font(.system(size: 11)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(progressLine)
        }
    }

    private var sensitive: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Possible secrets in \(pack.findingCount) line(s). Text and files wait for your yes; Export stays off:",
                  systemImage: "exclamationmark.shield")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Island.warning)
            ForEach(pack.items.filter { !$0.findings.isEmpty }) { item in
                Text("Result \(item.position): " + item.findings.prefix(4).map { "\($0.section) line \($0.line) (\($0.kind))" }.joined(separator: ", "))
                    .font(.system(size: 11)).foregroundStyle(Island.secondary)
            }
            HStack {
                Button("Copy Anyway") { model.copyContextPackText(confirmed: true) }.buttonStyle(IslandPillStyle(prominent: false))
                Button("Cancel") { model.cancelSensitivePackCopy() }.buttonStyle(.plain).foregroundStyle(Island.secondary)
            }
        }
        .padding(8).background(RoundedRectangle(cornerRadius: Island.rowRadius).fill(Island.card))
    }

    /// Done steps and the one left; never "delivered".
    private var progressLine: String {
        let p = model.packProgress
        var parts: [String] = []
        parts.append(p.textCopiedAt.map { "Text copied \(Wording.clock($0))" } ?? "Text: not copied yet")
        if !pack.sendable.isEmpty {
            if let at = p.filesCopiedAt { parts.append("Files copied \(Wording.clock(at))") }
            else if let at = p.dragStartedAt { parts.append("Drag started \(Wording.clock(at))") }
            else { parts.append("Files: not handed over yet") }
        }
        if let at = p.exportedAt { parts.append("Exported \(Wording.clock(at))") }
        if model.packTextReplaced { parts.append("the clipboard no longer holds the text") }
        return parts.joined(separator: " · ") + ". Delivery not verified: Prompt Relay cannot see what the other app received."
    }
}

// MARK: - Preview

struct ContextPackPreviewView: View {
    let model: AppModel
    let presentation: NotchPresentation
    @State private var source = false

    var body: some View {
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            if let pack = model.contextPack.pack {
                HStack(spacing: 8) {
                    Caption("Context Pack", role: Island.accent)
                    Text("\(pack.items.count) results · \(pack.characters.formatted()) characters · format v\(ContextPackFormat.version)")
                        .font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1)
                    Spacer(minLength: 0)
                    ReaderModePicker(source: $source)
                }
                items(pack)
                Group {
                    if source {
                        VerbatimTextView(pack.text, textColor: NSColor(Island.primary), fontSize: 12, jump: nil).padding(6)
                    } else {
                        FormattedPackView(text: pack.text, jump: nil)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).fill(Island.card))
                .clipShape(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous))
                .islandFrame("pack.preview.text")
                HStack {
                    Text("Copy uses this exact Markdown source.").font(.system(size: 11)).foregroundStyle(Island.tertiary)
                    Spacer()
                    Button("Back") { model.goBack() }.buttonStyle(IslandPillStyle(prominent: false))
                }
            } else {
                MessageCard(title: "Nothing prepared", detail: "Prepare the Context Pack first.", symbol: "square.stack.3d.up",
                            tint: Island.secondary, action: ("Back", { model.goBack() }))
            }
        }
        .islandPadding(presentation)
    }

    /// Per result: source, provenance and attachments, with a way back to it.
    private func items(_ pack: BuiltContextPack) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(pack.items) { item in
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(item.position). \(item.entry.provider) · \(item.entry.profile) · \(item.entry.host) · \(item.entry.project)")
                            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Island.primary).lineLimit(1)
                        Text(provenance(item)).font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(2)
                        if !item.attachments.isEmpty {
                            Text(item.attachments.map { "\($0.name) (\(label($0.availability)))" }.joined(separator: ", "))
                                .font(.system(size: 11)).foregroundStyle(item.attachments.contains { $0.availability == .missing } ? Island.warning : Island.tertiary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 2)
                    Button("Open") { model.open(item.ref) }.buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Island.accent)
                        .islandHelp("Open this result on its own")
                }
            }
        }
        .padding(8).background(RoundedRectangle(cornerRadius: Island.rowRadius).fill(Island.card))
    }

    private func provenance(_ item: BuiltContextPack.Item) -> String {
        if item.isImport {
            return "Supplied by you: pasted report · Reported by agent: its text · Not verified: everything it claims"
        }
        let request: String
        switch item.requestOrigin {
        case "user": request = "request"
        case "automated": request = "earlier user request (turn started automatically)"
        case "unavailable", "unknown": request = "request not established"
        default: request = "captured request"
        }
        return "Confirmed locally: \(request), observed commands and files · Reported by agent: the answer · Not verified: its claims"
    }

    private func label(_ a: BuiltContextPack.AttachmentStatus.Availability) -> String {
        switch a {
        case .file: return "file"
        case .memoryOnly: return "temporary, in memory"
        case .missing: return "missing, not included"
        }
    }
}

// MARK: - Handoff History

struct HandoffHistoryView: View {
    let model: AppModel
    let presentation: NotchPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            if model.handoffHistory.isEmpty {
                MessageCard(title: "No packs prepared yet",
                            detail: "Each prepared Context Pack is listed here with what you did with it. No text or image is stored.",
                            symbol: "clock", tint: Island.secondary, action: nil)
            } else {
                HStack {
                    Text("Copied, dragged or exported — not “delivered”: Prompt Relay cannot see what another app received.")
                        .font(.system(size: 11)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Clear All") { model.clearHandoffHistory() }.buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Island.secondary)
                        .islandHelp("Delete these records; the results themselves stay")
                }
                BoundedScroll(maxHeight: presentation.listHeight(chrome: 60)) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.handoffHistory) { record in row(record) }
                    }
                    .padding(4)
                }
                .background(RoundedRectangle(cornerRadius: Island.cardRadius).fill(Island.card))
            }
        }
        .islandPadding(presentation)
    }

    private func row(_ record: HandoffRecord) -> some View {
        let available = model.availableResults(of: record).count
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(Wording.absolute(record.preparedAt)) · \(record.results.count) results · \(record.destination.title)")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Island.primary).lineLimit(1)
                Spacer(minLength: 4)
                Button("Prepare Again") { model.reprepare(record) }.buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Island.accent).disabled(available == 0)
                Button { model.deleteHandoffRecord(record.id) } label: { Image(systemName: "trash").font(.system(size: 10.5)) }
                    .buttonStyle(.plain).foregroundStyle(Island.secondary).accessibilityLabel("Delete this record")
            }
            Text(record.steps.map { "\($0.event.title) \(Wording.clock($0.at))" }.joined(separator: " → ")
                 + " · \(record.attachmentCount) files" + (record.temporaryImages > 0 ? " (\(record.temporaryImages) temporary)" : "")
                 + " · destination not verified")
                .font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(2)
            Text(record.results.map(\.label).joined(separator: " | ") + (available < record.results.count ? " · \(record.results.count - available) no longer in history" : ""))
                .font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(2).truncationMode(.tail)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }
}

// MARK: - Inbox: choosing results

/// + / ✓ on an Inbox row: in the Context Pack or not.
struct PackToggle: View {
    let model: AppModel
    let ref: ReportRef

    var body: some View {
        let on = model.isInPack(ref)
        Button { model.togglePack(ref) } label: {
            Image(systemName: on ? "checkmark.circle.fill" : "plus.circle").font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(on ? Island.accent : Island.tertiary)
        .accessibilityLabel(on ? "Remove from Context Pack" : "Add to Context Pack")
        .islandHelp(on ? "In the Context Pack · click to remove" : "Add to a Context Pack (several results for another AI)")
    }
}

/// Shown under the Inbox list while results are chosen.
struct PackBar: View {
    let model: AppModel

    var body: some View {
        if !model.packRefs.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 11, weight: .semibold)).foregroundStyle(Island.accent)
                Text("\(model.packRefs.count) chosen for a Context Pack").font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Island.primary)
                Spacer(minLength: 4)
                Button("Create Context Pack") { model.openContextPack() }.buttonStyle(IslandPillStyle(prominent: true))
            }
            .islandFrame("inbox.pack")
        }
    }
}
