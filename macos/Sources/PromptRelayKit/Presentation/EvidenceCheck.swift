import Foundation

/// Phase 7: what Prompt Relay saw on this Mac, kept apart from what the AI
/// said, plus how complete the materials are and what the developer should
/// still check. Deterministic rules over facts already stored (hook events,
/// attachment manifests, the answer's text); no AI, no new capture. A rule
/// that finds a claim in the answer never turns it into a fact: it is listed
/// as *Reported by AI* and *Not verified*.
public struct EvidenceCheck: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case observed, reported, notVerified, unavailable
        public var title: String {
            switch self {
            case .observed: return "Observed locally"
            case .reported: return "Reported by AI"
            case .notVerified: return "Not verified"
            case .unavailable: return "Unavailable"
            }
        }
    }

    public struct Item: Equatable, Sendable, Identifiable {
        public let kind: Kind
        public let text: String
        public var alert = false
        public var id: String { kind.rawValue + "|" + text }
    }

    public struct Input: Sendable {
        public var imported = false
        public var captureOn = true
        public var observed: ObservedCounts?
        public var detail: ObservedDetail?
        public var answer: String?
        public var backgroundAtStop = false
        public init() {}
    }

    public let items: [Item]
    /// Phase 14.2: failures classified by kind (command / test / build),
    /// from the same stored commands as the items above — never a second
    /// source of truth, never "N failed" collapsing a diagnostic shell call
    /// and a failed test suite into one indistinguishable number.
    public let failureBreakdown: FailureBreakdown

    public func items(_ kind: Kind) -> [Item] { items.filter { $0.kind == kind } }

    /// "12 observed · 1 test failed" for the compact chip. What still needs
    /// the user's own check (`ReviewChecklist`) is a separate count, shown
    /// next to this one in the chip, never merged into it; the claims this
    /// struct could not verify stay listed, with their own count, in
    /// Evidence & Review (`items(.notVerified)`).
    public var summary: String {
        let main = items(.observed).count
        return [main > 0 ? "\(main) observed" : nil, failureBreakdown.isEmpty ? nil : failureBreakdown.summary]
            .compactMap { $0 }.joined(separator: " · ")
    }

    public static func make(_ input: Input) -> EvidenceCheck {
        var items: [Item] = []
        let claims = Claims.find(in: input.answer ?? "")
        if input.imported {
            items.append(Item(kind: .unavailable, text: "Imported by you: nothing about this result was observed on this Mac"))
        } else if !input.captureOn {
            items.append(Item(kind: .unavailable, text: "Capture is off for this project: nothing was recorded"))
        } else if input.observed == nil {
            items.append(Item(kind: .unavailable, text: "Commands not recorded for this answer (needs the plugin's tool hooks, 0.3.0 or later)"))
        }
        let commands = (input.detail?.commands ?? []).filter { $0.agentType == nil }
        let failureBreakdown: FailureBreakdown
        if input.detail != nil {
            failureBreakdown = .make(commands)
        } else if let observed = input.observed, max(observed.commandsNonzero ?? 0, observed.runsNonzero) > 0 {
            failureBreakdown = .fromAggregate(max(observed.commandsNonzero ?? 0, observed.runsNonzero))
        } else {
            failureBreakdown = FailureBreakdown()
        }
        var testsOK = 0, buildsOK = 0
        if let observed = input.observed {
            let count = input.detail.map { _ in commands.count } ?? observed.toolEvents
            items.append(Item(kind: .observed, text: input.detail == nil ? "\(count) tool events observed" : "\(count) command\(count == 1 ? "" : "s") observed"))
            let failed = commands.filter { $0.outcome == "failed" || ($0.exitCode ?? 0) != 0 }
            if input.detail != nil {
                for code in Dictionary(grouping: failed, by: { $0.exitCode }).sorted(by: { ($0.key ?? -1) < ($1.key ?? -1) }) {
                    let n = code.value.count
                    items.append(Item(kind: .observed, text: "\(n) command\(n == 1 ? "" : "s") returned \(code.key.map { "exit \($0)" } ?? "an error")",
                                      alert: true))
                }
            } else if max(observed.commandsNonzero ?? 0, observed.runsNonzero) > 0 {
                let n = max(observed.commandsNonzero ?? 0, observed.runsNonzero)
                items.append(Item(kind: .observed, text: "\(n) command\(n == 1 ? "" : "s") returned a non-zero exit code", alert: true))
            }
            testsOK = commands.filter { $0.kind == "test" && $0.exitCode == 0 }.count
            buildsOK = commands.filter { $0.kind == "build" && $0.exitCode == 0 }.count
            if testsOK > 0 { items.append(Item(kind: .observed, text: "\(testsOK) test command\(testsOK == 1 ? "" : "s") exited 0")) }
            if buildsOK > 0 { items.append(Item(kind: .observed, text: "\(buildsOK) build command\(buildsOK == 1 ? "" : "s") exited 0")) }
            if observed.filesChanged > 0 {
                items.append(Item(kind: .observed, text: "\(observed.filesChanged) file\(observed.filesChanged == 1 ? "" : "s") changed with Edit/Write"))
            }
            if commands.contains(where: \.background) || observed.backgroundStarted > 0 {
                items.append(Item(kind: .observed, text: "Background commands started; their results were not observed"))
            }
        }
        if input.backgroundAtStop {
            items.append(Item(kind: .observed, text: "Background work was still running when Claude stopped"))
        }
        // What the answer says, never promoted to a fact.
        if claims.tests {
            items.append(Item(kind: .reported, text: "The answer says tests pass"))
            items.append(Item(kind: .notVerified, text: testsOK > 0
                ? "Claimed test success: a test command exited 0, which does not show every test or the whole task"
                : "Claimed test success: no passing test command was observed"))
        }
        if claims.build {
            items.append(Item(kind: .reported, text: "The answer says the build succeeds"))
            items.append(Item(kind: .notVerified, text: buildsOK > 0
                ? "Claimed build success: a build command exited 0 (one run, one configuration)"
                : "Claimed build success: no successful build command was observed"))
        }
        if claims.done { items.append(Item(kind: .reported, text: "The answer says the work is done or working")) }
        if claims.visual {
            items.append(Item(kind: .notVerified, text: "Visual review required: the answer is about the interface"))
        }
        // Phase 14.2: the answer says the task is done, but neither a
        // passing test nor a successful build was observed to back it up —
        // named explicitly so it is never read as a confirmed success.
        if claims.done, !claims.tests, !claims.build, testsOK == 0, buildsOK == 0 {
            items.append(Item(kind: .notVerified, text: "Task outcome unknown: the answer says it is done, but no test or build command confirms it"))
        }
        items.append(Item(kind: .unavailable, text: "CI not connected"))
        items.append(Item(kind: .notVerified, text: "Stop means Claude stopped answering, not that the task succeeded"))
        return EvidenceCheck(items: items, failureBreakdown: failureBreakdown)
    }

    /// Phrases in the answer, matched literally (English and Russian). Only
    /// used to say "the answer claims X"; the claim itself is not judged.
    public struct Claims: Equatable, Sendable {
        public var tests = false, build = false, done = false, visual = false

        public static func find(in text: String) -> Claims {
            let t = text.lowercased()
            // Short words match whole words only ("ui" is not in "build").
            func any(_ words: [String]) -> Bool {
                words.contains { w in
                    w.count <= 3 ? t.range(of: "\\b\(w)\\b", options: .regularExpression) != nil : t.contains(w)
                }
            }
            return Claims(
                tests: any(["tests pass", "tests passed", "all tests", "test suite passes", "tests are green", "0 failures",
                            "тесты прош", "тесты пройден", "все тесты", "тесты зелён", "тесты зелен"]),
                build: any(["build succeeded", "builds successfully", "build passes", "build is green", "compiles successfully",
                            "сборка прош", "сборка успешн", "собирается без", "build succeeded"]),
                done: any(["everything works", "it works", "is working", "all done", "fully implemented", "is complete",
                           "всё работает", "все работает", "работает корректно", "готово", "реализовано полностью"]),
                visual: any(["ui", "interface", "layout", "animation", "screen", "button", "интерфейс", "анимац", "экран", "кнопк", "вёрстк"])
                    && any(["view", "swiftui", "css", "html", "window", "panel", "island", "интерфейс", "экран"]))
        }
    }
}

