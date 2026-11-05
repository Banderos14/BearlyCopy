import AppKit
import SwiftUI

// Clipboard: Prompt Relay's small shelf, usable without Claude Code. Text
// holds the last five copies made in Prompt Relay (references, fetched
// fresh on Copy Again; text from other apps is never read). Images holds
// the last five images copied anywhere (ADR-014's history: SHA-256
// de-duplication, 20 MB limit, 24 h, sensitive types skipped, local only).
// A clipboard image becomes a report attachment only through Add to Report.

struct ClipboardView: View {
    let model: AppModel
    let presentation: NotchPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
            HStack(spacing: Island.Space.m) {
                Picker("", selection: Binding(get: { model.clipboardTab }, set: { model.clipboardTab = $0 })) {
                    ForEach(AppModel.ClipboardTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                .islandHelp("Your recent copied text and images")
                Spacer(minLength: 0)
                Text(model.clipboardTab == .text ? "Last \(AppModel.copyHistoryLimit) copies made here"
                     : "Last \(ClipboardImageHistory.limit) images · kept 24 h on this Mac")
                    .font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1)
            }
            ClipboardNotice(model: model)
            if model.clipboardTab == .text {
                ClipboardTextList(model: model)
            } else {
                ClipboardImagesPane(model: model)
            }
            CopyFailureLine(model: model)
        }
        .islandPadding(presentation)
    }
}

// MARK: - Text

struct ClipboardTextList: View {
    let model: AppModel

