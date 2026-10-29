import AppKit
import Observation
import SwiftUI

/// What the SwiftUI notch content needs to draw itself; owned by the controller.
@MainActor
@Observable
public final class NotchPresentation {
    /// What the open island shows.
    public enum Surface: Equatable, Sendable {
        /// Quick Peek, opened by hover: the newest answer and the copy actions.
        case peek
        /// Expanded, opened by a click, ⌃⌥⌘P or the menu-bar item: the one
        /// interface, with its views (projects, history, settings…) inside.
        case expanded
    }

    public internal(set) var isExpanded = false
    public internal(set) var surface: Surface = .peek
    public internal(set) var isFocused = false
    public internal(set) var reduceMotion = false
    /// Size of the camera housing on the active display.
    public internal(set) var notchSize = CGSize(width: 185, height: 32)
    /// Width of the expanded island on the active display.
    public internal(set) var islandWidth = NotchLayout.expandedWidth
    /// Height the expanded content needs (measured by the view); the island
    /// and its window follow it, so there is never empty space below.
    public internal(set) var contentHeight: CGFloat = NotchLayout.minContentHeight
    /// Tallest content on the active display; lists and long text scroll inside it.
    public internal(set) var maxContentHeight: CGFloat = 388
    /// No notch on the display: the island floats below the menu bar.
    public internal(set) var isFloating = false
    /// Show the small "answer ready" ears beside the notch.
    public internal(set) var showsIndicator = false
    /// Relay the bear beside the notch and in the band (Settings → Appearance).
    public internal(set) var showsMascot = false
    public let mascot = MascotState()
    /// The resting island has ears: a new answer, or the mascot.
    var hasEars: Bool { showsIndicator || showsMascot }
    var onContentHeight: ((CGFloat) -> Void)?

    public init() {}

    /// Called by the view when its content size changes.
    func reportContentHeight(_ height: CGFloat) {
        let clamped = min(max(height.rounded(.up), NotchLayout.minContentHeight), maxContentHeight)
        guard abs(clamped - contentHeight) >= 1 else { return }
        if let onContentHeight { onContentHeight(clamped) } else { contentHeight = clamped }
    }

    /// Height available to a scrolling list inside a view with a header and
    /// a footer of `chrome` points.
    func listHeight(chrome: CGFloat) -> CGFloat { max(80, maxContentHeight - chrome) }

    var animation: Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.86)
    }
}

/// Reads the displays; injectable so multi-display behavior is testable.
@MainActor
public protocol ScreenProviding: AnyObject {
    var screens: [ScreenDescriptor] { get }
}

@MainActor
public final class LiveScreens: ScreenProviding {
    public init() {}
    public var screens: [ScreenDescriptor] { NSScreen.screens.map(ScreenDescriptor.init) }
}

/// Other apps that draw their own island in the notch. Prompt Relay never
/// changes them; it only notices that they run.
@MainActor
public protocol NotchNeighbors: AnyObject {
    /// Localized names of running apps that use the notch area.
    var running: [String] { get }
}

@MainActor
public final class LiveNotchNeighbors: NotchNeighbors {
    /// Coucou (formerly NotchBuddy): its App Store and GitHub builds.
    public static let bundleIDs: Set<String> = ["fr.louisraille.Coucou", "fr.louisraille.NotchBuddy"]
    public init() {}
    public var running: [String] {
        let apps = NSWorkspace.shared.runningApplications
        var names = apps
            .filter { $0.bundleIdentifier.map(Self.bundleIDs.contains) ?? false }
            .map { $0.localizedName ?? $0.bundleIdentifier ?? "another notch app" }
        // The Release build steps aside for a Debug build being developed, so
        // two Prompt Relay islands never sit on top of each other.
        if AppBuild.bundleID == AppBuild.releaseBundleID,
           apps.contains(where: { $0.bundleIdentifier == AppBuild.debugBundleID }) {
            names.append(AppBuild.name(of: AppBuild.debugBundleID))
        }
        return names
    }
}