/// How complete the materials of an answer are, from the attachment
/// manifests only. Never counts a total that is not known; a private
/// claude.ai link is never taken as having the content.
public struct ArtifactCompleteness: Equatable, Sendable {
    public struct Line: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let text: String
        public var alert = false
        /// Named states or materials without an image or content.
        public var missing: [String] = []
    }

    public let lines: [Line]
    public var missingCount: Int { lines.reduce(0) { $0 + $1.missing.count } }

    /// - Parameters:
    ///   - unreadable: attachments whose stored file cannot be opened.
    ///   - published: pages the AI published during the turn (observed).
    public static func make(attachments: [ReportAttachment], unreadable: Set<String>, materials: [ReportMaterial],
                            published: [ObservedArtifact] = []) -> ArtifactCompleteness {
        var lines: [Line] = []
        let files = attachments.filter { $0.mockupID == nil }
        if !files.isEmpty {
            let chosen = files.filter(\.isSelected).count
            let broken = files.filter { unreadable.contains($0.id) }
            var parts = ["\(files.count) attached", "\(chosen) chosen to send"]
            if !broken.isEmpty { parts.append("\(broken.count) cannot be opened") }
            lines.append(Line(id: "files", title: "Files", text: parts.joined(separator: " · "), alert: !broken.isEmpty,
                              missing: broken.map(\.originalFilename)))
        }
        for m in materials where m.kind == .mockup {
            let declared = m.states.count
            let captured = m.states.filter { $0.status == .captured && $0.attachmentID.map { !unreadable.contains($0) } ?? false }
            let named = m.states.filter { $0.status == .namedOnly }
            let failed = m.states.filter { $0.status == .failed }
            let chosen = captured.filter(\.selected).count
            var parts: [String] = []
            if declared == 0 {
                parts.append("number of states unknown")
            } else {
                parts.append("\(captured.count)/\(declared) states captured")
                let missing = declared - captured.count
                if missing > 0 { parts.append("\(missing) missing") }
            }
            if chosen != captured.count { parts.append("\(chosen) chosen to send") }
            if !failed.isEmpty { parts.append("\(failed.count) could not be opened") }
            parts.append("Live review required")
            lines.append(Line(id: m.id, title: "Mockup “\(m.title)”", text: parts.joined(separator: " · "),
                              alert: declared == 0 || captured.count < declared,
                              missing: (named + failed).map(\.title) + m.states.filter { $0.status == .captured && !captured.contains($0) }.map(\.title)))
        }
        for m in materials where m.kind == .link {
            lines.append(Line(id: m.id, title: "Link “\(m.title)”",
                              text: m.isPrivateLink ? "link only: a private claude.ai page, its content was not received" : "link only: the page itself is not attached",
                              alert: m.isPrivateLink, missing: [m.title]))
        }
        // Pages the AI published that have no material here: known by name only.
        let known = Set(materials.compactMap(\.url))
        let unmatched = published.filter { $0.url.map { !known.contains($0) } ?? true }
        if !unmatched.isEmpty {
            let names = unmatched.map { $0.title ?? $0.path ?? "untitled page" }
            lines.append(Line(id: "published", title: "Published by the AI",
                              text: "\(unmatched.count) page\(unmatched.count == 1 ? "" : "s") known by name only, not captured",
                              alert: true, missing: names))
        }
        return ArtifactCompleteness(lines: lines)
    }
}

