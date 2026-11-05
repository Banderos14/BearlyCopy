import AppKit
import Foundation

/// Phase 5: typed attachments, Claude's suggested materials, interactive
/// mockups and the two-step hand-off to ChatGPT (ADR-016).
extension AppModel {
    func prepareResultAttachments(_ show: ShowData) {
        guard autoSelectResultAttachments, let store = reportStore else { return }
        do {
            if try store.prepareResults(show) > 0 { attachmentsVersion += 1 }
        } catch { attachmentMessage = "Some result files could not be prepared. You can add them manually." }
    }

    /// Phase 9.4: the header's version — no unconfirmed "Unknown" host.
    public var currentCompactSourceLabel: String {
        if let imported = selectedImport {
            return "Imported by you · " + (imported.assistantTitle ?? "AI")
        }
        return detail.value?.session.compactSourceLabel ?? selectedSession?.compactSourceLabel ?? "This Mac"
    }

    public var currentSourceLabel: String {
        if let imported = selectedImport {
            return "Imported by you · " + (imported.assistantTitle ?? "Unknown") + " · " + (imported.host?.title ?? "Unknown")
        }
        return detail.value?.session.sourceLabel ?? selectedSession?.sourceLabel ?? "Unknown"
    }

    // MARK: Materials (links, mockups)

    public func materials(for ref: ReportRef?) -> [ReportMaterial] {
        _ = attachmentsVersion
        guard let ref, let store = reportStore else { return [] }
        return store.materials(for: ref)
    }

    /// Selected files, mockups and links of the current report: what the
    /// Quick Peek line and the hand-off count.
    public struct MaterialSummary: Equatable, Sendable {
        public var documents = 0
        public var images = 0
        public var mockups = 0
        public var mockupStates = 0
        public var links = 0
        public var needsVisualReview: Bool { mockups > 0 }
        public var isEmpty: Bool { documents + images + mockups + links == 0 }

        /// "1 document · 1 mockup (7 states) · 3 images"
        public var line: String { parts.joined(separator: " · ") }

        /// The same facts one by one (chips); empty kinds are left out.
        public var parts: [String] {
            var parts: [String] = []
            if documents > 0 { parts.append(documents == 1 ? "1 document" : "\(documents) documents") }
            if mockups > 0 {
                let states = mockupStates == 1 ? "1 state" : "\(mockupStates) states"
                parts.append(mockups == 1 ? "1 mockup (\(states))" : "\(mockups) mockups (\(states))")
            }
            if images > 0 { parts.append(images == 1 ? "1 image" : "\(images) images") }
            if links > 0 { parts.append(links == 1 ? "1 link" : "\(links) links") }
            return parts
        }
    }

    public func materialSummary(for ref: ReportRef?) -> MaterialSummary {
        var summary = MaterialSummary()
        for a in attachments(for: ref) where a.isSelected && a.mockupID == nil {
            if a.effectiveKind == .image { summary.images += 1 } else { summary.documents += 1 }
        }
        for m in materials(for: ref) where m.selected {
            if m.kind == .mockup { summary.mockups += 1; summary.mockupStates += m.states.count } else { summary.links += 1 }
        }
        return summary
    }

    public func setSelected(_ attachment: ReportAttachment, _ selected: Bool) {
        try? reportStore?.setSelected(attachment.id, selected)
        attachmentsVersion += 1
    }

    public func setSelected(_ material: ReportMaterial, _ selected: Bool) {
        var copy = material
        copy.selected = selected
        try? reportStore?.updateMaterial(copy)
        attachmentsVersion += 1
    }

    public func setStateSelected(_ material: ReportMaterial, state: String, _ selected: Bool) {
        var copy = material
        guard let i = copy.states.firstIndex(where: { $0.id == state }) else { return }
        copy.states[i].selected = selected
        try? reportStore?.updateMaterial(copy)
        attachmentsVersion += 1
    }

    public func removeMaterial(_ material: ReportMaterial) {
        do { try reportStore?.removeMaterial(material.id); attachmentMessage = nil } catch {
            attachmentMessage = "\(material.title) could not be removed. Try again."
        }
        attachmentsVersion += 1
    }

