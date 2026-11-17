import AppKit
import SwiftUI

/// What the menu-bar bear reports back to the island's controller.
public enum StatusItemEvent: Sendable {
    case entered
    case exited
    case clicked
}

/// The seam between `NotchController` and the real menu-bar item, so tests
/// can run without putting anything in the user's menu bar.
@MainActor
public protocol StatusItemHosting: AnyObject {
    /// Shows or removes the item (it exists only while the bear or an
    /// indicator has something to show).
    func setVisible(_ visible: Bool)
    /// The item's content changed width (an indicator appeared or went).
    func refreshLayout()
    /// Where the bear is on screen (global coordinates), when it is shown.
    var bearCenter: CGPoint? { get }
}

public typealias StatusItemFactory = @MainActor (NotchPresentation, @escaping @MainActor (StatusItemEvent) -> Void) -> any StatusItemHosting

/// Relay the bear as a real menu-bar item (`NSStatusItem`). The bear used to
/// be drawn in a window "ear" over the menu bar, which hid whatever macOS had
/// put next to the notch. A status item takes part in the menu bar's layout
/// (like every other icon), so the other items flow around it and nothing
/// lies behind it. Left click opens the island; the right button (or
/// control-click) shows the app's menu.
@MainActor
public final class RelayStatusItem: NSObject, StatusItemHosting {
    /// One slot: the bear (28 pt at x = 8, y = 2, the pose budget Relay's
    /// bounded resting pose is computed for) or the indicator.
    static let slot: CGFloat = 38
    static let height: CGFloat = 32

    private let presentation: NotchPresentation
    private let onEvent: @MainActor (StatusItemEvent) -> Void
    private let makeMenu: @MainActor () -> NSMenu
    private var item: NSStatusItem?
    private var host: NSHostingView<StatusBearContent>?

    public init(presentation: NotchPresentation, makeMenu: @escaping @MainActor () -> NSMenu,
                onEvent: @escaping @MainActor (StatusItemEvent) -> Void) {
        self.presentation = presentation
        self.makeMenu = makeMenu
        self.onEvent = onEvent
    }

    deinit {
        // `NSStatusBar` is main-thread only; the item is removed in `setVisible(false)`
        // when the controller stops, so there is nothing to do here.
    }

    /// Slots currently shown: the bear and/or the indicator.
    var slots: Int {
        let bear = presentation.showsMascot || { if case .ready = presentation.indicator { return true }; return false }()
        return (bear ? 1 : 0) + (presentation.indicator != .none ? 1 : 0)
    }

    public func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: Self.slot)
            item.autosaveName = "PromptRelayBear"   // the position the user gives it by ⌘-dragging is remembered
            if let button = item.button {
                button.title = ""
                button.target = self
                button.action = #selector(clicked(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                button.setAccessibilityLabel("Prompt Relay")
                let host = NSHostingView(rootView: StatusBearContent(presentation: presentation))
                host.translatesAutoresizingMaskIntoConstraints = false
                button.addSubview(host)
                NSLayoutConstraint.activate([
                    host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                    host.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                    host.heightAnchor.constraint(equalToConstant: Self.height),
                    host.widthAnchor.constraint(equalTo: button.widthAnchor),
                ])
                let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                          owner: self, userInfo: nil)
                button.addTrackingArea(area)
                self.host = host
            }
            self.item = item
            refreshLayout()
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            host = nil
        }
    }

    public func refreshLayout() {
        guard let item else { return }
        let width = Self.slot * CGFloat(max(1, slots))
        if item.length != width { item.length = width }
    }

    public var bearCenter: CGPoint? {
        guard let frame = item?.button?.window?.frame else { return nil }
        // The bear is the first slot, 28 pt at (8, 2) in a 38 × 32 box.
        let originX = frame.minX + RestingPose.origin.x + RestingPose.size / 2
        let centerY = frame.midY
        return CGPoint(x: originX, y: centerY)
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            guard let item else { return }
            item.menu = makeMenu()
            sender.performClick(nil)   // shows the menu under the item
            item.menu = nil            // left clicks go to the action again
        } else {
            onEvent(.clicked)
        }
    }

    @objc func mouseEntered(with event: NSEvent) { onEvent(.entered) }
    @objc func mouseExited(with event: NSEvent) { onEvent(.exited) }
}

/// The item's content: Relay (the same layers as the island's), then the
/// activity indicator on a small black capsule, so it reads on any menu bar.
struct StatusBearContent: View {
    let presentation: NotchPresentation

    var body: some View {
        HStack(spacing: 0) {
            if presentation.showsMascot {
                MascotView(state: presentation.mascot, size: RestingPose.size, reduceMotion: presentation.reduceMotion,
                           resting: true, breathes: presentation.breathes)
                    .frame(width: RestingPose.size, height: RestingPose.size)
                    .padding(.leading, RestingPose.origin.x)
                    .padding(.top, RestingPose.origin.y)
                    .frame(width: RelayStatusItem.slot, height: RelayStatusItem.height, alignment: .topLeading)
            } else if case .ready = presentation.indicator {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: RelayStatusItem.slot, height: RelayStatusItem.height)
            }
            if presentation.indicator != .none {
                ReadyIndicatorView(indicator: presentation.indicator, reduceMotion: presentation.reduceMotion)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black))
                    .frame(width: RelayStatusItem.slot, height: RelayStatusItem.height)
            }
        }
        .frame(height: RelayStatusItem.height)
    }
}
