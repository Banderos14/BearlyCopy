// Probe (Phase 7): does a `.fill` thumbnail, clipped, take clicks only
// inside its visible frame? Run: swiftc scripts/probes/thumbnail-hit.swift -o /tmp/thumb && /tmp/thumb && /tmp/thumb fixed
// Result on macOS 27 (2026-10-31): without `.contentShape` the clicks on the
// thumbnails did not open the image under the cursor; with it, every click
// opened the right one. Synthetic events go to a key window of this process only.
import AppKit
import SwiftUI
final class K: NSWindow { override var canBecomeKey: Bool { true } }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var hits: [String] = []
let fixed = CommandLine.arguments.count > 1
let img: NSImage = { let i = NSImage(size: NSSize(width: 800, height: 160)); i.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 800, height: 160).fill(); i.unlockFocus(); return i }()
struct Thumb: View {
    let i: Int
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let label = Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            .frame(width: 96, height: 64).background(Color.gray).clipped().clipShape(shape)
        return Button { hits.append("open\(i)") } label: {
            if fixed { label.contentShape(shape) } else { label }
        }.buttonStyle(.plain)
    }
}
struct V: View {
    var body: some View {
        HStack(spacing: 8) { ForEach(0..<3) { Thumb(i: $0) } }.frame(width: 320, height: 64, alignment: .leading)
    }
}
let w = K(contentRect: NSRect(x: 0, y: 0, width: 320, height: 64), styleMask: [.borderless], backing: .buffered, defer: false)
w.contentView = NSHostingView(rootView: V())
w.makeKeyAndOrderFront(nil)
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
// thumb 0: x 0…96, thumb 1: 104…200. Click inside thumb 0 near its right edge, and its centre.
for x in [5.0, 48.0, 90.0, 94.0, 110.0, 150.0, 196.0] {
    hits.append("@\(Int(x))")
    for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        w.sendEvent(NSEvent.mouseEvent(with: t, location: NSPoint(x: x, y: 32), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
}
print(fixed ? "with contentShape:" : "Phase 6 code:   ", hits.joined(separator: " "))
