// Probe (Phase 7): which SwiftUI modifiers open an AppKit tooltip window
// (NSToolTipPanel, its own window, able to cover other apps)?
// Run: swiftc scripts/probes/appkit-tooltip.swift -o /tmp/tip && for m in help hint label shortcut menu trunc none; do /tmp/tip $m; done
// Result on macOS 27 (2026-10-31): only `.help` opens one. It moves the
// pointer over its own window for a moment.
import AppKit
import SwiftUI
let mode = CommandLine.arguments[1]
let app = NSApplication.shared
app.setActivationPolicy(.regular)
struct V: View {
    var body: some View {
        let b = Button { } label: { Image(systemName: "gearshape").frame(width: 60, height: 60) }.buttonStyle(.plain)
        Group {
            if mode == "help" { b.help("HELP TIP") }
            else if mode == "hint" { b.accessibilityLabel("Settings").accessibilityHint("HINT TIP") }
            else if mode == "label" { b.accessibilityLabel("Settings") }
            else if mode == "shortcut" { b.accessibilityLabel("Settings").accessibilityHint("H").keyboardShortcut(",", modifiers: .command) }
            else if mode == "menu" { Menu { Button("x") {} } label: { Image(systemName: "ellipsis").frame(width: 60, height: 60) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("More").accessibilityHint("H") }
            else if mode == "trunc" { Text("A very long text that will surely be truncated in this tiny frame").lineLimit(1).frame(width: 60, height: 60) }
            else { b }
        }.frame(width: 200, height: 200)
    }
}
let w = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
w.contentView = NSHostingView(rootView: V())
w.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
    let p = NSPoint(x: 100, y: 100)
    for t in [NSEvent.EventType.mouseMoved, .mouseMoved] {
        let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        app.postEvent(e, atStart: false)
    }
    // Also the real cursor position over the window center:
    let screenPt = w.convertPoint(toScreen: p)
    let h = NSScreen.screens[0].frame.height
    CGWarpMouseCursorPosition(CGPoint(x: screenPt.x, y: h - screenPt.y))
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: screenPt.x, y: h - screenPt.y), mouseButton: .left)?.post(tap: .cghidEventTap)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
    print(mode, app.windows.map { "\(type(of: $0)) visible=\($0.isVisible)" })
    exit(0)
}
app.run()
