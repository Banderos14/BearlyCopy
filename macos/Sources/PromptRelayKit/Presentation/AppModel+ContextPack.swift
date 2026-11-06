import AppKit
import Foundation

/// The state of the pack being prepared.
public enum ContextPackState: Equatable {
    case idle
    case building
    case ready(BuiltContextPack)
    case failed(String)

    public var pack: BuiltContextPack? { if case .ready(let p) = self { return p } else { return nil } }
}

/// What the user did with one prepared pack. Copied, dragged or exported
/// never means another app received it: Prompt Relay cannot see that.
public struct PackProgress: Equatable, Sendable {
    public var packID: String?
    public var textCopiedAt: String?
    /// The pasteboard change count right after the text was written.
    public var textChangeCount: Int?
    public var filesCopiedAt: String?
    public var dragStartedAt: String?
    public var exportedAt: String?
    public var exportFolder: URL?
}

/// One prepared pack in the local Handoff History: which results, which
/// receiver the user picked, and what they did. No request, answer,
/// instructions or image is stored here; the results stay in the Core.
public struct HandoffRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Event: String, Codable, Sendable {
        case prepared, copiedText = "copied_text", copiedFiles = "copied_files", dragStarted = "drag_started", exported

        public var title: String {
            switch self {
            case .prepared: return "Prepared"
            case .copiedText: return "Text copied"
            case .copiedFiles: return "Files copied"
            case .dragStarted: return "Drag started"
            case .exported: return "Exported"
            }
        }
    }
    public struct Step: Codable, Equatable, Sendable {
        public let event: Event
        public let at: String
    }
    public struct Result: Codable, Equatable, Sendable {
        public let ref: ReportRef
        /// "Codex · prompt-relay · Fix the cache #3" — display only.
        public let label: String
    }

    public let id: String
    public let preparedAt: String
    public let destination: HandoffDestination
    public let results: [Result]
    public let attachmentCount: Int
    public let temporaryImages: Int
    public let characters: Int
    public let formatVersion: Int
    public var steps: [Step]

    public var lastEvent: Event { steps.last?.event ?? .prepared }
    public func has(_ event: Event) -> Bool { steps.contains { $0.event == event } }
}

/// Phase 13: Context Packs — choose results, prepare one pack, hand it over
/// (text, then files), keep a short local history (docs/CONTEXT_PACK.md).
extension AppModel {
    // MARK: Choosing results

    public func isInPack(_ ref: ReportRef) -> Bool { packRefs.contains(ref) }

    /// Adds a result once (a pack never holds one result twice).
    @discardableResult
    public func addToPack(_ ref: ReportRef) -> Bool {
        guard !packRefs.contains(ref) else { return false }
        guard packRefs.count < ContextPackFormat.maxResults else {
            packMessage = "A Context Pack holds at most \(ContextPackFormat.maxResults) results. Remove one first, or export results separately."
            return false
        }
        packRefs.append(ref)
        packMessage = nil
        return true
    }

    public func removeFromPack(_ ref: ReportRef) {
        packRefs.removeAll { $0 == ref }
        packMessage = nil
    }

    public func togglePack(_ ref: ReportRef) {
        if isInPack(ref) { removeFromPack(ref) } else { addToPack(ref) }
    }

    /// Moves one result up (-1) or down (+1); the others keep their order.
    public func movePackItem(_ ref: ReportRef, by offset: Int) {
        guard let i = packRefs.firstIndex(of: ref) else { return }
        let j = i + offset
        guard packRefs.indices.contains(j) else { return }
        packRefs.swapAt(i, j)
    }

    /// Forgets the selection and the draft instructions (no history is deleted).
    public func clearPack() {
        packRefs = []
        packInstructions = ""
        contextPack = .idle
        packProgress = PackProgress()
        packAwaitsSensitiveConfirmation = false
        packMessage = nil
    }

    /// Opens the Context Pack view (from the Inbox bar, ⋯ or History).
    public func openContextPack() { navigate(to: .contextPack) }

    // MARK: Rows before preparing

