import AppKit
import Foundation

/// Phase 5: typed attachments, Claude's suggested materials, interactive
/// mockups and the two-step hand-off to ChatGPT (ADR-016).
extension AppModel {
    func prepareResultAttachments(_ show: ShowData) {
        guard autoSelectResultAttachments, let store = reportStore else { return }
        store.autoSelectsPrepared = autoSelectPreparedAttachments
        let key = ReportRef.local(sessionKey: show.session.sessionKey, turn: show.turn.index).key
        let before = store.prepareSkips[key]
        do {
            if try store.prepareResults(show) > 0 || store.prepareSkips[key] != before { attachmentsVersion += 1 }
        } catch { attachmentMessage = "Some result files could not be prepared. You can add them manually." }
    }

    /// Phase 17: result files are snapshotted when a final answer arrives,
    /// for every conversation — not when its report is first opened, by
    /// which time later work may have changed them. One `show` per new
    /// answer; answers that were already there at launch are prepared when
    /// opened, as before (their files are checked against the answer's time).
    func prepareNewFinals() {
        guard autoSelectResultAttachments, reportStore != nil else { return }
        if arrivalBaseline == nil { arrivalBaseline = clock() }
        guard let baseline = arrivalBaseline else { return }
        let fresh = finishedAnswers.filter { answer in
            guard answer.completion.isFinal, let finished = Wording.date(answer.at) else { return false }
            return finished >= baseline.addingTimeInterval(-1)
                && !arrivalPrepared.contains(ReportRef.local(sessionKey: answer.sessionKey, turn: answer.turnIndex).key)
        }
        for answer in fresh.prefix(8) {
            let ref = ReportRef.local(sessionKey: answer.sessionKey, turn: answer.turnIndex)
            arrivalPrepared.insert(ref.key)
            let task = Task { @MainActor [weak self] in
                guard let self, let show = try? await self.core.show(sessionKey: answer.sessionKey, turn: answer.turnIndex) else { return }
                self.prepareResultAttachments(show.data)
            }
            arrivalTasks.append(task)
        }
    }

    /// Tests: every arrival-time preparation started so far has finished.
    func arrivalPreparationSettled() async {
        let tasks = arrivalTasks
        arrivalTasks.removeAll()
        for task in tasks { await task.value }
    }

    /// How a stored attachment got here, for its row: prepared by Prompt
    /// Relay or added by the user, and on what evidence.
    public nonisolated static func attachmentStatus(_ attachment: ReportAttachment) -> String {
        switch attachment.effectiveSource {
        case .agentResult: return "Attached automatically · written this turn"
        case .namedVerified: return "Attached automatically · named, changed this turn"
        case .named where attachment.autoPrepared == true: return "Attached automatically · named in the answer, not seen written"
        case .named: return "Attached by you · named in the answer"
        case .windowCapture: return "Auto screenshot"
        case .windowSnapshot: return "Window snapshot by you"
        case .you: return "Attached by you"
        case .claude, .agentObserved: return "Attached by you · from this turn"
        case .clipboard: return "Attached by you · clipboard"
        }
    }

    /// Phase 17: the snapshot against its original now. The hand-off always
    /// uses the snapshot (the bytes of the answer's moment); this only says
    /// so when the two differ.
    public enum SnapshotDrift: Equatable, Sendable { case same, changed, missing }

