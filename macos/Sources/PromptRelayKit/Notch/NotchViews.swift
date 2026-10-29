import SwiftUI

/// The island outline: straight top edge along the screen, concave flares
/// where it meets the menu bar, rounded bottom corners like the camera
/// housing. Both radii animate, so the shape morphs from the notch.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topRadius) }
        set { bottomRadius = newValue.first; topRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let rt = min(topRadius, w / 4), rb = min(bottomRadius, (w - 2 * rt) / 2, h / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + rt, y: rect.minY + rt), control: CGPoint(x: rect.minX + rt, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + rt, y: rect.minY + h - rb))
        p.addQuadCurve(to: CGPoint(x: rect.minX + rt + rb, y: rect.minY + h), control: CGPoint(x: rect.minX + rt, y: rect.minY + h))
        p.addLine(to: CGPoint(x: rect.minX + w - rt - rb, y: rect.minY + h))
        p.addQuadCurve(to: CGPoint(x: rect.minX + w - rt, y: rect.minY + h - rb), control: CGPoint(x: rect.minX + w - rt, y: rect.minY + h))
        p.addLine(to: CGPoint(x: rect.minX + w - rt, y: rect.minY + rt))
        p.addQuadCurve(to: CGPoint(x: rect.minX + w, y: rect.minY), control: CGPoint(x: rect.minX + w - rt, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// The notch surface: a Dynamic-Island-style card drawn from the shared
/// AppModel. It is its own compact composition (not the window's columns):
/// project and status beside the camera housing, the shown answer, small
/// ‹ › steps through earlier answers, and one primary action.
///
/// The island is black in both appearances so it merges with the hardware
/// notch; its text uses the dark appearance for contrast.
public struct NotchRootView: View {
    let model: AppModel
    let presentation: NotchPresentation
    let interaction: NotchInteraction
    let actions: SurfaceActions

    public init(model: AppModel, presentation: NotchPresentation, interaction: NotchInteraction, actions: SurfaceActions) {
        self.model = model
        self.presentation = presentation
        self.interaction = interaction
        self.actions = actions
    }

    /// Lines of the answer shown in the island; the full text is in the
    /// window and is what Copy Response copies.
    static let previewLines = 6
    private var ear: CGFloat { NotchLayout.earWidth }
    private var expanded: Bool { presentation.isExpanded }
    private var topRadius: CGFloat { expanded ? 14 : 6 }

    private var islandSize: CGSize {
        let notch = presentation.notchSize
        if expanded { return CGSize(width: presentation.islandWidth, height: notch.height + presentation.contentHeight) }
        if presentation.showsIndicator { return CGSize(width: notch.width + ear * 2, height: notch.height) }
        // Resting: a little smaller than the camera housing and more rounded,
        // so it always stays hidden behind it (no black edge can peek out).
        return CGSize(width: notch.width - 2, height: notch.height - 1)
    }

    /// Bottom corner radius: generous at rest (inside the hardware curve).
    private var bottomRadius: CGFloat {
        if expanded { return 24 }
        return presentation.showsIndicator ? 10 : presentation.notchSize.height / 2
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // No shadow: the island must not show a grey halo on light desktops.
            NotchShape(bottomRadius: bottomRadius, topRadius: topRadius)
                .fill(Color.black)
            if expanded {
                expandedContent
                    .transition(presentation.reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .offset(y: -6)).animation(.easeOut(duration: 0.18).delay(0.05)))
            } else {
                compactContent
                    .transition(.opacity.animation(.easeOut(duration: 0.1)))
            }
        }
        .frame(width: islandSize.width, height: islandSize.height, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .sensitiveContextAlert(model)
    }

    // MARK: Compact

    private var compactContent: some View {
        HStack(spacing: 0) {
            if presentation.showsIndicator {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: ear)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
            if presentation.showsIndicator {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                    .frame(width: ear)
                    .padding(.trailing, 4)
            }
        }
        .frame(height: islandSize.height)
        .contentShape(Rectangle())
        .onTapGesture { interaction.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.showsIndicator ? "Prompt Relay: a new answer is ready" : "Prompt Relay")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { interaction.toggle() }
    }

    // MARK: Expanded

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            band
            body(for: model.selectedTurn)
                .padding(.horizontal, 18 + topRadius)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { presentation.reportContentHeight(proxy.size.height) }
                        .onChange(of: proxy.size.height) { _, h in presentation.reportContentHeight(h) }
                })
        }
        .frame(width: presentation.islandWidth, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.white)
    }

    /// The row level with the camera housing: project left, status right.
    private var band: some View {
        let side = max(0, (presentation.islandWidth - presentation.notchSize.width) / 2 - topRadius - 10)
        return HStack(spacing: 0) {
            Text(model.selectedProject.map(Wording.projectName) ?? "Prompt Relay")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: side, alignment: .leading)
            Spacer(minLength: presentation.notchSize.width)
            statusLabel
                .frame(width: side, alignment: .trailing)
        }
        .padding(.horizontal, topRadius + 8)
        .frame(height: presentation.notchSize.height)
    }

    private var statusLabel: some View {
        HStack(spacing: 5) {
            Circle().fill(statusColor).frame(width: 6, height: 6)
            Text(statusText).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        if model.projects.error != nil, model.projects.value == nil { return .red }
        guard let turn = model.selectedTurn else { return .gray }
        return StatusBadge(turn.status).color
    }

    /// Only facts: when Claude stopped. Never "done" or "tests passed".
    private var statusText: String {
        if model.projects.error != nil, model.projects.value == nil { return "Core unavailable" }
        guard let turn = model.selectedTurn else { return "No answer yet" }
        let when = Wording.short(turn.finalResponse?.receivedAt ?? turn.request?.receivedAt)
        switch turn.status {
        case .stopReceived: return "Stopped \(when)"
        case .stopReceivedBackgroundTasksPending: return "Tasks running"
        default: return Wording.status(turn.status)
        }
    }

    @ViewBuilder
    private func body(for turn: Turn?) -> some View {
        if let error = model.projects.error, model.projects.value == nil {
            message(error.title, detail: error.detail, symbol: "exclamationmark.triangle")
        } else if model.projects.value?.isEmpty == true {
            message("No answers yet", detail: "Enable a project with prompt-relay enable, then send a prompt in Claude Code.",
                    symbol: "tray")
        } else if let turn {
            VStack(alignment: .leading, spacing: 10) {
                answer(turn)
                meta(turn)
                actionRow(turn)
            }
        } else {
            message("No answer yet", detail: "Answers from Claude Code appear here when it stops.", symbol: "text.bubble")
        }
    }

    private func message(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            openWindowButton
        }
    }

    @ViewBuilder
    private func answer(_ turn: Turn) -> some View {
        if let blocker = AppModel.copyBlocker(for: turn) {
            Text(turn.error?.message ?? blocker)
                .font(.system(size: 13))
                .foregroundStyle(turn.status == .apiError ? Color.red.opacity(0.9) : .white.opacity(0.6))
                .lineLimit(3)
        } else {
            // Shown text only; the copy always uses the Core's full text.
            Text(Self.excerpt(model.selectedResponseText ?? turn.finalResponse?.preview ?? ""))
                .font(.system(size: 13))
                .lineSpacing(2)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(Self.previewLines)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Answer preview")
        }
    }

    /// The first characters of the answer for display: long blank runs are
    /// shortened so six lines show content. Never used for copying.
    static func excerpt(_ text: String) -> String {
        var out = String(text.prefix(800))
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func meta(_ turn: Turn) -> some View {
        let answers = Self.answerTurns(model)
        let position = answers.firstIndex(of: turn.index).map { $0 + 1 }
        return HStack(spacing: 6) {
            if let response = turn.finalResponse, response.charCount > 0 {
                Text(Wording.size(response))
            }
            if let note = Wording.link(turn.link) { Text("· " + note) }
            Spacer(minLength: 4)
            if answers.count > 1, let position {
                stepButton("chevron.left", label: "Older answer", enabled: position < answers.count) { Self.step(model, by: 1) }
                Text("\(position) of \(answers.count)").monospacedDigit()
                stepButton("chevron.right", label: "Newer answer", enabled: position > 1) { Self.step(model, by: -1) }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.5))
    }

    private func stepButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(enabled ? 0.8 : 0.25))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func actionRow(_ turn: Turn) -> some View {
        let canCopy = AppModel.copyBlocker(for: turn) == nil
        return HStack(spacing: 8) {
            Button {
                Task { await model.copySelectedResponse() }
            } label: {
                Label(responseCopied ? "Copied" : "Copy Response",
                      systemImage: responseCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).frame(height: 28)
                    .background(Capsule().fill(Color.white.opacity(canCopy ? 1 : 0.3)))
                    .foregroundStyle(.black)
                    .contentTransition(.opacity)
            }
            .buttonStyle(.plain)
            .disabled(!canCopy)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .accessibilityLabel("Copy Response")
            .accessibilityHint("Copies Claude's full final answer")

            Button {
                Task { await model.copySelectedContext() }
            } label: {
                Text(contextCopied ? "Copied" : "Context")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy Context")
            .help("Copy a Markdown packet: request, response, provenance and git state")

            if case .failed(let reason) = model.copyFeedback {
                Text(reason).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
            }
            Spacer(minLength: 4)
            openWindowButton
        }
        .animation(.easeOut(duration: 0.15), value: model.copyFeedback)
    }

    private var openWindowButton: some View {
        Button { interaction.close(); actions.openWindow() } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Full Window")
        .help("Open the full answer in the Prompt Relay window")
    }

    private var responseCopied: Bool {
        if case .copied(.response, _) = model.copyFeedback { return true }
        return false
    }

    private var contextCopied: Bool {
        if case .copied(.context, _) = model.copyFeedback { return true }
        return false
    }

    // MARK: Navigation (shared with the keyboard handler)

    /// Turns of the selected session that have something to show, newest first.
    static func answerTurns(_ model: AppModel) -> [Int] {
        model.turnsNewestFirst.filter { $0.finalResponse != nil || $0.status == .apiError }.map(\.index)
    }

    /// Positive steps go to older answers, negative to newer ones.
    static func step(_ model: AppModel, by delta: Int) {
        let answers = answerTurns(model)
        guard !answers.isEmpty else { return }
        let current = answers.firstIndex(of: model.selectedTurnIndex ?? -1) ?? 0
        let next = min(max(current + delta, 0), answers.count - 1)
        if answers[next] != model.selectedTurnIndex { model.selectTurn(answers[next]) }
    }
}
