import SwiftUI

/// The compact Evidence chip on the Answer card: what was observed and
/// what is open, in a few words; opens Evidence & Review.
struct EvidenceChip: View {
    let model: AppModel

    /// Phase 14.2: "6 observed · 1 test failed · 2 checks left" — Evidence
    /// Check's own facts, then the user's own checklist progress, kept
    /// visually together but never merged into one number: tapping the chip
    /// still opens the claims Evidence Check could not verify on their own,
    /// plus every checklist item, each with its own state.
    static func combinedSummary(_ model: AppModel) -> String? {
        guard let evidence = model.evidence else { return nil }
        let progress = model.reviewProgress?.summary
        return [evidence.summary.isEmpty ? nil : evidence.summary, progress?.isEmpty == false ? progress : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        if let evidence = model.evidence {
            let failed = evidence.items.contains { $0.kind == .observed && $0.alert }
            let text = Self.combinedSummary(model) ?? ""
            Button { model.navigate(to: .evidence) } label: {
                HStack(spacing: 4) {
                    Image(systemName: failed ? "exclamationmark.triangle.fill" : "checklist")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(failed ? Island.warning : Island.secondary)
                    Text(text.isEmpty ? "Evidence" : text)
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(Island.secondary)
                .padding(.horizontal, 6).frame(height: 18)
                .background(Capsule().fill(Island.cardRaised))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Evidence Check: \(text)")
            .islandHelp("Compare observed work with the answer, and your own checklist")
            .islandFrame("response.evidence")
        }
    }
}

/// One line in Attachments when materials are incomplete; details in
/// Evidence & Review.
struct CompletenessLine: View {
    let model: AppModel

    var body: some View {
        let lines = model.completeness.lines.filter(\.alert)
        if let first = lines.first {
            Button { model.navigate(to: .evidence) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up.trianglebadge.exclamationmark").font(.system(size: 9.5))
                        .foregroundStyle(Island.warning)
                    Text("\(first.title): \(first.text)" + (lines.count > 1 ? " · +\(lines.count - 1)" : ""))
                        .font(.system(size: 11)).foregroundStyle(Island.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Island.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .islandHelp("See which files and images are missing")
            .islandFrame("attachments.completeness")
        }
    }
}

/// Evidence & Review: Evidence Check (observed / reported / not verified /
/// unavailable), Artifact Completeness and the Review Checklist. All from
/// stored facts; the user's ticks are shown as the user's.
struct EvidenceView: View {
    let model: AppModel
    let presentation: NotchPresentation
    /// Phase 12: the three original sections, unchanged, behind Details.
    @State private var showsDetails = false

    var body: some View {
        BoundedScroll(maxHeight: presentation.listHeight(chrome: 8)) {
            VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) {
                if let evidence = model.evidence {
                    TrustCard(model: model, summary: TrustSummary.make(evidence: evidence, completeness: model.completeness,
                                                                       checklist: model.reviewChecklist))
                    DisclosureGroup(isExpanded: $showsDetails) {
                        VStack(alignment: .leading, spacing: IslandMetrics.of(presentation).spacing) { details(evidence) }
                            .padding(.top, 6)
                    } label: {
                        Text("Details").font(.system(size: 12, weight: .medium)).foregroundStyle(Island.secondary)
                            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading).contentShape(Rectangle())
                            .onTapGesture { showsDetails.toggle() }
                    }
                    .islandFrame("evidence.details")
                } else {
                    MessageCard(title: "No answer selected", detail: "Open an answer in Details first.", symbol: "checklist",
                                tint: Island.secondary, action: nil)
                }
            }
            .padding(.trailing, 4)
        }
        .islandPadding(presentation)
    }

    /// Evidence Check, Artifact Completeness and the Review Checklist as
    /// before Phase 12 (diagnostic detail; nothing removed).
    @ViewBuilder
    private func details(_ evidence: EvidenceCheck) -> some View {
                    section("Evidence Check", note: "Observed facts come from hook events on this Mac. What the answer says is listed as reported, never as proof.") {
                        ForEach(EvidenceCheck.Kind.allCases, id: \.self) { kind in
                            let items = evidence.items(kind)
                            if !items.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        Caption(kind.title, role: tint(kind))
                                        // Phase 14.2: its own count, kept apart from the
                                        // checklist's "N checks left" above.
                                        if kind == .notVerified {
                                            Text("\(items.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(Island.tertiary)
                                        }
                                    }
                                    ForEach(items) { item in
                                        Label {
                                            Text(item.text).font(.system(size: 11.5)).foregroundStyle(Island.primary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        } icon: {
                                            Image(systemName: symbol(kind, alert: item.alert)).font(.system(size: 10))
                                                .foregroundStyle(item.alert ? Island.error : tint(kind))
                                        }
                                    }
                                }
                                .islandFrame("evidence.\(kind.rawValue)")
                            }
                        }
                    }
                    let completeness = model.completeness
                    section("Artifact Completeness", note: "From the attachment list: what is stored, chosen and missing. A total is shown only when it is known.") {
                        if completeness.lines.isEmpty {
                            Text("No documents, mockups or links are attached to this answer.").font(.system(size: 11.5))
                                .foregroundStyle(Island.tertiary)
                        }
                        ForEach(completeness.lines) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Image(systemName: line.alert ? "exclamationmark.circle" : "checkmark.circle").font(.system(size: 10))
                                        .foregroundStyle(line.alert ? Island.warning : Island.success)
                                    Text(line.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Island.primary).lineLimit(1)
                                }
                                Text(line.text).font(.system(size: 11)).foregroundStyle(Island.secondary).fixedSize(horizontal: false, vertical: true)
                                if !line.missing.isEmpty {
                                    Text("Missing or name only: " + line.missing.joined(separator: ", "))
                                        .font(.system(size: 11)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .islandFrame("completeness.\(line.id)")
                        }
                    }
                    if let checklist = model.reviewChecklist {
                        section("Review Checklist", note: "For you to check yourself. BearlyCopy has not done these checks; a tick is your own.",
                               badge: model.reviewProgress?.summary) {
                            if checklist.items.isEmpty {
                                Text("Nothing specific to check from what was recorded.").font(.system(size: 11.5)).foregroundStyle(Island.tertiary)
                            }
                            ForEach(checklist.items) { item in
                                ChecklistRow(model: model, item: item)
                                    .islandFrame("checklist.\(item.id)")
                            }
                        }
                    }
    }

    private func section<C: View>(_ title: String, note: String, badge: String? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Caption(title, role: Island.accent)
                if let badge, !badge.isEmpty {
                    Text(badge).font(.system(size: 11, weight: .medium)).foregroundStyle(Island.tertiary)
                }
            }
            Text(note).font(.system(size: 11)).foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .islandCard()
    }

    private func tint(_ kind: EvidenceCheck.Kind) -> Color {
        switch kind {
        case .observed: return Island.success
        case .reported: return Island.review
        case .notVerified: return Island.warning
        case .unavailable: return Island.tertiary
        }
    }

    private func symbol(_ kind: EvidenceCheck.Kind, alert: Bool) -> String {
        if alert { return "xmark.octagon" }
        switch kind {
        case .observed: return "eye"
        case .reported: return "quote.bubble"
        case .notVerified: return "questionmark.circle"
        case .unavailable: return "minus.circle"
        }
    }
}

/// Phase 12: "What can be trusted?" — confirmed facts, the agent's claims and
/// what still needs a person, in that order. Ticks are the user's own.
/// Phase 14.2: one Review Checklist item — Pending / Checked by you / Not
/// applicable (the CI item only) — in Evidence & Review's own detail list.
struct ChecklistRow: View {
    let model: AppModel
    let item: ReviewChecklist.Item

