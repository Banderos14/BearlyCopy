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

/// The island over the shared AppModel, in three states: resting (hidden
/// behind the camera housing, or two small "new answer" ears), Quick Peek on
/// hover (the newest answer and the copy actions) and Expanded on click,
/// ⌃⌥⌘P or the menu-bar item: the one interface, whose views (projects,
/// recent, all responses, settings, full response) open inside it.
///
/// The island is black in both appearances so it merges with the hardware
/// notch; its text uses the dark appearance for contrast. On a display
/// without a notch the same content floats below the menu bar.
public struct NotchRootView: View {
    let model: AppModel
    let presentation: NotchPresentation
    let interaction: NotchInteraction
    let actions: SurfaceActions
    let settings: NotchSettings?
    let notifier: ReadyNotifier?
    @State private var tips: IslandTooltips

    public init(model: AppModel, presentation: NotchPresentation, interaction: NotchInteraction, actions: SurfaceActions,
                settings: NotchSettings? = nil, notifier: ReadyNotifier? = nil) {
        self.init(model: model, presentation: presentation, interaction: interaction, actions: actions,
                  settings: settings, notifier: notifier, tips: IslandTooltips())
    }

    init(model: AppModel, presentation: NotchPresentation, interaction: NotchInteraction, actions: SurfaceActions,
         settings: NotchSettings?, notifier: ReadyNotifier?, tips: IslandTooltips) {
        _tips = State(initialValue: tips)
        self.model = model
        self.presentation = presentation
        self.interaction = interaction
        self.actions = actions
        self.settings = settings
        self.notifier = notifier
    }

    /// Lines of the answer in Quick Peek; Home shows more, the reader all of
    /// it, and Copy Response always copies the full text.
    static let previewLines = 4
    /// The island's own coordinate space (origin: its top-left corner).
    static let space = "island"
    private var ear: CGFloat { NotchLayout.earWidth }
    private var expanded: Bool { presentation.isExpanded }
    /// The open island's top flare: its sides stand this far in from the window.
    static let expandedTopRadius: CGFloat = 14
    private var topRadius: CGFloat { expanded ? Self.expandedTopRadius : 6 }

    private var islandSize: CGSize {
        let notch = presentation.notchSize
        if expanded { return CGSize(width: presentation.islandWidth, height: notch.height + presentation.contentHeight) }
        if presentation.hasEars { return CGSize(width: notch.width + ear * 2, height: notch.height) }
        return Self.restingSize(notch: notch)
    }

    /// Resting: a little smaller than the camera housing and more rounded,
    /// so it always stays hidden behind it (no black edge can peek out).
    /// Never negative: without a notch (size zero) SwiftUI warned "Invalid
    /// frame dimension" on every layout (Phase 5.11).
    static func restingSize(notch: CGSize) -> CGSize {
        CGSize(width: max(0, notch.width - 2), height: max(0, notch.height - 1))
    }

    /// Bottom corner radius: generous at rest (inside the hardware curve).
    private var bottomRadius: CGFloat {
        if expanded { return 26 }
        return presentation.hasEars ? 10 : presentation.notchSize.height / 2
    }

    private var shape: AnyShape {
        presentation.isFloating
            ? AnyShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            : AnyShape(NotchShape(bottomRadius: bottomRadius, topRadius: topRadius))
    }

    #if DEBUG
    nonisolated(unsafe) static var bodyCount = 0
    #endif