    var body: some View {
        if model.copyHistory.isEmpty {
            MessageCard(title: "Nothing copied yet",
                        detail: "Copy Answer and Copy with Context appear here, so you can copy them again.",
                        symbol: "doc.on.clipboard", tint: Island.secondary, action: nil)
        } else {
            BoundedScroll(minHeight: 60) {
                GroupCard {
                    ForEach(Array(model.copyHistory.enumerated()), id: \.element.id) { i, record in
                        if i > 0 { Hairline() }
                        row(record)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Clear All") { model.clearCopyHistory() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Island.secondary)
                    .islandHelp("Forget this list (nothing else is deleted)")
            }
        }
    }

    private func row(_ record: CopyRecord) -> some View {
        let available = model.isAvailable(record.ref)
        return HStack(spacing: Island.Space.m) {
            Button { model.open(record.ref) } label: {
                HStack(spacing: 10) {
                    Image(systemName: record.kind == .response ? "doc.on.doc" : "checklist")
                        .font(.system(size: 12)).foregroundStyle(Island.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(record.kind.title) · \(record.projectName)").font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Island.primary).lineLimit(1)
                        if available, let preview = model.copyPreview(record) {
                            Text(preview).font(.system(size: 11.5)).foregroundStyle(Island.secondary).lineLimit(1)
                        }
                        Text(available ? "\(record.label) · \(Wording.relative(record.at))" : "No longer in history")
                            .font(.system(size: 11)).foregroundStyle(available ? Island.tertiary : Island.warning).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(IslandRowStyle())
            .disabled(!available)
            .islandHelp("Open this report")
            let copied = model.isCopied(record.kind == .response ? AppModel.answerToken(record.ref) : AppModel.reviewToken(record.ref))
            Button { Task { await model.copyAgain(record) } } label: {
                Label(copied ? Labels.copied : "Copy Again", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(IslandPillStyle(prominent: false))
            .disabled(!available)
            .islandHelp("Copy this item again")
            Button { model.removeCopyRecord(record) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Island.tertiary)
            .accessibilityLabel("Remove from this list")
            .islandHelp("Remove from this list")
            .padding(.trailing, 8)
        }
        .padding(.horizontal, 2)
        .animation(.easeOut(duration: 0.15), value: model.copiedToken)
    }

}

// MARK: - Images

struct ClipboardImagesPane: View {
    let model: AppModel
    @State private var chosen: [String] = []
    @State private var preview: String?

    var body: some View {
        if let history = model.clipboardImages, history.isEnabled {
            let items = history.items
            let selected = items.filter { chosen.contains($0.id) }
            if let id = preview, let item = items.first(where: { $0.id == id }) {
                previewPane(history, item)
            } else if items.isEmpty {
                MessageCard(title: "No images yet",
                            detail: "Copy a screenshot (⌃⇧⌘4) or an image file; the last five appear here, also without Claude Code.",
                            symbol: "photo.on.rectangle", tint: Island.secondary, action: nil)
            } else {
                HStack(spacing: Island.Space.m) {
                    ForEach(items) { item in
                        ClipboardThumb(history: history, item: item, chosen: chosen.contains(item.id),
                                       toggle: { toggle(item.id) }, open: { preview = item.id })
                    }
                    Spacer(minLength: 0)
                }
                .islandFrame("clipboard.images")
            }
            actions(history, selected: selected.isEmpty && preview != nil ? items.filter { $0.id == preview } : selected)
            if let message = history.message {
                Text(message).font(.system(size: 11)).foregroundStyle(Island.warning)
            }
        } else if model.clipboardImages == nil {
            MessageCard(title: "Clipboard images are unavailable", detail: "This build has no image history.",
                        symbol: "photo.on.rectangle", tint: Island.secondary, action: nil)
        } else {
            MessageCard(title: "Image history is off",
                        detail: "When on, the last five images you copy (screenshots with ⌃⇧⌘4, image files) are kept on this Mac for 24 hours, to copy or drag later. Text is never read; password-manager items are skipped.",
                        symbol: "photo.on.rectangle", tint: Island.secondary,
                        action: ("Turn On", { model.clipboardHistoryEnabled = true; model.answerClipboardNotice(keepOn: true) }))
        }
    }

    private func toggle(_ id: String) {
        if let i = chosen.firstIndex(of: id) { chosen.remove(at: i) } else { chosen.append(id) }
    }

    /// Copy, Drag and Add work on the chosen images (in the order chosen),
    /// or on the one being previewed.
    private func actions(_ history: ClipboardImageHistory, selected: [ClipboardImageHistory.Item]) -> some View {
        let n = selected.count
        let suffix = n > 1 ? " \(n)" : ""
        return HStack(spacing: Island.Space.m) {
            Button {
                model.copyClipboardImages(selected)
            } label: {
                Label(copied ? Labels.copied : "Copy\(suffix)", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(IslandPillStyle(prominent: true)).disabled(n == 0)
            .islandHelp("Copy selected images as files")
            FileDragButton(title: "Drag\(suffix)", help: "Drag the chosen images into another app, such as ChatGPT or Gemini") {
                history.exportFiles(selected)
            }
            .disabled(n == 0).opacity(n == 0 ? 0.45 : 1)
            Button(n > 1 ? "Attach \(n) to Current Answer" : Labels.attachToCurrentAnswer) {
                model.attachClipboardImages(selected, mockup: model.backRoute == .mockup ? model.openMockupMaterial : nil)
                chosen = []
                preview = nil
            }
            .buttonStyle(IslandPillStyle(prominent: false))
            .disabled(n == 0 || model.currentRef == nil)
            .islandHelp(attachTarget.map { _ in "Attach selected images to this answer" }
                        ?? "Select an answer before attaching images")
            Spacer(minLength: 0)
            Menu {
                Button(n > 0 ? "Remove \(n == 1 ? "Image" : "\(n) Images")" : "Remove") {
                    selected.forEach(history.remove)
                    chosen.removeAll { id in selected.contains { $0.id == id } }
                    preview = nil
                }
                .disabled(n == 0)
                Button("Clear All") { history.clearAll(); chosen = []; preview = nil }
                    .disabled(history.items.isEmpty)
                Divider()
                Button("Turn Off Image History") { model.clipboardHistoryEnabled = false; chosen = []; preview = nil }
            } label: {
                Image(systemName: "trash").font(.system(size: 12, weight: .medium)).frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Remove images")
            .islandHelp("Manage image history")
        }
        .islandFrame("clipboard.actions")
    }

    private func previewPane(_ history: ClipboardImageHistory, _ item: ClipboardImageHistory.Item) -> some View {
        VStack(alignment: .leading, spacing: Island.Space.s) {
            HStack(spacing: Island.Space.m) {
                Button { preview = nil } label: {
                    Label("All Images", systemImage: "chevron.left").font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(Island.secondary)
                Text(ClipboardImageHistory.exportName(item)).font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Island.primary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text("\(ReviewPack.size(item.byteCount)) · \(Wording.clock(ISO8601DateFormatter().string(from: item.capturedAt)))")
                    .font(.system(size: 11)).foregroundStyle(Island.tertiary)
                IconLink(symbol: "arrow.up.forward.app", label: "Open in Preview", help: "Open in Preview") {
                    NSWorkspace.shared.open(history.url(for: item))
                }
            }
            if let image = NSImage(contentsOf: history.url(for: item)) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).fill(Island.code))
                    .clipShape(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous))
                    .onDrag { history.exportFiles([item]).first.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
                    .islandFrame("clipboard.preview")
                    .islandFrame("clipboard.preview.\(item.id)")
            }
        }
    }

    private var copied: Bool { model.isCopied(AppModel.clipboardImagesToken) }

    /// The answer the images would go to, named, so they never land in another session by surprise.
    private var attachTarget: String? {
        guard let ref = model.currentRef else { return nil }
        let (project, label) = model.describe(ref)
        return "\(project) · \(label)"
    }
}

struct ClipboardThumb: View {
    let history: ClipboardImageHistory
    let item: ClipboardImageHistory.Item
    let chosen: Bool
    let toggle: () -> Void
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topLeading) {
                Button(action: open) {
                    Group {
                        if let thumb = Thumbnails.image(for: history.url(for: item), maxPixels: 200) {
                            Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                        } else { Color.clear }
                    }
                    .frame(width: 96, height: 64).background(Island.code).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: Island.rowRadius, style: .continuous))
                    // Clipping hides the overflow of a `.fill` image but does
                    // not stop it from taking clicks and hover: a wide
                    // screenshot reached into its neighbour, so pointing at
                    // one image lit or opened another (Phase 7, found by the
                    // owner). Only the visible thumbnail is hit-testable.
                    .contentShape(RoundedRectangle(cornerRadius: Island.rowRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Island.rowRadius, style: .continuous)
                        .stroke(chosen ? Island.accent : (hovering ? Island.hairline.opacity(3) : Island.hairline), lineWidth: chosen ? 2 : 1))
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .islandFrame("clipboard.thumb.\(item.id)")
                .islandHelp("Preview · drag it into another app")
                .accessibilityLabel("Preview \(ClipboardImageHistory.exportName(item))")
                SelectBox(selected: chosen, action: toggle).padding(4)
                    .islandHelp(chosen ? "Chosen" : "Choose for Copy, Drag or Add")
            }
            .contentShape(Rectangle())
            .onDrag { history.exportFiles([item]).first.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
            Text(item.displayName).font(.system(size: 11)).foregroundStyle(Island.secondary).lineLimit(1)
            Text("\(Wording.clock(ISO8601DateFormatter().string(from: item.capturedAt))) · \(ReviewPack.size(item.byteCount))")
                .font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1)
        }
        .frame(width: 96)
    }
}

/// The one-time notice about the image history (see `AppModel.clipboardNoticeVisible`).
struct ClipboardNotice: View {
    let model: AppModel

    var body: some View {
        if model.clipboardNoticeVisible, model.clipboardImages != nil {
            HStack(alignment: .top, spacing: Island.Space.m) {
                Image(systemName: "photo.on.rectangle").font(.system(size: 13)).foregroundStyle(Island.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clipboard keeps your last 5 copied images").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Island.primary)
                    Text("Screenshots and image files you copy are saved on this Mac for 24 hours, to copy or drag into another app later. Nothing leaves this Mac; text is never read.")
                        .font(.system(size: 11)).foregroundStyle(Island.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Button("OK") { model.answerClipboardNotice(keepOn: true) }.buttonStyle(IslandPillStyle(prominent: true))
                    Button("Turn Off") { model.answerClipboardNotice(keepOn: false) }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Island.secondary)
                }
            }
            .padding(Island.cardPadding)
            .background(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).fill(Island.card))
            .overlay(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).stroke(Island.accent.opacity(0.35)))
            .onAppear { model.clipboardNoticeAppeared() }
            .islandFrame("clipboard.notice")
        }
    }
}