    /// What a chosen result is, before the pack is prepared: from the Inbox
    /// rows or the conversations already loaded (no extra Core call).
    public struct PackRow: Equatable, Identifiable, Sendable {
        public let ref: ReportRef
        public let provider: String
        public let profile: String
        public let host: String
        public let project: String
        public let title: String
        public let answeredAt: String?
        public let characters: Int?
        public let available: Bool
        public let nativeSessionID: String?
        public var id: String { ref.key }
    }

    public var packRows: [PackRow] { packRefs.map(packRow) }

    func packRow(_ ref: ReportRef) -> PackRow {
        switch ref {
        case .imported(let id):
            let r = imports.first { $0.id == id }
            return PackRow(ref: ref, provider: "Imported by you", profile: r?.assistantTitle ?? "AI", host: r?.host?.title ?? "Unknown",
                           project: r?.projectName ?? "No project", title: r.map { Self.oneLine($0.task ?? $0.text) } ?? "Import no longer available",
                           answeredAt: r?.importedAt, characters: r.map { CharacterCount.of($0.text) }, available: r != nil,
                           nativeSessionID: nil)
        case .local(let key, let turn):
            if let r = inbox.value?.first(where: { $0.sessionKey == key && $0.turn == turn }) {
                return PackRow(ref: ref, provider: r.provider.shortTitle, profile: profileName(r.profileKey), host: r.host.title,
                               project: projectName(of: r),
                               title: Self.oneLine(r.request?.displayPreview ?? r.response.preview),
                               answeredAt: r.answeredAt, characters: r.response.charCount, available: true,
                               nativeSessionID: r.nativeSessionID)
            }
            let session = allSessions.first { $0.sessionKey == key }
            let (project, label) = describe(ref)
            return PackRow(ref: ref, provider: session?.provider.shortTitle ?? "Agent",
                           profile: session.map { profileName($0.profileKey) } ?? "—",
                           host: session?.source?.environment.title ?? "Unknown", project: project,
                           title: session.map(Wording.sessionTitle) ?? label, answeredAt: nil, characters: nil,
                           available: session != nil || allSessions.isEmpty, nativeSessionID: session?.nativeSessionID)
                .with(turn: turn)
        }
    }

    /// Two chosen results whose agents reported the same native session id
    /// from different profiles: they stay two results (never one conversation).
    public var packSharesNativeSessionAcrossProfiles: Bool {
        let rows = packRows.compactMap { row in row.nativeSessionID.map { ($0, row) } }
        let byNative = Dictionary(grouping: rows, by: \.0)
        // Two turns of one conversation share it too; only different conversations count.
        return byNative.values.contains { group in Set(group.map { conversationKey($0.1.ref) }).count > 1 }
    }

    private func conversationKey(_ ref: ReportRef) -> String {
        if case .local(let key, _) = ref { return key }
        return ref.key
    }

    public var packMixesProjects: Bool { Set(packRows.map(\.project)).count > 1 }

    /// A rough size before preparing: answers' characters plus a frame.
    public var packEstimatedCharacters: Int {
        packRows.reduce(0) { $0 + ($1.characters ?? 0) + 2_500 } + CharacterCount.of(packInstructions) + 1_200
    }

    /// The chosen attachments of every chosen result (counted, not read).
    public var packSelectedAttachmentCount: Int {
        packRefs.reduce(0) { $0 + handoffAttachments(for: $1).count }
    }

    // MARK: Preparing

    /// The prepared pack no longer matches the choice (results, order,
    /// instructions, receiver or chosen attachments changed).
    public var packIsStale: Bool {
        guard let pack = contextPack.pack else { return false }
        return pack.refs != packRefs || pack.instructions != normalizedInstructions || pack.destination != packDestination
            || pack.attachments.map(\.id) != packRefs.flatMap { handoffAttachments(for: $0).map(\.id) }
            || packIncludesManifest != pack.includesManifest
    }

    var normalizedInstructions: String? {
        packInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : packInstructions
    }

    static let manifestFenceEnd = "\n```\n"