/// A few things the developer should check personally, from fixed rules.
/// Prompt Relay never ticks them; the user does, and that is shown as the
/// user's own check, apart from observed facts.
public struct ReviewChecklist: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public let id: String
        public let text: String
        public let reason: String
        /// Phase 14.2: only the CI item — Prompt Relay has no CI integration
        /// to actually run, so ticking it should never be the only way to
        /// say "checked"; "Not applicable" says plainly that there is
        /// nothing here to check, without counting as a verified CI pass.
        public var allowsNotApplicable = false
    }

    public static let limit = 6
    public let items: [Item]

    public static func make(evidence: EvidenceCheck, completeness: ArtifactCompleteness, changedPaths: [String],
                            answer: String?, handoffFiles: Int, imported: Bool, isLatest: Bool) -> ReviewChecklist {
        var items: [Item] = []
        let claims = EvidenceCheck.Claims.find(in: answer ?? "")
        let uiExtensions = ["swift", "tsx", "jsx", "vue", "svelte", "css", "scss", "html", "xib", "storyboard"]
        let uiFiles = changedPaths.filter { uiExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        if !uiFiles.isEmpty || claims.visual || completeness.lines.contains(where: { $0.title.hasPrefix("Mockup") }) {
            items.append(Item(id: "ui", text: "Check the interface on a real screen",
                              reason: uiFiles.isEmpty ? "The answer or a mockup is about the interface" : "\(uiFiles.count) interface file(s) changed"))
        }
        let t = (answer ?? "").lowercased()
        if ["animation", "motion", "transition", "анимац", "переход"].contains(where: t.contains) {
            items.append(Item(id: "motion", text: "Check that the animation looks and feels right",
                              reason: "The answer mentions animation; a still image cannot show it"))
        }
        if completeness.missingCount > 0 {
            items.append(Item(id: "missing", text: "Review the missing materials (\(completeness.missingCount))",
                              reason: "Some states or pages are known by name only or could not be opened"))
        }
        let failed = evidence.items.contains { $0.kind == .observed && $0.alert }
        if failed || claims.build || claims.tests {
            items.append(Item(id: "build", text: "Run the build and tests yourself",
                              reason: failed ? "A command failed during the turn" : "Success is claimed but not independently verified"))
        }
        if claims.tests || claims.build || evidence.items.contains(where: { $0.text.contains("test command") || $0.text.contains("build command") }) {
            items.append(Item(id: "ci", text: "Check CI, if the project has it",
                              reason: "Prompt Relay is not connected to any CI; it cannot see CI results. If this project has no CI, mark Not applicable.",
                              allowsNotApplicable: true))
        }
        if handoffFiles > 0 {
            items.append(Item(id: "paste", text: "Check that the files arrive in the receiving assistant",
                              reason: "\(handoffFiles) file(s) chosen; pasting files depends on the other app"))
        }
        if !isLatest || imported {
            items.append(Item(id: "choice", text: "Make sure this is the right answer and the right files",
                              reason: imported ? "An imported result" : "This is not the newest answer of the session"))
        }
        return ReviewChecklist(items: Array(items.prefix(limit)))
    }
}

