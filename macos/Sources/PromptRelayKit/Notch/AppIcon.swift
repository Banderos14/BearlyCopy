import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Phase 16: Prompt Relay's application icon (Finder, Applications,
/// Launchpad, Spotlight, Privacy & Security lists) and its menu-bar mark.
///
/// Drawn from Relay's own vector geometry — `MascotView.shapes`, the same
/// bear the notch shows — never from a screenshot. `scripts/make-app-icon.sh`
/// renders every macOS size from this code into `macos/Resources/AppIcon.icns`,
/// which the Xcode target and `scripts/build-macos-app.sh` both bundle; a
/// test checks the committed file still matches this drawing.
@MainActor
public enum AppIcon {
    /// The `.iconset` entries `iconutil` needs: file name and pixel size.
    public static let iconsetEntries: [(name: String, pixels: Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]

    /// Apple's macOS icon grid on a 1024 canvas: an 824-pixel rounded square
    /// 100 pixels in from each edge (room for the system's shadow).
    static let tileInset: CGFloat = 100.0 / 1024
    static let tileRadius: CGFloat = 185.0 / 1024
    /// Relay's drawing size relative to the canvas; its ears and head span
    /// 0.9 of that, so the bear fills about 68 % of the tile.
    static let bearScale: CGFloat = 0.61
    /// Where the centre of the bear's silhouette sits (y down, of the canvas).
    static let bearCentre = CGPoint(x: 0.5, y: 0.515)

    /// The warm night of the notch island, so the icon reads as "the bear at
    /// the notch": a dark tile, lighter at the top.
    static let tileTop = CGColor(srgbRed: 0.24, green: 0.20, blue: 0.17, alpha: 1)
    static let tileBottom = CGColor(srgbRed: 0.10, green: 0.08, blue: 0.07, alpha: 1)

    /// One square sRGB rendering of the icon, `pixels` wide.
    public static func render(pixels: Int) -> CGImage? {
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let n = CGFloat(pixels)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        ctx.clear(CGRect(x: 0, y: 0, width: n, height: n))
        // Draw in y-down coordinates, like Relay's own geometry.
        ctx.translateBy(x: 0, y: n)
        ctx.scaleBy(x: 1, y: -1)

        let inset = tileInset * n
        let tile = CGRect(x: inset, y: inset, width: n - 2 * inset, height: n - 2 * inset)
        let tilePath = RoundedRectangle(cornerRadius: tileRadius * n, style: .continuous).path(in: tile).cgPath

        // A soft shadow under the tile, as macOS icons have.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 0.012 * n), blur: 0.024 * n,
                      color: CGColor(gray: 0, alpha: 0.32))
        ctx.addPath(tilePath)
        ctx.setFillColor(tileBottom)
        ctx.fillPath()
        ctx.restoreGState()

        // The tile: a vertical gradient, a faint warm glow behind the bear.
        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.clip()
        if let gradient = CGGradient(colorsSpace: space, colors: [tileTop, tileBottom] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
        }
        if let glow = CGGradient(colorsSpace: space,
                                 colors: [MascotView.fur.copy(alpha: 0.22)!, MascotView.fur.copy(alpha: 0)!] as CFArray,
                                 locations: [0, 1]) {
            let c = CGPoint(x: bearCentre.x * n, y: bearCentre.y * n)
            ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: 0.42 * n, options: [])
        }
        ctx.restoreGState()

        // A hairline highlight along the tile's top edge (only where it adds detail).
        if pixels >= 64 {
            ctx.saveGState()
            ctx.addPath(tilePath)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
            ctx.setLineWidth(max(1, 0.004 * n))
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Relay: the notch bear's own shapes, smiling, looking at you.
        let s = bearScale * n
        let origin = CGPoint(x: bearCentre.x * n - 0.5 * s, y: bearCentre.y * n - 0.48 * s)
        let shapes = MascotView.shapes(size: CGSize(width: s, height: s), mood: .idle, gaze: .zero, expression: .smile)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 0.010 * n), blur: 0.03 * n, color: CGColor(gray: 0, alpha: 0.45))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.translateBy(x: origin.x, y: origin.y)
        for shape in shapes { draw(shape, in: ctx) }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        return ctx.makeImage()
    }

    static func draw(_ shape: RelayShape, in ctx: CGContext) {
        ctx.addPath(shape.path)
        if let width = shape.lineWidth {
            ctx.setStrokeColor(shape.color)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.strokePath()
        } else {
            ctx.setFillColor(shape.color)
            ctx.fillPath()
        }
    }

    /// PNG bytes of `render(pixels:)` (sRGB, with alpha).
    public static func pngData(pixels: Int) -> Data? {
        guard let image = render(pixels: pixels) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Writes every `.iconset` PNG into `folder` (created if needed).
    public static func writeIconset(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for entry in iconsetEntries {
            guard let data = pngData(pixels: entry.pixels) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: entry.name])
            }
            try data.write(to: folder.appendingPathComponent(entry.name), options: .atomic)
        }
    }

    // MARK: Menu bar

    /// Relay's silhouette as a template image for the menu bar (ears and
    /// head; eyes and nose cut out), so the menu-bar item is recognisably
    /// Prompt Relay in light and dark menu bars.
    public static func menuBarImage(points: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: points, height: points), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width * 1.06
            ctx.translateBy(x: (rect.width - s) / 2, y: (rect.height - s) / 2 + rect.height * 0.02)
            let parts = MascotView.shapes(size: CGSize(width: s, height: s), mood: .idle, gaze: .zero)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            // Ears (outer discs) and head: parts 0, 2 and 4.
            for index in [0, 2, 4] where index < parts.count {
                ctx.addPath(parts[index].path)
                ctx.fillPath()
            }
            // Cut the eyes and the nose out of the silhouette.
            ctx.setBlendMode(.clear)
            let s2 = s
            for (x, y, w, h) in [(0.335, 0.45, 0.15, 0.17), (0.665, 0.45, 0.15, 0.17), (0.5, 0.612, 0.19, 0.13)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                ctx.fillEllipse(in: CGRect(x: (x - w / 2) * s2, y: (y - h / 2) * s2, width: w * s2, height: h * s2))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Prompt Relay"
        return image
    }
}