    /// Builds the pack from the Core (one call for every local result) and
    /// the app's attachments; records "Prepared" in the Handoff History.
    public func prepareContextPack() async {
        guard !packRefs.isEmpty else { contextPack = .failed("Choose at least one result."); return }
        contextPack = .building
        packAwaitsSensitiveConfirmation = false
        packSensitiveConfirmed = false
        switch await buildContextPack(packRefs, instructions: normalizedInstructions, destination: packDestination) {
        case .success(let pack):
            contextPack = .ready(pack)
            packProgress = PackProgress(packID: pack.id)
            recordHandoff(pack)
        case .failure(let failure):
            contextPack = .failed(failure.message)
        }
    }

    public func buildContextPack(_ refs: [ReportRef], instructions: String?,
                                 destination: HandoffDestination) async -> Result<BuiltContextPack, PackFailure> {
        var seen = Set<ReportRef>()
        guard refs.allSatisfy({ seen.insert($0).inserted }) else { return .failure(PackFailure(message: "A result is listed twice.")) }
        guard refs.count <= ContextPackFormat.maxResults else {
            return .failure(PackFailure(message: "A Context Pack holds at most \(ContextPackFormat.maxResults) results."))
        }
        // Result files the agent wrote and named are prepared as for Copy with Context.
        if autoSelectResultAttachments {
            for case .local(let key, let turn) in refs {
                if let shown = try? await core.show(sessionKey: key, turn: turn) { prepareResultAttachments(shown.data) }
            }
        }
        let slots: [PackSlot] = refs.map { ref in
            if case .local(let key, let turn) = ref { return .local(sessionKey: key, turn: turn) }
            return .external
        }
        var core: ContextPackData?
        if slots.contains(where: { $0 != .external }) {
            do { core = try await self.core.contextPack(slots).data } catch {
                return .failure(PackFailure(message: Self.message(for: error)))
            }
        }
        let builtAt = core?.exportedAt ?? ReportStore.now()
        var inputs: [ContextPackComposer.Input] = []
        var items: [BuiltContextPack.Item] = []
        var manifests: [PackManifest.Result] = []
        var coreWarnings: [String] = []
        for (i, ref) in refs.enumerated() {
            let chosen = handoffAttachments(for: ref)
            let missing = Set(chosen.filter { !isAttachmentAvailable($0) }.map(\.id))
            let statuses = chosen.map { a in
                BuiltContextPack.AttachmentStatus(id: a.id, ref: ref, name: handoffNames(for: ref)[a.id] ?? a.originalFilename,
                                                  kind: a.effectiveKind, bytes: a.byteCount,
                                                  availability: missing.contains(a.id) ? .missing : a.isInMemory ? .memoryOnly : .file,
                                                  origin: a.effectiveSource)
            }
            let selectedMaterials = materials(for: ref).filter(\.selected)
            let attachmentFindings = attachmentSecretFindings(chosen.filter { !missing.contains($0.id) }, names: handoffNames(for: ref))
            switch ref {
            case .local(let key, let turn):
                guard let result = core?.results.first(where: { $0.sessionKey == key && $0.turn == turn }) else {
                    return .failure(PackFailure(message: "A chosen result is no longer in Prompt Relay's history."))
                }
                let label = profileKey(ofSession: key).flatMap { profileLabels[$0.id] }.flatMap { $0.isEmpty ? nil : $0 }
                let input = ContextPackComposer.Input(ref: ref, source: .local(result), profileLabel: label, attachments: chosen,
                                                      materials: selectedMaterials, names: handoffNames(for: ref), missing: missing)
                inputs.append(input)
                coreWarnings += result.warnings.map { "Result \(i + 1): \($0)" }
                var m = result.manifest
                m.position = i + 1
                m.profile = input.entry.profile
                m.attachments = statuses.map(\.manifest)
                manifests.append(m)
                items.append(.init(ref: ref, position: i + 1, entry: input.entry, isImport: false, attachments: statuses,
                                   findings: result.sensitiveFindings + attachmentFindings, responseCharacters: m.response.characters,
                                   requestOrigin: m.request.origin))
            case .imported(let id):
                guard let report = imports.first(where: { $0.id == id }) else {
                    return .failure(PackFailure(message: "A chosen import is no longer in Prompt Relay's history."))
                }
                let input = ContextPackComposer.Input(ref: ref, source: .imported(report), attachments: chosen,
                                                      materials: selectedMaterials, names: handoffNames(for: ref), missing: missing)
                inputs.append(input)
                let findings = SecretScanner.scan(report.task ?? "", section: "request") + SecretScanner.scan(report.text, section: "response")
                    + attachmentFindings
                let e = input.entry
                manifests.append(PackManifest.Result(
                    position: i + 1, resultId: Self.importResultID(id), kind: "user_import", provider: "imported",
                    profile: e.profile, profileRecorded: nil, host: report.host?.rawValue ?? "unknown",
                    project: report.projectName ?? "not specified", turn: nil, answeredAt: report.importedAt, status: nil,
                    completion: nil, link: nil,
                    request: .init(included: report.task != nil, provenance: report.task == nil ? "unavailable" : "supplied_by_user",
                                   origin: report.task == nil ? "unknown" : "user", characters: report.task.map(CharacterCount.of),
                                   earlierUserRequestTurn: nil),
                    response: .init(included: true, provenance: "reported_by_agent_pasted_by_user", characters: CharacterCount.of(report.text)),
                    observed: nil, attachments: statuses.map(\.manifest)))
                items.append(.init(ref: ref, position: i + 1, entry: e, isImport: true, attachments: statuses, findings: findings,
                                   responseCharacters: CharacterCount.of(report.text), requestOrigin: report.task == nil ? "unknown" : "user"))
            }
        }
        var text = ContextPackComposer.compose(inputs, exportedAt: builtAt, instructions: instructions, coreWarnings: coreWarnings)
        var warnings = coreWarnings
        if let mixed = ContextPackComposer.mixedProjectWarning(inputs.map(\.entry.project)) { warnings.insert(mixed, at: 0) }
        var manifest = PackManifest(preparedAt: builtAt, preparedBy: "Prompt Relay " + ((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "(development build)"),
                                    resultCount: refs.count, results: manifests,
                                    reviewInstructions: .init(suppliedByUser: instructions != nil, characters: instructions.map(CharacterCount.of) ?? 0),
                                    markdownCharacters: CharacterCount.of(text), destination: destination.rawValue, warnings: warnings,
                                    limits: ["Claims inside a response are the agent's own words and are not verified.",
                                             "Git state is read when the pack is prepared, not when the agent finished.",
                                             "Copying, dragging or exporting the pack does not mean another app received it.",
                                             "Window snapshots exist in memory only and are lost when Prompt Relay quits."])
        if packIncludesManifest {
            text += "\n## Manifest (machine-readable)\n[\(ReviewPack.confirmed)] Facts about this pack; no paths, session ids or text.\n\n```json\n"
                + manifest.json() + Self.manifestFenceEnd
            manifest.markdownCharacters = CharacterCount.of(text)
        }
        return .success(BuiltContextPack(id: UUID().uuidString.lowercased(), builtAt: builtAt, text: text, manifest: manifest,
                                         items: items, warnings: warnings, instructions: instructions, destination: destination,
                                         includesManifest: packIncludesManifest))
    }

    /// The same secret check as Copy with Context, on the text documents
    /// chosen for the pack (a file the user added is not checked anywhere
    /// else). Images and PDFs are not read; documents over 1 MB are skipped.
    func attachmentSecretFindings(_ chosen: [ReportAttachment], names: [String: String]) -> [SensitiveFinding] {
        chosen.filter { $0.effectiveKind == .document && !$0.isInMemory && $0.byteCount <= 1024 * 1024 }.flatMap { a -> [SensitiveFinding] in
            guard let data = attachmentData(a), let text = String(data: data, encoding: .utf8) else { return [] }
            return SecretScanner.scan(text, section: "attachment \(names[a.id] ?? a.originalFilename)")
        }
    }

    /// Files and drag of a pack with likely secrets wait for the same yes as its text.
    private func packNeedsYes(_ pack: BuiltContextPack) -> Bool {
        guard pack.findingCount > 0, !packSensitiveConfirmed else { return false }
        packAwaitsSensitiveConfirmation = true
        return true
    }

    static func importResultID(_ id: String) -> String {
        "r-" + String(ReportStore.sha256(Data("import#\(id)".utf8)).replacingOccurrences(of: "sha256:", with: "").prefix(16))
    }

    // MARK: Handing over

    /// Step 1: the pack's exact text on the clipboard (read back). Likely
    /// secrets wait for the user's yes, as with Copy with Context.
    public func copyContextPackText(confirmed: Bool = false) {
        guard let pack = contextPack.pack, !packIsStale else {
            packMessage = "The choice changed after the pack was prepared. Prepare it again."
            return
        }
        guard !pack.isTooLargeForClipboard else {
            packMessage = "This pack is \(pack.characters.formatted()) characters: too long to paste into a chat. Remove a result, or Export it to a folder."
            return
        }
        if pack.findingCount > 0 && !confirmed {
            packAwaitsSensitiveConfirmation = true
            return
        }
        packAwaitsSensitiveConfirmation = false
        if confirmed { packSensitiveConfirmed = true }
        do {
            let count = try clipboard.copy(pack.text)
            packProgress.textCopiedAt = ReportStore.now()
            packProgress.textChangeCount = count
            packMessage = nil
            finishCopy(.copied(.context, characters: pack.characters), token: Self.packTextToken)
            noteHandoff(pack, .copiedText)
        } catch {
            finishCopy(.failed(Self.message(for: error)))
        }
    }

    public func cancelSensitivePackCopy() { packAwaitsSensitiveConfirmation = false }

    /// The clipboard no longer holds the pack's text (another copy replaced it).
    public var packTextReplaced: Bool {
        _ = clipboardTick
        guard let count = packProgress.textChangeCount, packProgress.filesCopiedAt == nil else { return false }
        return clipboard.changeCount != count
    }

    /// The available attachments of the prepared pack, in pack order.
    func packAttachments(_ pack: BuiltContextPack) -> [ReportAttachment] {
        pack.items.flatMap { item -> [ReportAttachment] in
            let byID = Dictionary(uniqueKeysWithValues: attachments(for: item.ref).map { ($0.id, $0) })
            return item.attachments.filter { $0.availability != .missing }.compactMap { byID[$0.id] }
        }
    }

    private func packNames(_ pack: BuiltContextPack) -> [String: String] {
        pack.refs.reduce(into: [String: String]()) { names, ref in names.merge(handoffNames(for: ref)) { a, _ in a } }
    }

    /// Hand-off copies of the pack's files (its own folder; originals untouched).
    func packFiles(_ pack: BuiltContextPack) -> [URL] {
        guard let store = reportStore else { return [] }
        let files = packAttachments(pack).filter { !$0.isInMemory }
        guard !files.isEmpty else { return [] }
        do { return try store.handoffFiles(for: files, names: packNames(pack), folder: "handoff-pack") } catch {
            packMessage = "Prompt Relay could not prepare the files."
            return []
        }
    }

    /// In-memory snapshots as image data (no file is written for them); nil
    /// when one of them is gone since the pack was prepared.
    func packImages(_ pack: BuiltContextPack) -> [ClipboardImage]? {
        let memory = packAttachments(pack).filter(\.isInMemory)
        let images = memory.compactMap(memoryImage)
        return images.count == memory.count ? images : nil
    }

    /// Step 2: files (like ⌘C in Finder) and snapshots (image data) on the
    /// clipboard. It replaces the text, which was already pasted.
    public func copyContextPackFiles() {
        guard let pack = contextPack.pack, !packIsStale else {
            packMessage = "The choice changed after the pack was prepared. Prepare it again."
            return
        }
        guard !packNeedsYes(pack) else { return }
        guard let images = packImages(pack) else {
            packMessage = "A window snapshot is no longer in memory. Prepare the pack again."
            return
        }
        let files = packFiles(pack)
        guard !files.isEmpty || !images.isEmpty else { packMessage = "This pack has no files to hand over."; return }
        do {
            try clipboard.copyFiles(files, images: images)
            packProgress.filesCopiedAt = ReportStore.now()
            packMessage = nil
            finishCopy(.copied(.files, characters: files.count + images.count), token: Self.packFilesToken)
            noteHandoff(pack, .copiedFiles)
        } catch {
            finishCopy(.failed("The files could not be copied."))
        }
    }

    /// The pack's files and snapshots for one drag (snapshots as image data,
    /// no file). Called when the drag starts: that is what History records.
    public func contextPackDragPayloads() -> [DragPayload] {
        guard let pack = contextPack.pack, !packIsStale, !packNeedsYes(pack), let images = packImages(pack) else { return [] }
        let payloads = packFiles(pack).map(DragPayload.file) + images.map(DragPayload.image)
        if !payloads.isEmpty {
            packProgress.dragStartedAt = ReportStore.now()
            noteHandoff(pack, .dragStarted)
        }
        return payloads
    }

    /// The manifest alone, for tools that read JSON.
    public func copyContextPackManifest() {
        guard let pack = contextPack.pack else { return }
        do {
            try clipboard.copy(pack.manifest.json())
            finishCopy(.copied(.context, characters: 0), token: Self.packManifestToken)
        } catch { finishCopy(.failed(Self.message(for: error))) }
    }

    /// Export…: the pack, its manifest and its files (snapshots included,
    /// written only here, into the folder the user picks). Not with likely
    /// secrets (copy with the confirmation instead), as for Export Bundle.
    public func exportContextPack() {
        guard contextPack.pack != nil else { return }
        presentDialog(.exportFolder) { [weak self] urls in
            guard let self, let parent = urls?.first else { return }
            if let folder = self.writeContextPack(into: parent) { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
    }

    @discardableResult
    public func writeContextPack(into parent: URL) -> URL? {
        guard let pack = contextPack.pack, !packIsStale else {
            packMessage = "The choice changed after the pack was prepared. Prepare it again."
            return nil
        }
        guard pack.findingCount == 0 else {
            packMessage = "Not exported: the pack may contain secrets (\(pack.findingCount)). Review it in Preview; copying asks first."
            return nil
        }
        let chosen = packAttachments(pack)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "").prefix(15)
        let names = packNames(pack)
        do {
            let folder = try ExportBundle.write(into: parent, name: "Prompt Relay Context Pack \(stamp)", package: pack.text,
                                                files: chosen.map { a in (Self.renamed(a, names[a.id]), attachmentURL(a)) },
                                                memory: Dictionary(uniqueKeysWithValues: chosen.filter(\.isInMemory)
                                                    .compactMap { a in attachmentData(a).map { (a.id, $0) } }),
                                                packageName: "context-pack.md") { _ in nil }
            try Data(pack.manifest.json().utf8).write(to: folder.appendingPathComponent("manifest.json"))
            packProgress.exportedAt = ReportStore.now()
            packProgress.exportFolder = folder
            packMessage = nil
            finishCopy(.copied(.files, characters: pack.characters), token: Self.packExportToken)
            noteHandoff(pack, .exported)
            return folder
        } catch {
            packMessage = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    static func renamed(_ a: ReportAttachment, _ name: String?) -> ReportAttachment {
        guard let name else { return a }
        return ReportAttachment(id: a.id, reportKey: a.reportKey, originalFilename: name, storedFilename: a.storedFilename,
                                mimeType: a.mimeType, byteCount: a.byteCount, sha256: a.sha256, addedAt: a.addedAt,
                                provenance: a.provenance, kind: a.kind, source: a.source, sourceProvider: a.sourceProvider,
                                originalPath: a.originalPath, selected: a.selected, mockupID: a.mockupID, stateID: a.stateID,
                                inMemory: a.inMemory)
    }

    static let packTextToken = "pack|text"
    static let packFilesToken = "pack|files"
    static let packManifestToken = "pack|manifest"
    static let packExportToken = "pack|export"

    // MARK: Handoff History (app data dir, next to the reports)

    static let handoffHistoryLimit = 100

    static func handoffHistoryURL(_ store: ReportStore) -> URL { store.root.appendingPathComponent("handoff-history.json") }
    static func packDraftURL(_ store: ReportStore) -> URL { store.root.appendingPathComponent("context-pack-draft.json") }

    static func loadHandoffHistory(_ store: ReportStore) -> [HandoffRecord] {
        guard let data = try? Data(contentsOf: handoffHistoryURL(store)) else { return [] }
        return (try? JSONDecoder().decode([HandoffRecord].self, from: data)) ?? []
    }

    func saveHandoffHistory() {
        guard let reportStore else { return }
        let url = Self.handoffHistoryURL(reportStore)
        if handoffHistory.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: reportStore.root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(handoffHistory).write(to: url, options: [.atomic])
    }

    func recordHandoff(_ pack: BuiltContextPack) {
        let results = pack.items.map { item in
            HandoffRecord.Result(ref: item.ref, label: String("\(item.entry.provider) · \(item.entry.project) · \(packRow(item.ref).title)".prefix(90)))
        }
        let record = HandoffRecord(id: pack.id, preparedAt: pack.builtAt, destination: pack.destination, results: results,
                                   attachmentCount: pack.sendable.count, temporaryImages: pack.temporaryImages,
                                   characters: pack.characters, formatVersion: ContextPackFormat.version,
                                   steps: [.init(event: .prepared, at: pack.builtAt)])
        handoffHistory = Array(([record] + handoffHistory).prefix(Self.handoffHistoryLimit))
    }

    func noteHandoff(_ pack: BuiltContextPack, _ event: HandoffRecord.Event) {
        guard let i = handoffHistory.firstIndex(where: { $0.id == pack.id }) else { return }
        handoffHistory[i].steps.append(.init(event: event, at: ReportStore.now()))
    }

    /// Removes one record. The results themselves are never touched.
    public func deleteHandoffRecord(_ id: String) { handoffHistory.removeAll { $0.id == id } }

    public func clearHandoffHistory() { handoffHistory = [] }

    /// The results of a record that still exist (to prepare it again).
    public func availableResults(of record: HandoffRecord) -> [ReportRef] {
        record.results.map(\.ref).filter(isAvailable)
    }

    /// Prepare Again: the same results in the same order (those still in the
    /// history) and receiver. Instructions are not kept in the history.
    public func reprepare(_ record: HandoffRecord) {
        packRefs = Array(availableResults(of: record).prefix(ContextPackFormat.maxResults))
        packDestination = record.destination
        contextPack = .idle
        packProgress = PackProgress()
        packMessage = packRefs.count < record.results.count ? "Some results of that pack are no longer in the history; they were left out." : nil
        navigate(to: .contextPack)
    }

    // MARK: Draft (survives a restart; references and the user's words only)

    struct PackDraft: Codable {
        var refs: [ReportRef]
        var instructions: String
        var destination: HandoffDestination
        var includesManifest: Bool?
    }

    func loadPackDraft() {
        guard let store = reportStore, let data = try? Data(contentsOf: Self.packDraftURL(store)),
              let draft = try? JSONDecoder().decode(PackDraft.self, from: data) else { return }
        loadingPackDraft = true
        defer { loadingPackDraft = false }
        var seen = Set<ReportRef>()
        packRefs = Array(draft.refs.filter { seen.insert($0).inserted }.prefix(ContextPackFormat.maxResults))
        packInstructions = draft.instructions
        packDestination = draft.destination
        packIncludesManifest = draft.includesManifest ?? false
    }

    func savePackDraft() {
        guard !loadingPackDraft, let store = reportStore else { return }
        let url = Self.packDraftURL(store)
        if packRefs.isEmpty && packInstructions.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let draft = PackDraft(refs: packRefs, instructions: packInstructions, destination: packDestination, includesManifest: packIncludesManifest)
        try? JSONEncoder().encode(draft).write(to: url, options: [.atomic])
    }
}

extension AppModel.PackRow {
    func with(turn: Int) -> AppModel.PackRow {
        AppModel.PackRow(ref: ref, provider: provider, profile: profile, host: host, project: project,
                         title: title.isEmpty ? "Turn \(turn)" : title, answeredAt: answeredAt, characters: characters,
                         available: available, nativeSessionID: nativeSessionID)
    }
}