extension AppModel {
    /// Evidence Check for the answer shown.
    public var evidence: EvidenceCheck? {
        if let report = selectedImport {
            var input = EvidenceCheck.Input()
            input.imported = true
            input.answer = report.text
            return .make(input)
        }
        guard let turn = selectedTurn else { return nil }
        var input = EvidenceCheck.Input()
        input.captureOn = selectedProject?.captureEnabled ?? true
        input.observed = turn.observed
        input.detail = selectedObservedDetail ?? turn.observedDetail
        input.answer = selectedResponseText ?? turn.finalResponse?.preview
        input.backgroundAtStop = turn.status == .stopReceivedBackgroundTasksPending
        return .make(input)
    }

    /// `observed_detail` from `show`, once loaded for this turn.
    var selectedObservedDetail: ObservedDetail? {
        guard let show = detail.value, show.turn.index == selectedTurnIndex, show.session.sessionKey == selectedSessionKey else { return nil }
        return show.turn.observedDetail
    }

    /// Artifact Completeness for the answer shown.
    public var completeness: ArtifactCompleteness {
        let ref = currentRef
        let files = attachments(for: ref)
        let unreadable = Set(files.filter { a in
            a.isInMemory ? !isAttachmentAvailable(a)
                : attachmentURL(a).map { !FileManager.default.isReadableFile(atPath: $0.path) } ?? true
        }.map(\.id))
        return .make(attachments: files, unreadable: unreadable, materials: materials(for: ref),
                     published: selectedImport == nil ? (selectedObservedDetail ?? selectedTurn?.observedDetail)?.artifacts ?? [] : [])
    }

    public var reviewChecklist: ReviewChecklist? {
        guard let evidence else { return nil }
        let changed = (selectedObservedDetail ?? selectedTurn?.observedDetail)?.filesChanged.map(\.path) ?? []
        let newest = Self.newestAnswerIndex(turnsNewestFirst)
        return .make(evidence: evidence, completeness: completeness, changedPaths: changed,
                     answer: selectedImport?.text ?? selectedResponseText ?? selectedTurn?.finalResponse?.preview,
                     handoffFiles: handoffAttachments(for: currentRef).count, imported: selectedImport != nil,
                     isLatest: selectedImport != nil || newest == nil || newest == selectedTurnIndex)
    }

    nonisolated static func newestAnswerIndex(_ newestFirst: [Turn]) -> Int? {
        newestFirst.first { $0.finalResponse != nil }?.index
    }

    // MARK: The user's own check marks

    static let reviewChecksKey = "reviewChecks.v1"

    /// Items the user ticked for the answer shown (never ticked by Prompt Relay).
    public func isReviewChecked(_ item: String) -> Bool {
        guard let key = currentRef?.key else { return false }
        return reviewChecks[key]?.contains(item) ?? false
    }

