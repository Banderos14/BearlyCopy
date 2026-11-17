import AppKit
import SwiftUI

// Small building blocks shared by the island's views.

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

    public var color: Color {
        switch status {
        case .stopReceived: return .green
        case .stopReceivedBackgroundTasksPending, .awaitingResponse: return .orange
        case .apiError: return .red
        case .noMatchedResponse, .stopReceivedWithoutText, .unknown: return .gray
        }
    }
}

// MARK: - Verbatim text

/// Read-only, selectable NSTextView. It shows the exact characters, handles
/// megabyte answers without SwiftUI `Text` layout costs, and follows the
/// system appearance.
public struct VerbatimTextView: NSViewRepresentable {
    let text: String
    let textColor: NSColor
    let fontSize: CGFloat
    /// Scrolls so this UTF-16 offset is at the top; a new `token` repeats the jump.
    var jump: (offset: Int, token: Int)?

    public init(_ text: String, textColor: NSColor = .labelColor, fontSize: CGFloat = NSFont.systemFontSize,
                jump: (offset: Int, token: Int)? = nil) {
        self.text = text
        self.textColor = textColor
        self.fontSize = fontSize
        self.jump = jump
    }

    public final class Coordinator { var token: Int? }
    public func makeCoordinator() -> Coordinator { Coordinator() }

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
            view.font = .systemFont(ofSize: fontSize)
            view.textColor = textColor
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.isAutomaticSpellingCorrectionEnabled = false
            view.setAccessibilityLabel("Response text")
        }
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text {
            view.string = text
            view.scrollToBeginningOfDocument(nil)
        }
        guard let jump, jump.token != context.coordinator.token,
              let layout = view.layoutManager, let container = view.textContainer else { return }
        context.coordinator.token = jump.token
        let offset = min(max(0, jump.offset), (view.string as NSString).length)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: offset)
        let rect = layout.lineFragmentRect(forGlyphAt: min(glyph, max(0, layout.numberOfGlyphs - 1)), effectiveRange: nil)
        let y = max(0, min(rect.minY, view.frame.height - scroll.contentView.bounds.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
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
        return "BearlyCopy found text that looks like credentials. Review it before pasting it into another chat.\n\n"
            + lines.joined(separator: "\n") + more
    }
}

public extension View {
    func sensitiveContextAlert(_ model: AppModel) -> some View {
        modifier(SensitiveContextAlert(model: model))
    }
}