/// Owns the one notch panel: where it is, which phase it shows, and every
/// observer it needs. `start()`/`stop()` are idempotent and `stop()` removes
/// all of them (window, tracking area, notifications, hotkey, timers).
@MainActor
public final class NotchController {
    public let interaction: NotchInteraction
    public let presentation = NotchPresentation()
    public private(set) var layout: NotchLayout?
    public private(set) var activeScreen: ScreenDescriptor?
    public private(set) var isRunning = false
    /// Another notch app runs and the user prefers to yield: the island has
    /// no hover target, and ⌃⌥⌘P or the menu-bar item open the panel.
    public private(set) var isYielding = false
    /// The resting island is shown and opens on hover (a notch, the setting
    /// on, not yielding). Otherwise it opens from the menu bar or ⌃⌥⌘P only.
    public private(set) var hasRestingTarget = false
    public private(set) var neighborNames: [String] = []

    private let model: AppModel
    private let settings: NotchSettings
    private let screens: ScreenProviding
    private let center: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let actions: SurfaceActions
    private let makeHotKey: @MainActor () -> HotKeyRegistration?
    private let neighbors: NotchNeighbors
    private let notifier: ReadyNotifier
    private var panel: NotchPanel?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var hotKey: HotKeyRegistration?
    private var collapseWork: DispatchWorkItem?
    private var observingModel = false
    private var menuTracking = false
    private var sensitivePending = false
    private var dialogOpen = false
    var blinkTask: Task<Void, Never>?
    private var resizeWork: DispatchWorkItem?
    /// The view `present(_:)` asked for, applied when the island opens.
    private var pendingRoute: AppModel.IslandRoute?

    public init(model: AppModel, settings: NotchSettings, actions: SurfaceActions, notifier: ReadyNotifier? = nil,
                screens: ScreenProviding? = nil,
                scheduler: NotchScheduling? = nil,
                center: NotificationCenter = .default,
                workspaceCenter: NotificationCenter? = nil,
                makeHotKey: (@MainActor () -> HotKeyRegistration?)? = nil,
                neighbors: NotchNeighbors? = nil) {
        self.model = model
        self.settings = settings
        self.actions = actions
        self.screens = screens ?? LiveScreens()
        self.center = center
        self.workspaceCenter = workspaceCenter ?? NSWorkspace.shared.notificationCenter
        self.makeHotKey = makeHotKey ?? { HotKeyRegistration.standard() }
        self.neighbors = neighbors ?? LiveNotchNeighbors()
        self.notifier = notifier ?? ReadyNotifier()
        interaction = NotchInteraction(scheduler: scheduler ?? MainQueueScheduler())
        interaction.onChange = { [weak self] phase, old in self?.apply(phase, from: old) }
        presentation.onContentHeight = { [weak self] height in self?.resize(to: height) }
    }

    /// Number of registered notification observers (leak checks in tests).
    public var observerCount: Int { observers.count }
    public var hasPanel: Bool { panel != nil }
    public var panelFrame: CGRect? { panel?.frame }
    public var panelIsVisible: Bool { panel?.isVisible ?? false }