    public func snapshotDrift(_ attachment: ReportAttachment) -> SnapshotDrift? {
        guard !attachment.isInMemory, let relative = attachment.originalPath, !relative.hasPrefix("…"), !relative.hasPrefix("/"),
              let store = reportStore, let show = detail.value, attachment.reportKey == currentRef?.key else { return nil }
        let roots = attachmentRoots(for: show)
        let candidates = [roots.display, roots.cwd, roots.legacy].compactMap { $0 }.map { $0 + "/" + relative }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return attachment.autoPrepared == true || attachment.effectiveSource != .you ? .missing : nil
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let stamp = "\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\(attributes?[.size] as? Int ?? -1)"
        if let hit = driftCache[attachment.id], hit.stamp == stamp { return hit.drift }
        let drift: SnapshotDrift
        if let size = attributes?[.size] as? Int, size != attachment.byteCount {
            drift = .changed
        } else {
            drift = store.originalChanged(attachment, original: URL(fileURLWithPath: path)).map { $0 ? .changed : .same } ?? .missing
        }
        driftCache[attachment.id] = (stamp, drift)
        return drift
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
            let added = urls.count - problems.count
            self.attachmentNotice = problems.isEmpty && added > 0
                ? "Attached \(added) file\(added == 1 ? "" : "s") — selected for Copy with Context and drag." : nil
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
        /// Phase 17: why Prompt Relay did not attach it by itself (nil: not
        /// tried yet, or automatic preparation is off).
        var autoSkip: ResultAttachments.Skip? = nil

        /// The row's second line: the real state, never a bare "Add".
        public var statusLine: String {
            if let why = notAttachableReason { return why }
            if let autoSkip { return autoSkip.sentence }
            return reason + " · not attached yet"
        }
        public var isWarning: Bool {
            guard attachable else { return true }
            switch autoSkip {
            case .sensitiveName?, .secretContent?, .outsideProject?, .missing?, .unstable?, .storeFailed?, .tooLarge?, .empty?, .unsupportedType?: return true
            default: return false
            }
        }

        /// Phase 16: Add can work — the file is there and of a kind Prompt
        /// Relay keeps (text document, PDF or image); mockups always.
        public var attachable: Bool { kind == .mockup || (exists && ReportStore.canKeep(name: title)) }
        /// Why Add is not offered, in words; nil when it is.
        public var notAttachableReason: String? {
            if attachable { return nil }
            return exists ? "Not attachable — Prompt Relay keeps text, PDF and images" : "File no longer exists — cannot be attached"
        }
    }

    /// Only what Claude showed explicitly (SendUserFile, Artifact) or wrote
    /// this turn **and** named in its answer. Other changed files stay paths.
    public var suggestions: [Suggestion] {
        guard selectedImport == nil, let ref = currentRef, let show = detail.value,
              show.turn.index == selectedTurnIndex, let observed = show.turn.observedDetail else { return [] }
        let roots = attachmentRoots(for: show)
        let added = Set(attachments(for: ref).compactMap(\.originalPath))
        let urls = Set(materials(for: ref).compactMap(\.url))
        // Phase 16: "already attached" is judged by the same display path the
        // attachment was stored under (auto-prepared results use the folder
        // the agent ran in, or the logical project containing it). Before, a
        // separate Git worktree's files were compared in another form, so an
        // attached file stayed listed and Add silently did nothing.
        // Phase 17: a path whose bytes were prepared under another path is
        // attached too (kept once), while that attachment exists.
        let present = Set(attachments(for: ref).map(\.id))
        let duplicates = (reportStore?.prepareDuplicates[ref.key] ?? [:]).filter { present.contains($0.value) }
        let isAdded: (String) -> Bool = { path in
            added.contains(Self.displayPath(path, root: roots.display)) || added.contains(Self.displayPath(path, root: roots.legacy))
                || duplicates[URL(fileURLWithPath: path).standardizedFileURL.path] != nil
        }
        let skips = reportStore?.prepareSkips[ref.key] ?? [:]
        func marked(_ list: [Suggestion]) -> [Suggestion] {
            list.map { s in
                var s = s
                if let path = s.path { s.autoSkip = skips[URL(fileURLWithPath: path).standardizedFileURL.path] }
                return s
            }
        }
        let exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        guard let cwd = roots.cwd else {
            return marked(Self.suggestions(observed: observed, answer: show.turn.finalResponse?.text ?? "", root: roots.legacy,
                                           addedPaths: added, addedURLs: urls, exists: exists, isAdded: isAdded))
        }
        // Names in the answer resolve in the agent's own folder first (its
        // worktree), then in the project — never to another checkout's copy.
        var out = Self.suggestions(observed: observed, answer: show.turn.finalResponse?.text ?? "", root: cwd,
                                   addedPaths: added, addedURLs: urls, exists: exists, isAdded: isAdded)
        if let display = roots.display, display != cwd {
            let known = Set(out.map(\.id).map { $0.split(separator: ":", maxSplits: 1).last.map(String.init) ?? $0 })
            out += Self.suggestions(observed: observed, answer: show.turn.finalResponse?.text ?? "", root: display,
                                    addedPaths: added, addedURLs: urls, exists: exists, isAdded: isAdded)
                .filter { !known.contains($0.path ?? "") && !known.contains($0.artifact?.url ?? "\u{0}") }
        }
        return marked(out)
    }