    public var body: some View {
        #if DEBUG
        let _ = { Self.bodyCount += 1 }()
        #endif
        ZStack(alignment: .topLeading) {
            // No shadow: the island must not show a grey halo on light desktops.
            shape.fill(Color.black)
            if expanded {
                openContent
                    .transition(presentation.reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .offset(y: -6)).animation(.easeOut(duration: 0.18).delay(0.05)))
            } else {
                compactContent
                    .transition(.opacity.animation(.easeOut(duration: 0.1)))
            }
            if expanded {
                let metrics = IslandMetrics.of(presentation)
                IslandTooltipOverlay(tips: tips, size: islandSize, band: presentation.notchSize.height,
                                     helpArea: CGRect(x: metrics.leading,
                                                      y: presentation.notchSize.height + presentation.bodyContentHeight - 6,
                                                      width: islandSize.width - 2 * metrics.leading,
                                                      height: presentation.helpTextHeight),
                                     onMeasure: { presentation.helpTextHeight = $0 })
            }
        }
        .animation(IslandTooltips.animation(reduceMotion: presentation.reduceMotion), value: presentation.helpTextHeight)
        .onChange(of: tips.tip == nil) { _, hidden in
            if hidden { presentation.helpTextHeight = 0 }
        }
        .environment(\.islandTooltips, tips)
        // A theme change redraws the island with the new roles.
        .id(settings?.theme)
        .onChange(of: presentation.isExpanded) { tips.hideAll() }
        .onChange(of: model.route) { tips.hideAll() }
        .onChange(of: model.clipboardTab) { tips.hideAll() }
        .onChange(of: presentation.surface) { tips.hideAll() }
        .frame(width: islandSize.width, height: islandSize.height, alignment: .top)
        .coordinateSpace(name: Self.space)
        #if DEBUG
        .environment(\.islandFrameSink, { [presentation] id, rect in presentation.layoutFrames[id] = rect })
        #endif
        .clipShape(shape)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .sensitiveContextAlert(model)
    }

    // MARK: Compact

    /// Left ear: Relay the bear (or a bubble for a new answer when the
    /// mascot is off); right ear: the "new answer" dot.
    private var compactContent: some View {
        HStack(spacing: 0) {
            // No notch (Phase 7.1): the floating pill has no camera between
            // the ears, so Relay sits in its middle, clear of the round ends.
            if presentation.isFloating, presentation.showsMascot { Spacer(minLength: 0) }
            if presentation.showsMascot {
                // R8: at x = 8 in the ear (3.4 pt clear of the visible side
                // and of the camera housing); its motion is bounded there.
                let size = MascotView.size(notchHeight: presentation.notchSize.height)
                MascotView(state: presentation.mascot, size: size, reduceMotion: presentation.reduceMotion, resting: true,
                           breathes: presentation.breathes)
                .frame(width: size, height: size)
                .padding(.leading, presentation.isFloating ? 0 : RestingPose.origin.x)
                .frame(width: presentation.isFloating ? size : ear, alignment: .leading)
                .islandFrame("resting.mascot")
            } else if case .ready = presentation.indicator {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: ear)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
            if presentation.indicator != .none {
                ReadyIndicatorView(indicator: presentation.indicator, reduceMotion: presentation.reduceMotion)
                    .frame(width: ear)
                    .padding(.trailing, 4)
                    .islandFrame("resting.indicator")
            }
        }
        .frame(height: islandSize.height)
        .contentShape(Rectangle())
        .onTapGesture { interaction.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ReadyIndicatorView.label(presentation.indicator))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { interaction.toggle() }
    }

    // MARK: Open (Quick Peek or Expanded)

    /// Sized to its content: the island and its window follow the measured
    /// height, so no state has empty space below it.
    private var openContent: some View {
        AdaptiveIslandViewport(budget: presentation.notchSize.height + presentation.bodyBudget) {
            if presentation.surface == .expanded {
                IslandContent(model: model, presentation: presentation, interaction: interaction, actions: actions,
                              settings: settings, notifier: notifier)
            } else {
                PeekContent(model: model, presentation: presentation, interaction: interaction)
            }
        }
        .frame(width: presentation.islandWidth, alignment: .top)
        // The whole height budget is offered; the content takes what it needs.
        .onPreferenceChange(IslandExtraHeightKey.self) { heights in
            let total = heights.values.reduce(0, +)
            if presentation.temporaryContentHeight != total { presentation.temporaryContentHeight = total }
        }
        .animation(presentation.resizeAnimation, value: presentation.temporaryContentHeight)
        .environment(\.islandReduceMotion, presentation.reduceMotion)
        // Read after layout; the window follows on the next display pass.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
            presentation.reportBodyHeight(h - presentation.notchSize.height)
        }
        .foregroundStyle(.white)
    }

    /// The first characters of the answer for display: long blank runs are
    /// shortened so the preview shows content. Never used for copying.
    static func excerpt(_ text: String, limit: Int = 800) -> String {
        var out = String(text.prefix(limit))
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
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

/// Phase 8: the right ear. An unseen answer is a small light dot (a ring
/// when Claude Code started that turn itself, not your request), with the
/// number of sessions when more than one has one; a prompt still waiting
/// for Claude is three dim dots. Never "done" or "success": Stop only means
/// Claude stopped answering. Appears with one soft scale-in; no loop runs.
struct ReadyIndicatorView: View {
    let indicator: AppModel.ReadyIndicator
    let reduceMotion: Bool

    var body: some View {
        Group {
            switch indicator {
            case .none:
                EmptyView()
            case .working:
                HStack(spacing: 2.5) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.42)).frame(width: 3, height: 3) }
                }
                .transition(.opacity)
            case .ready(let sessions, let automated, let background):
                HStack(spacing: 3) {
                    ZStack {
                        // Phase 9.3: green = an answer with text is available
                        // (not "task succeeded"); the palette's success tone.
                        if automated {
                            Circle().strokeBorder(Island.success, lineWidth: 1.5)
                        } else {
                            Circle().fill(Island.success)
                        }
                        if background {
                            Circle().strokeBorder(Island.warning, lineWidth: 1.2).frame(width: 11, height: 11)
                        }
                    }
                    .frame(width: 7, height: 7)
                    if sessions > 1 {
                        Text("\(sessions)").font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.8))
                    }
                }
                .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
            case .attention:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Island.warning)
                    .frame(width: 11, height: 11)
                    .background(Circle().strokeBorder(Island.warning, lineWidth: 1.2))
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.62), value: indicator)
    }

    static func label(_ indicator: AppModel.ReadyIndicator) -> String {
        switch indicator {
        case .none: return "Prompt Relay"
        case .working(let n): return "Prompt Relay: an agent is working" + (n > 1 ? " in \(n) sessions" : "")
        case .attention: return "Prompt Relay: capture needs attention. Open Settings → Advanced."
        case .ready(let n, let automated, let background):
            return "Prompt Relay: " + (automated ? "an answer to a turn Claude Code started itself" : "a new answer")
                + (background ? ", background work was still running" : "")
                + (n > 1 ? "; new answers in \(n) sessions" : "") + ". Not yet opened."
        }
    }
}