    var body: some View {
        let state = model.reviewCheckState(item.id)
        HStack(alignment: .top, spacing: 7) {
            if item.allowsNotApplicable {
                Menu {
                    Button("Pending") { model.setReviewChecked(item.id, false); model.setReviewNotApplicable(item.id, false) }
                    Button("Checked by you") { model.setReviewChecked(item.id, true) }
                    Button("Not applicable") { model.setReviewNotApplicable(item.id, true) }
                } label: {
                    Image(systemName: symbol(state)).font(.system(size: 12)).foregroundStyle(tint(state))
                        .frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("\(label(state)): \(item.text)")
            } else {
                SelectBox(selected: state == .checked) { model.setReviewChecked(item.id, state != .checked) }
                    .accessibilityLabel("\(label(state)): \(item.text)")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text).font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(state == .pending ? Island.primary : Island.secondary)
                    .strikethrough(state != .pending, color: Island.tertiary)
                Text(state == .pending ? item.reason : "\(label(state)) · \(item.reason)").font(.system(size: 11))
                    .foregroundStyle(Island.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func label(_ s: AppModel.ReviewCheckState) -> String {
        switch s {
        case .pending: return "Pending"
        case .checked: return "Checked by you"
        case .notApplicable: return "Not applicable"
        }
    }

    private func symbol(_ s: AppModel.ReviewCheckState) -> String {
        switch s {
        case .pending: return "square"
        case .checked: return "checkmark.square.fill"
        case .notApplicable: return "minus.square"
        }
    }

    private func tint(_ s: AppModel.ReviewCheckState) -> Color {
        switch s {
        case .pending: return Island.tertiary
        case .checked: return Island.accent
        case .notApplicable: return Island.tertiary
        }
    }
}

struct TrustCard: View {
    let model: AppModel
    let summary: TrustSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("What can be trusted?", role: Island.accent)
            ForEach(TrustSummary.Group.allCases, id: \.self) { group in
                let rows = summary.rows(group)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: symbol(group)).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint(group))
                        Text(group.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(tint(group))
                        Text(note(group)).font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1)
                    }
                    if rows.isEmpty {
                        Text(empty(group)).font(.system(size: 11.5)).foregroundStyle(Island.tertiary).padding(.leading, 15)
                    }
                    ForEach(rows) { row in line(row) }
                }
                .islandFrame("trust.\(group.rawValue)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .islandCard()
    }

    private func line(_ row: TrustSummary.Row) -> some View {
        let state = row.checklistID.map(model.reviewCheckState) ?? .pending
        return HStack(alignment: .top, spacing: 6) {
            if let id = row.checklistID {
                if row.allowsNotApplicable {
                    Menu {
                        Button("Pending") { model.setReviewChecked(id, false); model.setReviewNotApplicable(id, false) }
                        Button("Checked by you") { model.setReviewChecked(id, true) }
                        Button("Not applicable") { model.setReviewNotApplicable(id, true) }
                    } label: {
                        Image(systemName: checklistSymbol(state)).font(.system(size: 12)).foregroundStyle(checklistTint(state))
                            .frame(width: 16, height: 16).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("\(checklistLabel(state)): \(row.text)")
                } else {
                    SelectBox(selected: state == .checked) { model.setReviewChecked(id, state != .checked) }
                        .accessibilityLabel("\(checklistLabel(state)): \(row.text)")
                }
            } else {
                Image(systemName: row.alert ? "xmark.octagon" : "circle.fill")
                    .font(.system(size: row.alert ? 10 : 4)).foregroundStyle(row.alert ? Island.error : Island.tertiary)
                    .frame(width: 10, height: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                let resolved = row.checklistID != nil && state != .pending
                Text(row.text).font(.system(size: 11.5)).foregroundStyle(resolved ? Island.secondary : Island.primary)
                    .strikethrough(resolved, color: Island.tertiary).fixedSize(horizontal: false, vertical: true)
                if let detail = row.detail {
                    Text(resolved ? "\(checklistLabel(state)) · \(detail)" : detail).font(.system(size: 11)).foregroundStyle(Island.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 4)
    }

    private func checklistLabel(_ s: AppModel.ReviewCheckState) -> String {
        switch s {
        case .pending: return "Pending"
        case .checked: return "Checked by you"
        case .notApplicable: return "Not applicable"
        }
    }

    private func checklistSymbol(_ s: AppModel.ReviewCheckState) -> String {
        switch s {
        case .pending: return "square"
        case .checked: return "checkmark.square.fill"
        case .notApplicable: return "minus.square"
        }
    }

    private func checklistTint(_ s: AppModel.ReviewCheckState) -> Color {
        switch s {
        case .pending: return Island.tertiary
        case .checked: return Island.accent
        case .notApplicable: return Island.tertiary
        }
    }

    private func tint(_ g: TrustSummary.Group) -> Color {
        switch g {
        case .confirmed: return Island.success
        case .reported: return Island.review
        case .needsVerification: return Island.warning
        }
    }

    private func symbol(_ g: TrustSummary.Group) -> String {
        switch g {
        case .confirmed: return "checkmark.seal"
        case .reported: return "quote.bubble"
        case .needsVerification: return "person.crop.circle.badge.questionmark"
        }
    }

    private func note(_ g: TrustSummary.Group) -> String {
        switch g {
        case .confirmed: return "seen on this Mac"
        case .reported: return "the answer's own words, not proof"
        case .needsVerification: return "for you to check"
        }
    }

    private func empty(_ g: TrustSummary.Group) -> String {
        switch g {
        case .confirmed: return "Nothing was observed for this answer."
        case .reported: return "No claims about tests, builds or completion found."
        case .needsVerification: return "Nothing specific to check from what was recorded."
        }
    }
}