    public func setReviewChecked(_ item: String, _ checked: Bool) {
        guard let key = currentRef?.key else { return }
        noteReviewMarked(key)
        var set = reviewChecks[key] ?? []
        if checked { set.insert(item) } else { set.remove(item) }
        var all = reviewChecks
        all[key] = set.isEmpty ? nil : set
        reviewChecks = all
        // Mutually exclusive with Not applicable (only meaningful on the CI item).
        if checked, isReviewNotApplicable(item) { setReviewNotApplicable(item, false) }
    }

    // MARK: Phase 14.2 — Not applicable (the CI item only)

    static let reviewNotApplicableKey = "reviewChecks.notApplicable.v1"

    /// Marked "Not applicable" for the answer shown — a third state, never
    /// read as a passed CI check: `isReviewChecked` stays false for it.
    public func isReviewNotApplicable(_ item: String) -> Bool {
        guard let key = currentRef?.key else { return false }
        return reviewNotApplicable[key]?.contains(item) ?? false
    }

    public func setReviewNotApplicable(_ item: String, _ value: Bool) {
        guard let key = currentRef?.key else { return }
        noteReviewMarked(key)
        var set = reviewNotApplicable[key] ?? []
        if value { set.insert(item) } else { set.remove(item) }
        var all = reviewNotApplicable
        all[key] = set.isEmpty ? nil : set
        reviewNotApplicable = all
        if value, isReviewChecked(item) { setReviewChecked(item, false) }
    }

    /// Pending / Checked by you / Not applicable, for one checklist item of
    /// the answer shown — the vocabulary of the user's own progress, kept
    /// apart from what Evidence Check could or could not confirm.
    public enum ReviewCheckState: Equatable, Sendable { case pending, checked, notApplicable }

    public func reviewCheckState(_ item: String) -> ReviewCheckState {
        if isReviewNotApplicable(item) { return .notApplicable }
        if isReviewChecked(item) { return .checked }
        return .pending
    }

    var reviewChecks: [String: Set<String>] {
        get {
            _ = reviewChecksVersion
            return (stateDefaults?.dictionary(forKey: Self.reviewChecksKey) as? [String: [String]])?.mapValues(Set.init) ?? [:]
        }
        set {
            // Only the most recently marked answers keep their marks.
            stateDefaults?.set(Self.storable(Self.keepingMostRecent(newValue, order: reviewRecentKeys)), forKey: Self.reviewChecksKey)
            reviewChecksVersion += 1
        }
    }

    var reviewNotApplicable: [String: Set<String>] {
        get {
            _ = reviewChecksVersion
            return (stateDefaults?.dictionary(forKey: Self.reviewNotApplicableKey) as? [String: [String]])?.mapValues(Set.init) ?? [:]
        }
        set {
            stateDefaults?.set(Self.storable(Self.keepingMostRecent(newValue, order: reviewRecentKeys)), forKey: Self.reviewNotApplicableKey)
            reviewChecksVersion += 1
        }
    }

    // MARK: Phase 15 — which answers were marked most recently

    /// Phase 15: the old pruning, `newValue.prefix(200)` on a `Dictionary`,
    /// kept an arbitrary 200 (Swift's per-process hash order), not the 200
    /// most recent — past 200 marked answers a tick could vanish the moment
    /// it was made. This list records the order answers were last marked
    /// in (oldest first), so pruning keeps the newest ones.
    static let reviewRecentKey = "reviewChecks.recent.v1"
    nonisolated static let reviewChecksLimit = 200

    var reviewRecentKeys: [String] { stateDefaults?.stringArray(forKey: Self.reviewRecentKey) ?? [] }

    /// Moves `key` to the newest end. Called before either dictionary is written.
    func noteReviewMarked(_ key: String) {
        var order = reviewRecentKeys.filter { $0 != key }
        order.append(key)
        // Both dictionaries share this order, so it may name up to twice the limit.
        if order.count > Self.reviewChecksLimit * 2 { order.removeFirst(order.count - Self.reviewChecksLimit * 2) }
        stateDefaults?.set(order, forKey: Self.reviewRecentKey)
    }

