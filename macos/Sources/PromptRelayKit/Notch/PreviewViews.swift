import AppKit
import PDFKit
import SwiftUI

// Read-only previews inside the island: the real Copy with Context text
// before copying, and one attachment (image, text document, PDF). Opening
// either changes nothing about the selection; Back returns to Details.

// MARK: - Copy with Context

struct PackagePreviewView: View {
    let model: AppModel
    let presentation: NotchPresentation
    /// The section to scroll to (Preview navigation); the token repeats a jump.
    @State private var jump: (offset: Int, token: Int)?
    /// Phase 8: Formatted (rendered Markdown) or Markdown Source (the exact
    /// characters). Two views of one immutable snapshot (`pack.text`):
    /// switching never rebuilds it, and Copy always copies the source.
    @State private var source = false

    var body: some View {
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            switch model.packPreview {
            case .ready(let pack)?:
                header(pack)
                Group {
                    if source {
                        VerbatimTextView(pack.text, textColor: NSColor(Island.primary), fontSize: 12, jump: jump)
                            .padding(6)
                    } else {
                        FormattedPackView(text: pack.text, jump: jump)
                    }
                }
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).fill(Island.card))
                    .clipShape(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous))
                    .islandFrame("preview.text")
                footer(pack)
            case .failed(_, let message)?:
                MessageCard(title: "The package could not be built", detail: message, symbol: "exclamationmark.triangle",
                            tint: Island.warning, action: nil)
            default:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 20)
            }
            CopyFailureLine(model: model)
        }
        .islandPadding(presentation)
    }

    private func header(_ pack: AppModel.BuiltPack) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Caption(Labels.copyWithContext, role: Island.accent)
                Text("\(pack.text.unicodeScalars.count.formatted()) characters · built \(Wording.clock(pack.builtAt))")
                    .font(.system(size: 10.5)).foregroundStyle(Island.tertiary).lineLimit(1)
                Spacer(minLength: 0)
                sectionMenu(pack)
            }
            HStack(alignment: .center, spacing: 8) {
                ReaderModePicker(source: $source)
                    .islandFrame("preview.mode")
                Text("Full context · Both views share this snapshot. Copy uses its exact Markdown source.")
                    .font(.system(size: 10.5)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            if !pack.findings.isEmpty {
                Label("Possible secrets found: you will be asked before it is copied.", systemImage: "exclamationmark.shield")
                    .font(.system(size: 11)).foregroundStyle(Island.warning)
            }
            if model.previewSelectionChanged {
                HStack {
                    Text("Attachments changed. Refresh to include the new selection.")
                    Button("Refresh Preview") { Task { await model.refreshPackPreview() } }.buttonStyle(.plain)
                }.font(.system(size: 11)).foregroundStyle(Island.warning)
            }
        }
    }

    /// Jumps inside the built text to one of its own `## ` sections; nothing
    /// is shown twice and nothing is rebuilt.
    private func sectionMenu(_ pack: AppModel.BuiltPack) -> some View {
        let sections = PackSection.sections(in: pack.text)
        return Menu {
            ForEach(sections) { section in
                Button("\(section.short) — \(section.title)") { jump = (section.offset, (jump?.token ?? 0) + 1) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "list.bullet").font(.system(size: 9.5, weight: .semibold))
                Text("Sections").font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(Island.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(sections.isEmpty)
        .accessibilityLabel("Go to a section")
        .islandHelp("Jump to a section")
    }

    private func footer(_ pack: AppModel.BuiltPack) -> some View {
        let copied = model.isCopied(AppModel.reviewToken(pack.ref))
        return HStack(spacing: Island.Space.m) {
            Button { Task { await model.copyPreviewedPack() } } label: {
                Label(copied ? Labels.copied : Labels.copyWithContext, systemImage: copied ? "checkmark" : "checklist")
            }
            .buttonStyle(IslandPillStyle(prominent: true))
            .disabled(model.previewSelectionChanged)
            .islandHelp("Copy this preview and transfer the files")
            Text(pack.attachmentIDs.isEmpty ? "No files chosen" : "\(pack.attachmentIDs.count) chosen file\(pack.attachmentIDs.count == 1 ? "" : "s") follow after the text")
                .font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1)
            Spacer(minLength: 0)
            Button("Back") { model.goBack() }.buttonStyle(IslandPillStyle(prominent: false))
        }
        .islandFrame("preview.actions")
        .animation(.easeOut(duration: 0.15), value: model.copiedToken)
    }
}

// MARK: - Attachment

struct AttachmentPreviewView: View {
    let model: AppModel
    let presentation: NotchPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            if let a = model.previewedAttachment {
                let url = model.attachmentURL(a)
                header(a, url: url)
                content(a, url: url)
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).fill(Island.code))
                    .clipShape(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous))
                    .islandFrame("attachment.preview")
                if let note = note(a) {
                    Label(note, systemImage: "info.circle").font(.system(size: 10.5)).foregroundStyle(Island.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                MessageCard(title: "Attachment not found", detail: "It was removed, or another answer is shown now.",
                            symbol: "questionmark", tint: Island.secondary, action: ("Back", { model.goBack() }))
            }
            CopyFailureLine(model: model)
        }
        .islandPadding(presentation)
    }

    private func header(_ a: ReportAttachment, url: URL?) -> some View {
        let copied = model.isCopied(AppModel.attachmentToken(a.id))
        return HStack(spacing: Island.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(a.originalFilename).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Island.primary)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(ReviewPack.type(a)) · \(ReviewPack.size(a.byteCount)) · \(a.effectiveSource.label)")
                    .font(.system(size: 10.5)).foregroundStyle(Island.tertiary).lineLimit(1)
                Text(a.originalPath.map { "\(a.provenance) · \($0)" } ?? a.provenance)
                    .font(.system(size: 10)).foregroundStyle(Island.tertiary)
                    .lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: 4)
            Button { model.copyAttachmentFiles([a]) } label: {
                Label(copied ? Labels.copied : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(IslandPillStyle(prominent: false)).disabled(!model.isAttachmentAvailable(a))
            .islandHelp(a.isInMemory ? "Copy this image (kept in memory only)" : "Copy this file")
            FileDragButton(title: "Drag", help: a.isInMemory ? "Drag the image into another app" : "Drag the file into another app",
                           payloads: { model.dragPayloads(for: [a]) })
            if !a.isInMemory {
                IconLink(symbol: "folder", label: "Show in Finder", help: "Show the file in Finder") { model.revealAttachmentsForHandoff([a]) }
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.copiedToken)
    }

    @ViewBuilder
    private func content(_ a: ReportAttachment, url: URL?) -> some View {
        if a.isInMemory {
            if let data = model.attachmentData(a), let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(6)
                    .onDrag { model.dragProvider(for: a) }
            } else { unreadable }
        } else if let url {
            switch a.effectiveKind {
            case .image:
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(6)
                        .onDrag { model.dragProvider(for: a) }
                } else { unreadable }
            case .pdf:
                PDFPreview(url: url)
            case .document:
                if let text = model.previewText(a) {
                    VerbatimTextView(text, textColor: NSColor(Island.primary), fontSize: 12).padding(6)
                } else { unreadable }
            }
        } else {
            Text("The file is missing from Prompt Relay's folder.").font(.system(size: 12)).foregroundStyle(Island.warning)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var unreadable: some View {
        Text("This file cannot be shown here. Use Show in Finder to open it.")
            .font(.system(size: 12)).foregroundStyle(Island.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What a still preview cannot show.
    private func note(_ a: ReportAttachment) -> String? {
        if a.isInMemory {
            return "Kept in memory only: not saved to disk, gone when Prompt Relay quits. An app you copy or drag it into may keep its own copy."
        }
        let ext = (a.originalFilename as NSString).pathExtension.lowercased()
        if ["html", "htm"].contains(ext) { return "HTML is shown as source text; it is not run here, so its interactive behavior is not checked." }
        if a.mockupID != nil { return "A still image of a mockup state: motion, clicks and interactive states are not checked." }
        if a.effectiveKind == .document, a.byteCount > 1024 * 1024 { return "Only files up to 1 MB are shown." }
        return nil
    }
}

/// Apple's PDF view, read-only.
struct PDFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displaysPageBreaks = true
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

/// Copy with Context, Formatted: the snapshot's Markdown rendered (headings,
/// lists, tables, code) in a lazy stack, so 100,000 characters and more
/// scroll without building every row. Display only; the Sections menu jumps
/// to the same `## ` heading as in Markdown Source.
struct FormattedPackView: View {
    let text: String
    let jump: (offset: Int, token: Int)?

    var body: some View {
        let blocks = Markdown.blocks(text)
        ScrollViewReader { proxy in
            ScrollView {
                MarkdownBlocksView(blocks: blocks, codeLineLimit: nil, fontSize: 12.5, anchored: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .scrollIndicators(.automatic)
            .onChange(of: jump?.token) {
                guard let jump, let index = Self.blockIndex(of: jump.offset, in: text, blocks: blocks) else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .top) }
            }
        }
        .islandFrame("preview.formatted")
    }

    /// The block of the `## ` heading at `offset` in the source: the n-th
    /// level-2 heading with that title, where n counts the same titles before it.
    static func blockIndex(of offset: Int, in text: String, blocks: [Markdown.Block]) -> Int? {
        let sections = PackSection.sections(in: text)
        guard let section = sections.first(where: { $0.offset == offset }) else { return nil }
        let nth = sections.filter { $0.title == section.title && $0.offset < offset }.count
        let matches = blocks.indices.filter { if case .heading(2, section.title) = blocks[$0] { return true } else { return false } }
        return nth < matches.count ? matches[nth] : nil
    }
}