    /// Images for the states of a mockup, chosen in the file picker: each
    /// file goes to the state whose name it carries, or the next state
    /// without an image, or becomes a new state named after the file.
    public func importStateImages(_ material: ReportMaterial) {
        presentDialog(.images) { [weak self] urls in
            guard let self, let urls, let store = self.reportStore else { return }
            var current = store.materials(for: ReportStore.ref(forKey: material.reportKey)).first { $0.id == material.id } ?? material
            var problems: [String] = []
            for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let base = url.deletingPathExtension().lastPathComponent.lowercased()
                var target = current.states.first { base.contains($0.id.lowercased()) || base.contains($0.title.lowercased()) }
                    ?? current.states.first { $0.status != .captured }
                if target == nil {
                    let state = MockupState(id: Self.slug(url.deletingPathExtension().lastPathComponent),
                                            title: url.deletingPathExtension().lastPathComponent, summary: nil,
                                            interactive: [], status: .namedOnly, attachmentID: nil, failure: nil, selected: true)
                    current.states.append(state)
                    try? store.updateMaterial(current)
                    target = state
                }
                do {
                    current = try store.setStateImage(from: url, mockupID: current.id, stateID: target!.id)
                } catch let error as ReportStoreError {
                    problems.append(Self.message(for: error, file: url.lastPathComponent))
                    current = store.allMaterials().first { $0.id == current.id } ?? current
                } catch {
                    problems.append("\(url.lastPathComponent) could not be read")
                }
            }
            self.attachmentMessage = problems.isEmpty ? nil : problems.joined(separator: "; ")
            self.attachmentsVersion += 1
        }
    }

    /// One image for one state.
    public func importStateImage(_ material: ReportMaterial, state: MockupState) {
        presentDialog(.images) { [weak self] urls in
            guard let self, let url = urls?.first, let store = self.reportStore else { return }
            do {
                _ = try store.setStateImage(from: url, mockupID: material.id, stateID: state.id)
                self.attachmentMessage = nil
            } catch let error as ReportStoreError {
                self.attachmentMessage = Self.message(for: error, file: url.lastPathComponent)
            } catch {
                self.attachmentMessage = "\(url.lastPathComponent) could not be read"
            }
            self.attachmentsVersion += 1
        }
    }

    static func slug(_ text: String) -> String {
        let lowered = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
        let collapsed = lowered.split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "state" : String(collapsed.prefix(40))
    }

    // MARK: Suggestions from what Claude did in the turn

    /// A material Claude prepared for the user in this turn, not added yet.
    public struct Suggestion: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case file, mockup }
        public let id: String
        public let kind: Kind
        public let title: String
        /// Why it is suggested, in plain words.
        public let reason: String
        /// The file on this Mac (or the mockup's source), when known.
        public let path: String?
        public let exists: Bool
        public let artifact: ObservedArtifact?
    }

    /// Only what Claude showed explicitly (SendUserFile, Artifact) or wrote
    /// this turn **and** named in its answer. Other changed files stay paths.
    public var suggestions: [Suggestion] {
        guard selectedImport == nil, let ref = currentRef, let show = detail.value,
              show.turn.index == selectedTurnIndex, let observed = show.turn.observedDetail else { return [] }
        let root = projectPath(containing: show.session.project.path) ?? show.session.project.path
        return Self.suggestions(observed: observed, answer: show.turn.finalResponse?.text ?? "", root: root,
                                addedPaths: Set(attachments(for: ref).compactMap(\.originalPath)),
                                addedURLs: Set(materials(for: ref).compactMap(\.url)),
                                exists: { FileManager.default.fileExists(atPath: $0) })
    }

    static func suggestions(observed: ObservedDetail, answer: String, root: String?, addedPaths: Set<String>,
                            addedURLs: Set<String>, exists: (String) -> Bool) -> [Suggestion] {
        var out: [Suggestion] = []
        var seen = Set<String>()
        func display(_ path: String) -> String { displayPath(path, root: root) }
        for path in observed.shownFiles where !seen.contains(path) && !addedPaths.contains(display(path)) {
            seen.insert(path)
            out.append(Suggestion(id: "shown:" + path, kind: .file, title: (path as NSString).lastPathComponent,
                                  reason: "The agent showed it to you", path: path, exists: exists(path), artifact: nil))
        }
        for artifact in observed.artifacts {
            let key = artifact.url ?? artifact.sourcePath ?? ""
            guard !key.isEmpty, !seen.contains(key), !(artifact.url.map(addedURLs.contains) ?? false) else { continue }
            seen.insert(key)
            let source = artifact.sourcePath
            out.append(Suggestion(id: "artifact:" + key, kind: .mockup, title: artifact.title ?? "Claude artifact",
                                  reason: "Claude published it as an artifact", path: source,
                                  exists: source.map(exists) ?? false, artifact: artifact))
        }
        for file in observed.filesChanged where !seen.contains(file.path) && !addedPaths.contains(display(file.path)) {
            let relative = display(file.path)
            let name = (file.path as NSString).lastPathComponent
            // Named in the answer: the relative path, or the file name as a whole word.
            guard answer.contains(relative) || answer.range(of: #"(?<![\w.-])"# + NSRegularExpression.escapedPattern(for: name)
                                                           + #"(?![\w-])"#, options: .regularExpression) != nil else { continue }
            seen.insert(file.path)
            out.append(Suggestion(id: "named:" + file.path, kind: .file, title: name,
                                  reason: "Observed file change; named in the answer", path: file.path,
                                  exists: exists(file.path), artifact: nil))
        }
        // Named in the answer and present in the project, but not written by
        // an observed Edit/Write (a script made it, Phase 5.11). Only
        // documents and images inside the project; only existing files.
        guard let root else { return out }
        let base = root.hasSuffix("/") ? root : root + "/"
        let pattern = #"(?<![\w.-])((?:/|\./)?[\w][\w./-]*\.(?:png|jpe?g|gif|webp|heic|pdf|md|txt|html?|svg|csv|json))(?![\w-])"#
        let ns = answer as NSString
        let matches = (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?
            .matches(in: answer, range: NSRange(location: 0, length: ns.length)) ?? []
        for match in matches where out.count < 12 {
            let token = ns.substring(with: match.range(at: 1))
            let path = token.hasPrefix("/") ? token : base + (token.hasPrefix("./") ? String(token.dropFirst(2)) : token)
            let standard = (path as NSString).standardizingPath
            guard standard.hasPrefix(base), !seen.contains(standard), !addedPaths.contains(display(standard)),
                  exists(standard) else { continue }
            seen.insert(standard)
            out.append(Suggestion(id: "found:" + standard, kind: .file, title: (standard as NSString).lastPathComponent,
                                  reason: "Named in the answer; in the project, not seen being written", path: standard,
                                  exists: true, artifact: nil))
        }
        return out
    }

    /// Project-relative path, or the last two components (no user name).
    static func displayPath(_ path: String, root: String?) -> String {
        if let root, path.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            return String(path.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1))
        }
        let parts = path.split(separator: "/")
        return parts.count > 2 ? "…/" + parts.suffix(2).joined(separator: "/") : path
    }

    /// The user's click on a suggestion: a snapshot of the file, or a mockup
    /// record (its declared state names are read from the source, never run).
    public func accept(_ suggestion: Suggestion) {
        guard let ref = currentRef, let store = reportStore else { return }
        let root = detail.value.flatMap { projectPath(containing: $0.session.project.path) ?? $0.session.project.path }
        switch suggestion.kind {
        case .file:
            guard let path = suggestion.path else { return }
            do {
                try store.addFile(from: URL(fileURLWithPath: path), to: ref,
                                  source: suggestion.id.hasPrefix("found:") ? .named : .agentObserved,
                                  displayPath: Self.displayPath(path, root: root))
                attachmentMessage = nil
            } catch let error as ReportStoreError {
                attachmentMessage = Self.message(for: error, file: suggestion.title)
            } catch {
                attachmentMessage = "\(suggestion.title) could not be read"
            }
        case .mockup:
            let artifact = suggestion.artifact
            let declared = suggestion.path.flatMap { MockupStates.declared(inHTMLAt: URL(fileURLWithPath: $0)) }
            let states = (declared?.states ?? []).map {
                MockupState(id: $0.id, title: $0.title, summary: $0.description, interactive: $0.interactive ?? [],
                            status: .namedOnly, attachmentID: nil, failure: nil, selected: true)
            }
            let material = ReportMaterial(id: UUID().uuidString.lowercased(), reportKey: ref.key, kind: .mockup,
                                          title: declared?.title ?? suggestion.title, url: artifact?.url,
                                          audience: artifact?.audience,
                                          sourcePath: suggestion.path.map { Self.displayPath($0, root: root) },
                                          version: nil, addedAt: ReportStore.now(),
                                          provenance: "Published by Claude in this turn (Artifact tool) [Confirmed locally]",
                                          selected: true, states: states)
            do { try store.addMaterial(material); attachmentMessage = nil } catch {
                attachmentMessage = "The mockup could not be saved."
            }
        }
        attachmentsVersion += 1
    }

    public func acceptAll(_ suggestions: [Suggestion]) {
        for s in suggestions where s.exists || s.kind == .mockup { accept(s) }
    }

    // MARK: Adding files

    /// Documents, PDFs and images the user chose for the current report.
    public func chooseFiles() {
        guard let ref = currentRef, reportStore != nil else { return }
        presentDialog(.files) { [weak self] urls in
            guard let self, let urls, let store = self.reportStore else { return }
            var problems: [String] = []
            for url in urls {
                do { try store.addFile(from: url, to: ref, source: .you, displayPath: url.lastPathComponent) }
                catch let error as ReportStoreError { problems.append(Self.message(for: error, file: url.lastPathComponent)) }
                catch { problems.append("\(url.lastPathComponent) could not be read") }
            }
            self.attachmentMessage = problems.isEmpty ? nil : problems.joined(separator: "; ")
            self.attachmentsVersion += 1
        }
    }

    // MARK: Clipboard images

    /// Copies chosen clipboard images into the current report (or a state).
    public func attachClipboardImages(_ items: [ClipboardImageHistory.Item], mockup: ReportMaterial? = nil) {
        guard let ref = currentRef, let store = reportStore, let history = clipboardImages else { return }
        var problems: [String] = []
        for item in items {
            let name = item.originalName ?? "Screenshot \(Self.clipboardStamp(item.capturedAt)).png"
            do {
                if let mockup, let state = (store.allMaterials().first { $0.id == mockup.id })?.states.first(where: { $0.status != .captured }) {
                    _ = try store.setStateImage(from: history.url(for: item), mockupID: mockup.id, stateID: state.id)
                } else {
                    try store.addData(try Data(contentsOf: history.url(for: item)), name: name, to: ref, source: .clipboard)
                }
            } catch {
                problems.append("\(name) could not be attached")
            }
        }
        attachmentMessage = problems.isEmpty ? nil : problems.joined(separator: "; ")
        attachmentsVersion += 1
    }

    static func clipboardStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH.mm.ss"
        return f.string(from: date)
    }

    // MARK: Hand-off names and step 2

    /// Hand-off file names: documents keep their names; mockup states get
    /// `<mockup>-NN-<state>.png` in state order. Images keep theirs.
    func handoffNames(for ref: ReportRef) -> [String: String] {
        var names: [String: String] = [:]
        for m in materials(for: ref) where m.kind == .mockup && m.selected {
            let slug = Self.slug(m.title)
            var n = 0
            for state in m.states where state.selected && state.status == .captured {
                n += 1
                guard let id = state.attachmentID else { continue }
                let ext = attachments(for: ref).first { $0.id == id }.map { ($0.storedFilename as NSString).pathExtension } ?? "png"
                names[id] = String(format: "%@-%02d-%@.%@", slug, n, state.id, ext)
            }
        }
        return names
    }

    /// The selected files in hand-off order: documents, mockup states, images.
    public func handoffAttachments(for ref: ReportRef?) -> [ReportAttachment] {
        guard let ref else { return [] }
        let all = attachments(for: ref)
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let documents = all.filter { $0.isSelected && $0.mockupID == nil && $0.effectiveKind != .image }
        let states = materials(for: ref).filter { $0.kind == .mockup && $0.selected }.flatMap { m in
            m.states.filter { $0.selected && $0.status == .captured }.compactMap { $0.attachmentID.flatMap { byID[$0] } }
        }
        let images = all.filter { $0.isSelected && $0.mockupID == nil && $0.effectiveKind == .image }
        return documents + states + images
    }

    func beginHandoff(ref: ReportRef, text: String) {
        let ids = handoffAttachments(for: ref).map(\.id)
        handoffs[ref.key] = ids.isEmpty ? nil : HandoffStep(ref: ref, text: text, attachmentIDs: ids, textChangeCount: clipboard.changeCount)
    }

    /// Puts the hand-off's own text on the clipboard again, byte for byte
    /// (not rebuilt: the same snapshot the files belong to).
    public func copyHandoffTextAgain() {
        guard let step = activeHandoff else { return }
        do {
            try clipboard.copy(step.text)
            handoffs[step.ref.key]?.textChangeCount = clipboard.changeCount
            handoffs[step.ref.key]?.filesCopied = false
            finishCopy(.copied(.context, characters: step.characters), token: Self.reviewToken(step.ref))
        } catch {
            finishCopy(.failed(Self.message(for: error)))
        }
    }

    /// The island closed with a hand-off open: it waits, never ends by itself.
    func suspendHandoffs() {
        for key in handoffs.keys { handoffs[key]?.resumed = true }
    }

    func islandOpened() { clipboardTick += 1 }

    // MARK: Hand-off persistence (next to the reports, app data dir)

    static func handoffsURL(_ store: ReportStore) -> URL { store.root.appendingPathComponent("handoffs.json") }

    /// Steps saved before a restart; one whose files are gone is dropped.
    static func loadHandoffs(_ store: ReportStore) -> [String: HandoffStep] {
        guard let data = try? Data(contentsOf: handoffsURL(store)),
              let saved = try? JSONDecoder().decode([String: HandoffStep].self, from: data) else { return [:] }
        let present = Set(store.allAttachments().filter { store.fileURL(for: $0).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }.map(\.id))
        return saved.filter { $0.value.attachmentIDs.allSatisfy(present.contains) }
    }

    func saveHandoffs() {
        guard let reportStore else { return }
        let url = Self.handoffsURL(reportStore)
        if handoffs.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: reportStore.root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(handoffs).write(to: url, options: [.atomic])
    }

    /// The files of the active hand-off: exactly the set chosen at the copy,
    /// and only while that report is shown and its choice is unchanged.
    private func preparedHandoffFiles() -> [URL] {
        guard let step = activeHandoff, !handoffSelectionChanged, let store = reportStore else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: attachments(for: step.ref).map { ($0.id, $0) })
        let chosen = step.attachmentIDs.compactMap { byID[$0] }
        guard chosen.count == step.attachmentIDs.count else { return [] }
        do { return try store.handoffFiles(for: chosen.filter { !$0.isInMemory }, names: handoffNames(for: step.ref)) } catch {
            attachmentMessage = "Prompt Relay could not prepare the files."
            return []
        }
    }

    /// Phase 10: the in-memory snapshots of the active hand-off (image data).
    private func preparedHandoffImages() -> [ClipboardImage]? {
        guard let step = activeHandoff, !handoffSelectionChanged else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: attachments(for: step.ref).map { ($0.id, $0) })
        let memory = step.attachmentIDs.compactMap { byID[$0] }.filter(\.isInMemory)
        let images = memory.compactMap(memoryImage)
        return images.count == memory.count ? images : nil
    }

    /// Step 2: the files on the clipboard, like ⌘C in Finder; in-memory
    /// window snapshots go as image data next to them (no file is made).
    public func copyHandoffFiles() {
        guard !handoffSelectionChanged else {
            finishCopy(.failed("The chosen files changed. Use Copy with Context again."))
            return
        }
        let files = preparedHandoffFiles()
        guard let images = preparedHandoffImages() else {
            finishCopy(.failed("A window snapshot is no longer in memory. Use Copy with Context again."))
            return
        }
        guard !files.isEmpty || !images.isEmpty else { finishCopy(.failed("The files are missing.")); return }
        do {
            try clipboard.copyFiles(files, images: images)
            handoffStep?.filesCopied = true
            finishCopy(.copied(.files, characters: files.count), token: Self.handoffToken)
        } catch {
            finishCopy(.failed("The files could not be copied."))
        }
    }

    public func revealHandoffFiles() {
        let files = preparedHandoffFiles()
        guard !files.isEmpty else {
            attachmentMessage = (preparedHandoffImages()?.isEmpty == false)
                ? "Window snapshots are kept in memory only, not as files. Use Copy Files or Drag."
                : "The files are missing."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }



    /// Done: the user finished this hand-off. The clipboard keeps what it has.
    public func endHandoff() {
        guard let ref = currentRef else { return }
        handoffs[ref.key] = nil
        onHandoffDone?()
    }

    /// The prepared hand-off files (for an AppKit multi-file drag).
    public func handoffFileURLs() -> [URL] { preparedHandoffFiles() }

    /// Files and in-memory snapshots of the active hand-off, for a drag.
    public func handoffDragPayloads() -> [DragPayload] {
        preparedHandoffFiles().map(DragPayload.file) + (preparedHandoffImages() ?? []).map(DragPayload.image)
    }

    // MARK: Attachment preview

    /// Opens one attachment of the report shown, read-only. Nothing about the
    /// selection (session, answer, chosen files) changes.
    public func openAttachmentPreview(_ attachment: ReportAttachment) {
        previewAttachmentID = attachment.id
        navigate(to: .attachmentPreview)
    }

    /// The attachment being previewed, only while it belongs to the report shown.
    public var previewedAttachment: ReportAttachment? {
        attachments(for: currentRef).first { $0.id == previewAttachmentID }
    }

    /// The text of a document attachment for reading (at most 1 MB, UTF-8);
    /// nil for binary or unreadable files. The stored copy is only read.
    public func previewText(_ attachment: ReportAttachment) -> String? {
        guard attachment.effectiveKind == .document, let url = attachmentURL(attachment),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= 1024 * 1024 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func openMockup(_ material: ReportMaterial) {
        openMockupID = material.id
        navigate(to: .mockup)
    }

    public var openMockupMaterial: ReportMaterial? {
        materials(for: currentRef).first { $0.id == openMockupID }
    }
}

/// The optional "Mockup States" declaration of a page (ADR-016 §4.4): a
/// `<script type="application/json" id="prompt-relay-states">` block. Only
/// read as JSON; the page is never run.
public enum MockupStates {
    public struct Declaration: Decodable, Equatable, Sendable {
        public struct State: Decodable, Equatable, Sendable {
            public let id: String
            public let title: String
            public let description: String?
            public let interactive: [String]?
        }
        public let title: String?
        public let states: [State]
    }

    static let maxSourceBytes = 4 * 1024 * 1024

    public static func declared(inHTMLAt url: URL) -> Declaration? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size <= maxSourceBytes,
              let data = try? Data(contentsOf: url), let html = String(data: data, encoding: .utf8) else { return nil }
        return declared(inHTML: html)
    }

    public static func declared(inHTML html: String) -> Declaration? {
        guard let open = html.range(of: #"<script[^>]*id=["']prompt-relay-states["'][^>]*>"#, options: .regularExpression),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex) else { return nil }
        let json = html[open.upperBound..<close.lowerBound]
        guard let decl = try? JSONDecoder().decode(Declaration.self, from: Data(json.utf8)) else { return nil }
        let unique = decl.states.reduce(into: [Declaration.State]()) { acc, s in
            if !acc.contains(where: { $0.id == s.id }), !s.id.isEmpty { acc.append(s) }
        }
        let limited: [Declaration.State] = Array(unique[..<min(unique.count, 30)])
        return Declaration(title: decl.title, states: limited)
    }
}


/// Phase 10: one dragged thing — a file, or image data held only in memory.
public enum DragPayload: Equatable {
    case file(URL)
    case image(ClipboardImage)
}
