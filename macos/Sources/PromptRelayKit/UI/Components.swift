import AppKit
import SwiftUI

// Reusable building blocks. Every surface (menu-bar panel, main window,
// later the notch) composes these; none of them owns state beyond hover.

// MARK: - Status

public struct StatusBadge: View {
    let status: TurnStatus

    public init(_ status: TurnStatus) { self.status = status }

    public var body: some View {
        Label {
            Text(Wording.status(status))
        } icon: {
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    var color: Color {
        switch status {
        case .stopReceived: return .green
        case .stopReceivedBackgroundTasksPending, .awaitingResponse: return .orange
        case .apiError: return .red
        case .noMatchedResponse, .stopReceivedWithoutText, .unknown: return .gray
        }
    }
}

// MARK: - Turn row

public struct TurnRow: View {
    let turn: Turn
    let onCopy: (() -> Void)?
    @State private var hovering = false

    public init(turn: Turn, onCopy: (() -> Void)? = nil) {
        self.turn = turn
        self.onCopy = onCopy
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("#\(turn.index)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    StatusBadge(turn.status)
                    Spacer(minLength: 4)
                    Text(Wording.relative(turn.finalResponse?.receivedAt ?? turn.request?.receivedAt))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                if let request = turn.request {
                    Text(oneLine(request.preview))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                } else if let note = Wording.link(turn.link) {
                    Text(note).font(.callout).italic().foregroundStyle(.secondary).lineLimit(1)
                }
                if let response = turn.finalResponse, response.charCount > 0 {
                    Text(oneLine(response.preview)).font(.callout).lineLimit(2)
                } else if let message = turn.error?.message {
                    Text(message).font(.callout).foregroundStyle(.red).lineLimit(2)
                }
            }
            if let onCopy, AppModel.copyBlocker(for: turn) == nil {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy Response")
                .accessibilityLabel("Copy response of turn \(turn.index)")
                .opacity(hovering ? 1 : 0.45)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Previews are shown on one line; the copied text is never derived from them.
    private func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - Verbatim text

/// Read-only, selectable NSTextView. It shows the exact characters, handles
/// megabyte answers without SwiftUI `Text` layout costs, and follows the
/// system appearance.
public struct VerbatimTextView: NSViewRepresentable {
    let text: String

    public init(_ text: String) { self.text = text }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 4, height: 6)
            view.font = .systemFont(ofSize: NSFont.systemFontSize)
            view.textColor = .labelColor
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.isAutomaticSpellingCorrectionEnabled = false
            view.setAccessibilityLabel("Response text")
        }
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.scrollToBeginningOfDocument(nil)
    }
}

// MARK: - Copy bar

public struct CopyBar: View {
    let model: AppModel
    var compact: Bool

    public init(model: AppModel, compact: Bool = false) {
        self.model = model
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.copySelectedResponse() }
            } label: {
                Label("Copy Response", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!canCopyResponse)
            .help(responseHelp)

            Button {
                Task { await model.copySelectedContext() }
            } label: {
                Label(compact ? "Context" : "Copy Context", systemImage: "text.badge.checkmark")
            }
            .disabled(model.selectedTurn == nil || isWorking)
            .help("Copy a Markdown packet: request, response, provenance labels and git state")

            Spacer(minLength: 4)
            CopyFeedbackLabel(feedback: model.copyFeedback)
        }
        .controlSize(compact ? .regular : .large)
    }

    private var isWorking: Bool {
        if case .working = model.copyFeedback { return true }
        return false
    }

    private var canCopyResponse: Bool {
        guard let turn = model.selectedTurn, !isWorking else { return false }
        return AppModel.copyBlocker(for: turn) == nil
    }

    private var responseHelp: String {
        guard let turn = model.selectedTurn else { return "Select an answer first" }
        return AppModel.copyBlocker(for: turn) ?? "Copy the final answer exactly as Claude wrote it (⇧⌘C)"
    }
}

public struct CopyFeedbackLabel: View {
    let feedback: AppModel.CopyFeedback

    public init(feedback: AppModel.CopyFeedback) { self.feedback = feedback }

    public var body: some View {
        Group {
            switch feedback {
            case .idle:
                EmptyView()
            case .working:
                ProgressView().controlSize(.small)
            case .copied(let kind, let characters):
                Label("\(kind.rawValue) copied", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .help("\(characters.formatted()) characters on the clipboard")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .font(.callout)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.15), value: feedback)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Empty and error states

public struct EmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    public init(_ title: String, message: String, systemImage: String) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
    }
}

public struct CoreErrorView: View {
    let error: CoreError
    let retry: () -> Void

    public init(_ error: CoreError, retry: @escaping () -> Void) {
        self.error = error
        self.retry = retry
    }

    public var body: some View {
        ContentUnavailableView {
            Label(error.title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.detail).textSelection(.enabled)
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}

// MARK: - Sensitive context confirmation

public struct SensitiveContextAlert: ViewModifier {
    @Bindable var model: AppModel

    public func body(content: Content) -> some View {
        content.alert(
            "Possible secrets in the context",
            isPresented: Binding(
                get: { model.pendingSensitiveContext != nil },
                set: { if !$0 { model.cancelSensitiveContextCopy() } }
            ),
            presenting: model.pendingSensitiveContext
        ) { _ in
            Button("Copy Anyway", role: .destructive) { model.confirmSensitiveContextCopy() }
            Button("Cancel", role: .cancel) { model.cancelSensitiveContextCopy() }
        } message: { context in
            Text(Self.summary(context.sensitiveFindings))
        }
    }

    static func summary(_ findings: [SensitiveFinding]) -> String {
        let lines = findings.prefix(6).map { "• \($0.kind) — \($0.section), line \($0.line)" }
        let more = findings.count > 6 ? "\n• …and \(findings.count - 6) more" : ""
        return "Prompt Relay found text that looks like credentials. Review it before pasting it into another chat.\n\n"
            + lines.joined(separator: "\n") + more
    }
}

public extension View {
    func sensitiveContextAlert(_ model: AppModel) -> some View {
        modifier(SensitiveContextAlert(model: model))
    }
}
