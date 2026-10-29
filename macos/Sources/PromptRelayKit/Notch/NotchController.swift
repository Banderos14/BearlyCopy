import AppKit
import Observation
import SwiftUI

/// What the SwiftUI notch content needs to draw itself; owned by the controller.
@MainActor
@Observable
public final class NotchPresentation {
    public internal(set) var isExpanded = false
    public internal(set) var isFocused = false
    public internal(set) var reduceMotion = false
    /// Size of the camera housing on the active display.
    public internal(set) var notchSize = CGSize(width: 185, height: 32)
    /// Width of the expanded island on the active display.
    public internal(set) var islandWidth = NotchLayout.expandedWidth
    /// Height the expanded content needs (measured by the view); the island
    /// and its window follow it, so there is never empty space below.
    public internal(set) var contentHeight: CGFloat = NotchLayout.minContentHeight
    /// Show the small "answer ready" ears beside the notch.
    public internal(set) var showsIndicator = false
    var onContentHeight: ((CGFloat) -> Void)?

    public init() {}

    /// Called by the view when its content size changes.
    func reportContentHeight(_ height: CGFloat) {
        let clamped = min(max(height.rounded(.up), NotchLayout.minContentHeight), NotchLayout.maxContentHeight)
        guard abs(clamped - contentHeight) >= 1 else { return }
        contentHeight = clamped
        onContentHeight?(clamped)
    }

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
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier.map(Self.bundleIDs.contains) ?? false }
            .map { $0.localizedName ?? $0.bundleIdentifier ?? "another notch app" }
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
    public private(set) var neighborNames: [String] = []

    private let model: AppModel
    private let settings: NotchSettings
    private let screens: ScreenProviding
    private let center: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let actions: SurfaceActions
    private let makeHotKey: @MainActor () -> HotKeyRegistration?
    private let neighbors: NotchNeighbors
    private var panel: NotchPanel?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var hotKey: HotKeyRegistration?
    private var collapseWork: DispatchWorkItem?
    private var observingModel = false

    public init(model: AppModel, settings: NotchSettings, actions: SurfaceActions,
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
        interaction = NotchInteraction(scheduler: scheduler ?? MainQueueScheduler())
        interaction.onChange = { [weak self] phase, old in self?.apply(phase, from: old) }
        presentation.onContentHeight = { [weak self] _ in self?.fitExpandedFrame() }
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
        let screen = DisplayChoice.pick(settings.display, from: screens.screens)
        guard let screen, let newLayout = NotchLayout(screen: screen) else {
            // No notch on the chosen display: the menu-bar item stays the way in.
            activeScreen = nil
            layout = nil
            interaction.setAvailable(false)
            return
        }
        let moved = activeScreen?.displayID != screen.displayID || layout != newLayout
        activeScreen = screen
        layout = newLayout
        neighborNames = neighbors.running
        let yielding = settings.yieldToOtherNotchApps && !neighborNames.isEmpty
        let yieldChanged = yielding != isYielding
        isYielding = yielding
        presentation.notchSize = newLayout.notch.size
        presentation.islandWidth = newLayout.expandedIslandWidth
        presentation.reduceMotion = settings.reducesMotion(systemReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        ensurePanel()
        if interaction.phase == .hidden {
            interaction.setAvailable(true)
        } else if moved || yieldChanged {
            interaction.close()
            placePanel(for: interaction.phase)
        } else {
            panel?.orderFrontRegardless()
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NotchPanel()
        let root = NotchRootView(model: model, presentation: presentation, interaction: interaction, actions: actions)
        panel.install(root: root)
        panel.onPointer = { [weak self] inside in
            guard let self else { return }
            if inside { self.interaction.pointerEntered() } else { self.interaction.pointerExited() }
        }
        panel.onResignKey = { [weak self] in self?.interaction.focusLost() }
        panel.onCancel = { [weak self] in self?.interaction.close() }
        panel.onKey = { [weak self] key in self?.handleKey(key) ?? false }
        self.panel = panel
    }

    private func compactFrame() -> CGRect? {
        guard let layout else { return nil }
        return presentation.showsIndicator ? layout.compact : layout.notch
    }

    private func placePanel(for phase: NotchInteraction.Phase) {
        guard let panel, let layout else { return }
        switch phase {
        case .hidden:
            panel.orderOut(nil)
        case .compact:
            if let frame = compactFrame() { panel.setFrame(frame, display: true) }
            if isYielding { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        case .expanded:
            panel.setFrame(layout.expandedFrame(contentHeight: presentation.contentHeight), display: true)
            panel.orderFrontRegardless()
        }
    }

    /// The expanded content changed height: keep the window exactly as tall
    /// as the island (anchored at the top edge).
    private func fitExpandedFrame() {
        guard interaction.phase.isExpanded, let panel, let layout else { return }
        let frame = layout.expandedFrame(contentHeight: presentation.contentHeight)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    // MARK: Phases

    private func apply(_ phase: NotchInteraction.Phase, from old: NotchInteraction.Phase) {
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

    /// ← → move to older / newer answers, Return copies the shown one.
    private func handleKey(_ key: NotchPanel.Key) -> Bool {
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
            (model.hasUnseenAnswer, model.pendingSensitiveContext != nil)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.track() } }
        }
        let showIndicator = unseen.0
        if presentation.showsIndicator != showIndicator {
            withAnimation(presentation.animation) { presentation.showsIndicator = showIndicator }
            if interaction.phase == .compact { placePanel(for: .compact) }
        }
        interaction.isPinned = unseen.1
    }
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
        animationBehavior = .none
        setAccessibilityLabel("Prompt Relay notch")
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
        container.addSubview(host)
        host.frame = container.bounds
        contentView = container
        tracking = container
    }

    func tearDown() {
        tracking?.removeTracking()
        tracking?.onPointer = nil
        onPointer = nil; onResignKey = nil; onCancel = nil; onKey = nil
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
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeTracking()
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
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
}

#if DEBUG
extension NotchController {
    /// Debug builds only: draws the real panel (on its real display, with real
    /// data) into PNGs, compact then expanded, plus its frames. It renders the
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
        interaction.toggle()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        capture("notch-expanded")
        interaction.isPinned = false
        interaction.close()
        try? await Task.sleep(nanoseconds: 600_000_000)
        capture("notch-after-close")
    }
}
#endif