    // MARK: Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let onDisplayChange: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.relayout() }
        }
        observers.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                     object: nil, queue: .main, using: onDisplayChange)))
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append((workspaceCenter, workspaceCenter.addObserver(forName: name, object: nil, queue: .main,
                                                                           using: onDisplayChange)))
        }
        // A menu opened from the island (⋯) takes the pointer outside it; the
        // island stays open until the menu closes.
        for (name, open) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setMenuTracking(open) }
            }))
        }
        hotKey = makeHotKey()
        hotKey?.onPress = { [weak self] in self?.toggleFromKeyboard() }
        model.startBackgroundObservation()
        observeModel()
        relayout()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        for (nc, token) in observers { nc.removeObserver(token) }
        observers.removeAll()
        hotKey?.unregister()
        hotKey = nil
        collapseWork?.cancel()
        resizeWork?.cancel()
        menuTracking = false
        dialogOpen = false
        blinkTask?.cancel()
        blinkTask = nil
        interaction.setAvailable(false)   // cancels timers, orders the panel out
        panel?.tearDown()
        panel?.close()
        panel = nil
        layout = nil
        activeScreen = nil
    }

    // MARK: Layout

    /// Re-reads the displays: plugging monitors in or out, resolution or
    /// scaling changes, wake from sleep, Space changes.
    public func relayout() {
        guard isRunning else { return }
        let all = screens.screens
        // The chosen notched display, else a floating island on the menu-bar display.
        guard let screen = DisplayChoice.pick(settings.display, from: all) ?? all.first else {
            activeScreen = nil
            layout = nil
            interaction.setAvailable(false)
            return
        }
        let newLayout = NotchLayout(screen: screen) ?? NotchLayout(floatingOn: screen)
        defer { updateBlinking() }
        let moved = activeScreen?.displayID != screen.displayID || layout != newLayout
        activeScreen = screen
        layout = newLayout
        neighborNames = neighbors.running
        let yielding = settings.yieldToOtherNotchApps && !neighborNames.isEmpty
        let resting = !newLayout.isFloating && settings.notchEnabled && !yielding
        let yieldChanged = yielding != isYielding || resting != hasRestingTarget
        isYielding = yielding
        hasRestingTarget = resting
        presentation.notchSize = newLayout.notch.size
        presentation.islandWidth = newLayout.expandedIslandWidth
        presentation.maxContentHeight = newLayout.maxContentHeight
        presentation.isFloating = newLayout.isFloating
        let mascotChanged = presentation.showsMascot != settings.mascotEnabled
        presentation.showsMascot = settings.mascotEnabled
        presentation.reduceMotion = settings.reducesMotion(systemReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        ensurePanel()
        if interaction.phase == .hidden {
            interaction.setAvailable(true)
        } else if moved || yieldChanged || mascotChanged {
            interaction.close()
            placePanel(for: interaction.phase)
        } else if interaction.phase.isExpanded || hasRestingTarget {
            // Regression: this re-showed the resting panel with hover off.
            panel?.orderFrontRegardless()
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NotchPanel()
        let root = NotchRootView(model: model, presentation: presentation, interaction: interaction, actions: actions,
                                 settings: settings, notifier: notifier)
        panel.install(root: root)
        panel.onPointer = { [weak self] inside in
            guard let self else { return }
            if inside { self.interaction.pointerEntered() } else { self.interaction.pointerExited(); self.pointerLeft() }
        }
        panel.onResignKey = { [weak self] in self?.interaction.focusLost() }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onKey = { [weak self] key in self?.handleKey(key) ?? false }
        panel.onMove = { [weak self] point in self?.look(at: point) }
        self.panel = panel
    }

    private func compactFrame() -> CGRect? {
        guard let layout else { return nil }
        return presentation.hasEars ? layout.compact : layout.notch
    }

    private func placePanel(for phase: NotchInteraction.Phase) {
        guard let panel, let layout else { return }
        switch phase {
        case .hidden:
            panel.orderOut(nil)
        case .compact:
            if let frame = compactFrame() { panel.setFrame(frame, display: true) }
            if hasRestingTarget { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        case .expanded:
            panel.setFrame(expandedFrame(layout), display: true)
            panel.orderFrontRegardless()
        }
    }

    private func expandedFrame(_ layout: NotchLayout) -> CGRect {
        layout.expandedFrame(contentHeight: presentation.contentHeight)
    }

    /// The content changed height (another view, a list grew): the window
    /// stays exactly as tall as the island, anchored at the top edge. Growing,
    /// the window grows first and the island animates into it; shrinking,
    /// the island animates first and the window follows.
    private func resize(to height: CGFloat) {
        resizeWork?.cancel()
        guard interaction.phase.isExpanded, let panel, let layout else {
            presentation.contentHeight = height
            return
        }
        if height >= presentation.contentHeight {
            panel.setFrame(layout.expandedFrame(contentHeight: height), display: true)
            withAnimation(presentation.animation) { presentation.contentHeight = height }
        } else {
            withAnimation(presentation.animation) { presentation.contentHeight = height }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.interaction.phase.isExpanded, let layout = self.layout else { return }
                self.panel?.setFrame(layout.expandedFrame(contentHeight: self.presentation.contentHeight), display: true)
            }
            resizeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (presentation.reduceMotion ? 0.12 : 0.3), execute: work)
        }
    }

    // MARK: Phases

    private func apply(_ phase: NotchInteraction.Phase, from old: NotchInteraction.Phase) {
        defer { updateBlinking() }
        collapseWork?.cancel()
        switch phase {
        case .hidden:
            presentation.isExpanded = false
            presentation.isFocused = false
            if old.isExpanded { model.surfaceDisappeared() }
            panel?.orderOut(nil)
        case .compact:
            if old.isExpanded { model.surfaceDisappeared() }
            presentation.isFocused = false
            withAnimation(presentation.animation) { presentation.isExpanded = false }
            if old.isExpanded {
                // Shrink the content first, then the window, so nothing jumps.
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.interaction.phase == .compact else { return }
                    self.placePanel(for: .compact)
                }
                collapseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + (presentation.reduceMotion ? 0.12 : 0.3), execute: work)
            } else {
                placePanel(for: .compact)
            }
        case .expanded(let focused):
            if !old.isExpanded {
                // Hover opens the peek; a click, the shortcut or the menu bar
                // the expanded island, on Home unless a view was asked for.
                presentation.surface = focused ? .expanded : .peek
                model.route = pendingRoute ?? .home
                pendingRoute = nil
            } else if focused, presentation.surface == .peek {
                withAnimation(presentation.animation) { presentation.surface = .expanded }
            }
            placePanel(for: phase)
            if !old.isExpanded {
                model.surfaceAppeared()
                if model.hasUnseenAnswer { Task { await model.revealReadyAnswer() } }
            }
            presentation.isFocused = focused
            withAnimation(presentation.animation) { presentation.isExpanded = true }
            if focused { panel?.makeKey() }
        }
    }

    public func toggleFromKeyboard() {
        interaction.toggle()
    }

    /// Opens the island on a view (the menu-bar item: Open, Settings…).
    public func present(_ route: AppModel.IslandRoute = .home) {
        if interaction.phase.isExpanded {
            model.route = route
            interaction.focus()
        } else {
            pendingRoute = route
            interaction.toggle()
            if !interaction.phase.isExpanded { pendingRoute = nil }
        }
    }

    /// Esc: back from a view, close from Home.
    func cancel() {
        if presentation.surface == .expanded, model.route != .home {
            model.goBack()
        } else {
            interaction.close()
        }
    }

    func handleKeyForTesting(_ key: NotchPanel.Key) -> Bool { handleKey(key) }

    /// ← → move to older / newer answers, Return copies the shown one. Only
    /// on the answer; elsewhere the keys go to the lists.
    private func handleKey(_ key: NotchPanel.Key) -> Bool {
        guard model.route == .home else { return false }
        switch key {
        case .older: NotchRootView.step(model, by: 1)
        case .newer: NotchRootView.step(model, by: -1)
        case .returnKey: Task { await model.copySelectedResponse() }
        }
        return true
    }

    // MARK: Model observation

    /// Keep the indicator ears and the pin state in step with the model,
    /// without polling: Observation re-arms after each change.
    private func observeModel() {
        guard !observingModel else { return }
        observingModel = true
        track()
    }

    private func track() {
        guard isRunning else { observingModel = false; return }
        let unseen = withObservationTracking {
            (model.hasUnseenAnswer, model.pendingSensitiveContext != nil, model.isPresentingSystemDialog,
             model.copyFeedback, model.projects.error != nil && model.projects.value == nil)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.track() } }
        }
        let showIndicator = unseen.0
        if presentation.showsIndicator != showIndicator {
            withAnimation(presentation.animation) { presentation.showsIndicator = showIndicator }
            if interaction.phase == .compact { placePanel(for: .compact) }
        }
        react(newAnswer: unseen.0, copy: unseen.3, coreDown: unseen.4)
        sensitivePending = unseen.1
        let dialogClosed = dialogOpen && !unseen.2
        dialogOpen = unseen.2
        updatePin()
        // Back from the folder picker: the island takes the keyboard again.
        if dialogClosed, interaction.phase.isExpanded { interaction.focus(); panel?.makeKey() }
    }

    private func setMenuTracking(_ open: Bool) {
        guard isRunning, interaction.phase.isExpanded || !open else { return }
        menuTracking = open
        updatePin()
    }

    /// Nothing closes the island while an alert or a menu from it is open.
    private func updatePin() {
        let pinned = sensitivePending || menuTracking || dialogOpen
        if interaction.isPinned != pinned { interaction.isPinned = pinned }
    }
}