    /// Phase 16: the folders a turn's files are judged against. `cwd`: where
    /// the agent ran. `display`: the root attachment paths are shown and
    /// stored relative to — the logical project when the agent's folder is
    /// inside it, else the agent's folder (as `ReportStore.prepareResults`).
    /// `legacy`: the root used before Phase 16 (records stored then still
    /// count as added).
    struct AttachmentRoots { let cwd: String?; let display: String?; let legacy: String? }

    func attachmentRoots(for show: ShowData) -> AttachmentRoots {
        let cwd = show.session.project.path
        let legacy = projectPath(containing: cwd) ?? cwd
        return AttachmentRoots(cwd: cwd, display: Self.displayRoot(cwd: cwd, logical: show.session.logicalProject?.path ?? legacy),
                               legacy: legacy)
    }

    /// The logical project when `cwd` is inside it, else `cwd`.
    static func displayRoot(cwd: String?, logical: String?) -> String? {
        guard let cwd else { return logical }
        return logical.flatMap { path(cwd, isInside: $0) ? $0 : nil } ?? cwd
    }

    static func suggestions(observed: ObservedDetail, answer: String, root: String?, addedPaths: Set<String>,
                            addedURLs: Set<String>, exists: (String) -> Bool,
                            isAdded: ((String) -> Bool)? = nil) -> [Suggestion] {
        var out: [Suggestion] = []
        var seen = Set<String>()
        func display(_ path: String) -> String { displayPath(path, root: root) }
        let added: (String) -> Bool = isAdded ?? { addedPaths.contains(display($0)) }
        for path in observed.shownFiles where !seen.contains(path) && !added(path) {
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
        for file in observed.filesChanged where !seen.contains(file.path) && !added(file.path) {
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
            guard standard.hasPrefix(base), !seen.contains(standard), !added(standard),
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
    ///
    /// Phase 16: never silent. Every outcome is said in `attachmentNotice`
    /// (added and selected for hand-off; already attached; why it failed),
    /// and only a record actually written to Prompt Relay's store counts as
    /// "attached". Returns that outcome.
    @discardableResult
    public func accept(_ suggestion: Suggestion) -> AttachOutcome {
        guard let ref = currentRef else { return report(.failed(suggestion.title, "no answer is selected")) }
        guard let store = reportStore else { return report(.failed(suggestion.title, "Prompt Relay's attachment folder is not available")) }
        let roots = detail.value.map(attachmentRoots(for:))
        let root = roots?.display
        let outcome: AttachOutcome
        switch suggestion.kind {
        case .file:
            guard let path = suggestion.path else { return report(.failed(suggestion.title, "its location is not known")) }
            guard FileManager.default.fileExists(atPath: path) else {
                return report(.failed(suggestion.title, "the file no longer exists at \(Self.displayPath(path, root: root))"))
            }
            let before = Set(store.attachments(for: ref).map(\.id))
            do {
                let stored = try store.addFile(from: URL(fileURLWithPath: path), to: ref,
                                               source: suggestion.id.hasPrefix("found:") ? .named : .agentObserved,
                                               displayPath: Self.displayPath(path, root: root))
                // Confirm it is in the store now, not just returned.
                guard store.attachments(for: ref).contains(where: { $0.id == stored.id }) else {
                    outcome = .failed(suggestion.title, "it could not be saved in Prompt Relay's folder"); break
                }
                if before.contains(stored.id) {
                    // The same bytes were attached already (perhaps under another name):
                    // make sure it goes with the hand-off, which is what Add asks for.
                    if !stored.isSelected { try? store.setSelected(stored.id, true) }
                    outcome = .alreadyAttached(stored.originalFilename)
                } else {
                    outcome = .added(stored.originalFilename)
                }
            } catch let error as ReportStoreError {
                outcome = .failed(suggestion.title, Self.reason(for: error))
            } catch {
                outcome = .failed(suggestion.title, "it could not be read")
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
            do {
                let saved = try store.addMaterial(material)
                outcome = saved.id == material.id ? .added(saved.title) : .alreadyAttached(saved.title)
            } catch {
                outcome = .failed(suggestion.title, "the mockup could not be saved")
            }
        }
        return report(outcome)
    }

    /// What happened to one Add (Phase 16).
    public enum AttachOutcome: Equatable, Sendable {
        case added(String)
        case alreadyAttached(String)
        case failed(String, String)

        public var isFailure: Bool { if case .failed = self { return true } else { return false } }

        var sentence: String {
            switch self {
            case .added(let name): return "Attached \(name) — selected for Copy with Context and drag."
            case .alreadyAttached(let name): return "\(name) is already attached to this answer (selected)."
            case .failed(let name, let why): return "\(name) was not attached: \(why)."
            }
        }
    }

    @discardableResult
    private func report(_ outcome: AttachOutcome) -> AttachOutcome {
        attachmentMessage = outcome.isFailure ? outcome.sentence : nil
        attachmentNotice = outcome.isFailure ? nil : outcome.sentence
        attachmentsVersion += 1
        return outcome
    }

    /// Add all: every suggestion, then one honest summary — how many were
    /// attached, and each one that was not, with its reason.
    @discardableResult
    public func acceptAll(_ suggestions: [Suggestion]) -> [AttachOutcome] {
        // Files that cannot be attached are listed as such, not tried.
        let outcomes = suggestions.map { s -> AttachOutcome in
            if let why = s.notAttachableReason { return .failed(s.title, why.lowercased().replacingOccurrences(of: " — ", with: ": ")) }
            return accept(s)
        }
        let failures = outcomes.filter(\.isFailure)
        let attached = outcomes.count - failures.count
        let head = attached == outcomes.count
            ? "Attached \(attached) file\(attached == 1 ? "" : "s") — selected for Copy with Context and drag."
            : "Attached \(attached) of \(outcomes.count)."
        attachmentNotice = failures.isEmpty ? head : nil
        attachmentMessage = failures.isEmpty ? nil : ([head] + failures.map(\.sentence)).joined(separator: " ")
        attachmentsVersion += 1
        return outcomes
    }

    /// The reason part of `message(for:file:)`, for "X was not attached: …".
    static func reason(for error: ReportStoreError) -> String {
        switch error {
        case .notAnImage: return "it is not an image"
        case .tooLarge: return "it is larger than 50 MB"
        case .documentTooLarge: return "text documents can be at most 1 MB"
        case .lockUnavailable: return "Prompt Relay's folder is busy or not writable; nothing was saved — try again"
        case .noPermission: return "macOS does not allow Prompt Relay to read it"
        case .damagedImage: return "it is damaged or not a readable image"
        case .unreadable: return "it could not be read (moved, deleted or a folder?)"
        case .writeFailed: return "it could not be saved in Prompt Relay's folder"
        case .removeFailed: return "it could not be saved"
        case .empty: return "it is empty"
        case .unsupported: return "Prompt Relay keeps text documents, PDFs and images, not this kind of file"
        }
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
        handoffs[ref.key] = ids.isEmpty ? nil : HandoffStep(ref: ref, text: text, attachmentIDs: ids, textChangeCount: clipboard.changeCount, startedAt: clock())
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
