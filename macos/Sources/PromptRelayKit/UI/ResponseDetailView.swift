import SwiftUI

/// The selected turn: header facts, warnings, the full verbatim answer and
/// the copy actions. Used by the window; the menu panel uses a shorter form.
public struct ResponseDetailView: View {
    let model: AppModel
    var compact: Bool

    public init(model: AppModel, compact: Bool = false) {
        self.model = model
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let turn = model.selectedTurn {
                header(turn)
                notes(turn)
                content(turn)
                CopyBar(model: model, compact: compact)
            } else if model.turns.value?.isEmpty == false {
                EmptyState("Select an answer", message: "Choose a turn to see Claude's full final response.",
                           systemImage: "text.cursor")
            } else {
                EmptyState("No answer selected", message: "Pick a session to see its answers.",
                           systemImage: "text.bubble")
            }
        }
    }

    @ViewBuilder
    private func header(_ turn: Turn) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Turn \(turn.index)").font(compact ? .headline : .title3.weight(.semibold))
            StatusBadge(turn.status)
            Spacer()
            if let response = turn.finalResponse {
                Text(Wording.absolute(response.receivedAt) + " · " + Wording.size(response))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if !compact, let request = turn.request {
            Text(request.preview)
                .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func notes(_ turn: Turn) -> some View {
        let linkNote = Wording.link(turn.link)
        let warnings = model.selectedResponseText != nil ? model.detailWarnings : []
        if linkNote != nil || !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let linkNote {
                    Label(linkNote, systemImage: "link.badge.plus").foregroundStyle(.secondary)
                }
                ForEach(warnings, id: \.self) { warning in
                    Label(warning.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func content(_ turn: Turn) -> some View {
        if let blocker = AppModel.copyBlocker(for: turn) {
            EmptyState("Nothing to copy", message: turn.error?.message.map { "\(blocker)\n\($0)" } ?? blocker,
                       systemImage: turn.status == .apiError ? "exclamationmark.octagon" : "hourglass")
                .frame(maxHeight: .infinity)
        } else if let text = model.selectedResponseText {
            VerbatimTextView(text)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .frame(minHeight: compact ? 140 : 220, maxHeight: .infinity)
        } else if let error = model.detail.error {
            CoreErrorView(error) { model.refresh() }.frame(maxHeight: .infinity)
        } else {
            ProgressView("Loading the full answer…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