    /// The `limit` entries marked most recently according to `order`
    /// (oldest first). Entries `order` does not name (stored before Phase
    /// 15) count as older than every named one; among themselves they are
    /// ranked by key, so the result never depends on hash order.
    nonisolated static func keepingMostRecent(_ all: [String: Set<String>], order: [String],
                                              limit: Int = reviewChecksLimit) -> [String: Set<String>] {
        guard all.count > limit else { return all }
        var rank: [String: Int] = [:]
        for (i, key) in order.enumerated() { rank[key] = i }
        let kept = Set(all.keys.sorted { (rank[$0] ?? -1, $0) > (rank[$1] ?? -1, $1) }.prefix(limit))
        return all.filter { kept.contains($0.key) }
    }

    nonisolated static func storable(_ all: [String: Set<String>]) -> [String: [String]] {
        all.mapValues { $0.sorted() }
    }

    /// Phase 14.2: the user's own progress on the checklist of the answer
    /// shown — separate from Evidence Check's unverified-claim count, and
    /// updated the instant a box is ticked (no reopen, no restart needed).
    public var reviewProgress: ReviewProgress? {
        guard let checklist = reviewChecklist, !checklist.items.isEmpty else { return nil }
        let resolved = checklist.items.filter { reviewCheckState($0.id) != .pending }.count
        return ReviewProgress(total: checklist.items.count, resolvedCount: resolved)
    }
}

/// Phase 14.2: "2 of 4 checks remaining" for the answer shown — the user's
/// own progress on `ReviewChecklist`, never the count of claims Evidence
/// Check could not independently verify (`EvidenceCheck.items(.notVerified)`,
/// a different, unrelated number that stays in Evidence & Review).
public struct ReviewProgress: Equatable, Sendable {
    public let total: Int
    /// Checked by you, or marked Not applicable — either way, not pending.
    public let resolvedCount: Int
    public var remaining: Int { max(0, total - resolvedCount) }
    public var isComplete: Bool { total > 0 && remaining == 0 }

    /// "" when there is nothing to check; else "N checks left" / "All checks completed".
    public var summary: String {
        guard total > 0 else { return "" }
        return isComplete ? "All checks completed" : "\(remaining) check\(remaining == 1 ? "" : "s") left"
    }
}

/// Phase 12: one answer to "What can be trusted?", built only from
/// Evidence Check, Artifact Completeness and the Review Checklist above —
/// nothing new is inferred, nothing is dropped (the full sections stay in
/// Details), and Copy with Context is not affected.
/// - Confirmed locally: facts read on this Mac (commands, exit codes, files,
///   stored attachments).
/// - Reported by the agent: what the answer says, never a fact.
/// - Needs verification: claims without matching evidence, missing
///   materials, and the checklist (ticks are the user's own).
public struct TrustSummary: Equatable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case confirmed, reported, needsVerification
        public var title: String {
            switch self {
            case .confirmed: return "Confirmed locally"
            case .reported: return "Reported by the agent"
            case .needsVerification: return "Needs verification"
            }
        }
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let group: Group
        public let text: String
        public var detail: String? = nil
        /// A failed command or missing material.
        public var alert = false
        /// A Review Checklist item the user can tick.
        public var checklistID: String? = nil
        /// Phase 14.2: only the CI item offers Not applicable as well.
        public var allowsNotApplicable = false
        public var id: String { group.rawValue + "|" + (checklistID ?? text) }
    }

    public let rows: [Row]
    public func rows(_ group: Group) -> [Row] { rows.filter { $0.group == group } }

    public static func make(evidence: EvidenceCheck?, completeness: ArtifactCompleteness, checklist: ReviewChecklist?) -> TrustSummary {
        var rows: [Row] = []
        for item in evidence?.items ?? [] {
            switch item.kind {
            case .observed: rows.append(Row(group: .confirmed, text: item.text, alert: item.alert))
            case .reported: rows.append(Row(group: .reported, text: item.text))
            case .notVerified: rows.append(Row(group: .needsVerification, text: item.text))
            case .unavailable: break   // Details only: what could not be observed
            }
        }
        for line in completeness.lines {
            if line.alert {
                rows.append(Row(group: .needsVerification, text: "\(line.title): \(line.text)",
                                detail: line.missing.isEmpty ? nil : "Missing or name only: " + line.missing.joined(separator: ", "),
                                alert: true))
            } else {
                rows.append(Row(group: .confirmed, text: "\(line.title): \(line.text)"))
            }
        }
        for item in checklist?.items ?? [] {
            rows.append(Row(group: .needsVerification, text: item.text, detail: item.reason, checklistID: item.id,
                            allowsNotApplicable: item.allowsNotApplicable))
        }
        return TrustSummary(rows: rows)
    }
}