// MARK: - Mascot

extension NotchController {
    /// Eyes follow the pointer, but only from pointer events inside the
    /// island's own window: nothing is tracked outside it, nothing is stored.
    func look(at point: CGPoint) {
        guard presentation.showsMascot, !presentation.reduceMotion, let panel else { return }
        // The mascot's center in window coordinates: the left ear at rest,
        // the band's left side when open (window origin bottom-left).
        let height = panel.frame.height
        let center: CGPoint = presentation.isExpanded
            ? CGPoint(x: (presentation.isFloating ? 4 : 14) + Island.inset + 9, y: height - presentation.notchSize.height / 2)
            : CGPoint(x: NotchLayout.earWidth / 2, y: height / 2)
        let dx = (point.x - center.x) / 120, dy = (center.y - point.y) / 80
        let gaze = CGPoint(x: max(-1, min(1, dx)), y: max(-1, min(1, dy)))
        if abs(gaze.x - presentation.mascot.gaze.x) > 0.04 || abs(gaze.y - presentation.mascot.gaze.y) > 0.04 {
            presentation.mascot.gaze = gaze
        }
    }

    func pointerLeft() { presentation.mascot.gaze = .zero }

    /// Short reactions to facts: a captured answer, a copy, a failure.
    func react(newAnswer: Bool, copy: AppModel.CopyFeedback, coreDown: Bool) {
        let mascot = presentation.mascot
        let mood: MascotState.Mood
        switch copy {
        case .copied: mood = .pleased
        case .failed: mood = .concerned
        default: mood = coreDown ? .concerned : (newAnswer ? .curious : .idle)
        }
        if mascot.mood != mood { mascot.mood = mood }
    }

