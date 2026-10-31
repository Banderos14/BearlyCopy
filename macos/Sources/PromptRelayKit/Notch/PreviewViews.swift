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

    var body: some View {
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            switch model.packPreview {
            case .ready(let pack)?:
                header(pack)
                VerbatimTextView(pack.text, textColor: NSColor(Island.primary), fontSize: 12)
                    .padding(6)
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
                    .font(.system(size: 10.5)).foregroundStyle(Island.tertiary)
                Spacer(minLength: 0)
            }
            Text("Exactly this text is copied. Git status and the time were read when it was built; Copy uses this snapshot.")
                .font(.system(size: 10.5)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
            if !pack.findings.isEmpty {
                Label("Possible secrets found: you will be asked before it is copied.", systemImage: "exclamationmark.shield")
                    .font(.system(size: 11)).foregroundStyle(Island.warning)
            }
            if model.previewSelectionChanged {
                Label("The chosen files changed since: Copy builds it again with the new choice.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11)).foregroundStyle(Island.warning)
            }
        }
    }

    private func footer(_ pack: AppModel.BuiltPack) -> some View {
        let copied = model.isCopied(AppModel.reviewToken(pack.ref))
        return HStack(spacing: Island.Space.m) {
            Button { Task { await model.copyPreviewedPack() } } label: {
                Label(copied ? Labels.copied : Labels.copyWithContext, systemImage: copied ? "checkmark" : "checklist")
            }
            .buttonStyle(IslandPillStyle(prominent: true))
            .islandHelp("Copy this text; then hand over the chosen files")
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
            }
            Spacer(minLength: 4)
            Button { model.copyAttachmentFiles([a]) } label: {
                Label(copied ? Labels.copied : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(IslandPillStyle(prominent: false)).disabled(url == nil)
            .islandHelp("Put the file on the clipboard, like ⌘C in Finder")
            FileDragButton(title: "Drag", help: "Drag the file into another app") { model.dragFile(for: a).map { [$0] } ?? [] }
            IconLink(symbol: "folder", label: "Show in Finder", help: "Show the file in Finder") { model.revealAttachmentsForHandoff([a]) }
        }
        .animation(.easeOut(duration: 0.15), value: model.copiedToken)
    }

    @ViewBuilder
    private func content(_ a: ReportAttachment, url: URL?) -> some View {
        if let url {
            switch a.effectiveKind {
            case .image:
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(6)
                        .onDrag { model.dragFile(for: a).flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
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