    /// Occasional blinks, only while the mascot is on screen and motion is
    /// allowed; nothing runs while it is hidden.
    func updateBlinking() {
        let visible = isRunning && presentation.showsMascot && !presentation.reduceMotion
            && (interaction.phase.isExpanded || (interaction.phase == .compact && hasRestingTarget))
        if visible, blinkTask == nil {
            blinkTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 3_500_000_000...7_000_000_000))
                    guard let self, !Task.isCancelled else { return }
                    self.presentation.mascot.isBlinking = true
                    try? await Task.sleep(nanoseconds: 140_000_000)
                    self.presentation.mascot.isBlinking = false
                }
            }
        } else if !visible {
            blinkTask?.cancel()
            blinkTask = nil
            presentation.mascot.isBlinking = false
        }
    }

    public var isBlinkLoopRunning: Bool { blinkTask != nil }
}

// MARK: - Panel

/// Borderless, non-activating, transparent panel above the menu bar. It only
/// receives events inside its own frame, which is never larger than the
/// notch (plus two small ears) while collapsed.
final class NotchPanel: NSPanel {
    enum Key { case older, newer, returnKey }

    var onPointer: ((Bool) -> Void)?
    var onResignKey: (() -> Void)?
    var onCancel: (() -> Void)?
    var onKey: ((Key) -> Bool)?
    var onMove: ((CGPoint) -> Void)?
    private var tracking: TrackingView?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)   // black island: AppKit views inside draw light text
        setAccessibilityLabel("Prompt Relay")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit would push a window out of the menu-bar band; the island lives there.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func install<V: View>(root: V) {
        let host = NSHostingView(rootView: root)
        host.autoresizingMask = [.width, .height]
        let container = TrackingView()
        container.onPointer = { [weak self] in self?.onPointer?($0) }
        container.onMove = { [weak self] in self?.onMove?($0) }
        container.addSubview(host)
        host.frame = container.bounds
        contentView = container
        tracking = container
    }

    func tearDown() {
        tracking?.removeTracking()
        tracking?.onPointer = nil
        tracking?.onMove = nil
        onPointer = nil; onResignKey = nil; onCancel = nil; onKey = nil; onMove = nil
        contentView = nil
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        let handled: Bool
        switch event.keyCode {
        case 123, 125: handled = onKey?(.older) ?? false   // ← ↓
        case 124, 126: handled = onKey?(.newer) ?? false   // → ↑
        case 36, 76: handled = onKey?(.returnKey) ?? false
        default: handled = false
        }
        if !handled { super.keyDown(with: event) }
    }
}

/// Reports pointer enter/exit for its own bounds only.
final class TrackingView: NSView {
    var onPointer: ((Bool) -> Void)?
    /// Pointer moves inside this view only (the mascot's eyes).
    var onMove: ((CGPoint) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeTracking()
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    func removeTracking() {
        if let area { removeTrackingArea(area) }
        area = nil
    }

    var trackingAreaCount: Int { trackingAreas.count }

    override func mouseEntered(with event: NSEvent) { onPointer?(true) }
    override func mouseExited(with event: NSEvent) { onPointer?(false) }
    override func mouseMoved(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
}

#if DEBUG
extension NotchController {
    /// Debug builds only: draws the real panel (on its real display, with real
    /// data) into PNGs: resting, Quick Peek, each view of the island, plus frames. It renders the
    /// app's own window, so no Screen Recording permission is involved; it
    /// does not show the menu bar or the hardware notch around it.
    public func debugCapture(to directory: URL) async {
        func capture(_ name: String) {
            guard let panel, let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
            let info = "\(name): frame \(NSStringFromRect(panel.frame)) on display \(activeScreen?.name ?? "-") phase \(interaction.phase)\n"
            if let handle = try? FileHandle(forWritingTo: directory.appendingPathComponent("frames.txt")) {
                handle.seekToEndOfFile(); handle.write(Data(info.utf8)); try? handle.close()
            } else {
                try? Data(info.utf8).write(to: directory.appendingPathComponent("frames.txt"))
            }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        capture("notch-resting")
        // Held open for the capture: at launch the main window takes focus,
        // which would (correctly) fold a panel the pointer is not over.
        interaction.isPinned = true
        interaction.pointerEntered()                       // hover → Quick Peek
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        capture("notch-peek")
        interaction.focus()                                // click → expanded Home
        for route in AppModel.IslandRoute.allCases {
            model.route = route
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            capture("notch-\(route.rawValue)")
        }
        model.route = .home
        interaction.isPinned = false
        interaction.close()
        try? await Task.sleep(nanoseconds: 600_000_000)
        capture("notch-after-close")
    }
}
#endif
