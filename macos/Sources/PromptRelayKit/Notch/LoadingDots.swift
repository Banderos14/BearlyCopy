import AppKit
import QuartzCore
import SwiftUI

/// Phase 9.4: three small dots that grow and fade in turn while an agent
/// works. Core Animation keyframes run in the render server, so the app does
/// no per-frame work; the animation ends when the dots leave the screen.
/// Reduce Motion: still dots, nothing animates.
struct LoadingDots: NSViewRepresentable {
    var color: NSColor
    var reduceMotion: Bool
    static let dot: CGFloat = 3.5
    static let gap: CGFloat = 2.5
    static let period: CFTimeInterval = 1.2
    static var size: CGSize { CGSize(width: dot * 3 + gap * 2, height: dot * 1.6) }

    func makeNSView(context: Context) -> DotsView { DotsView() }

    func updateNSView(_ view: DotsView, context: Context) {
        view.configure(color: color, reduceMotion: reduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DotsView, context: Context) -> CGSize? { Self.size }

    final class DotsView: NSView {
        private var dots: [CALayer] = []
        private(set) var animating = false
        private var configured: (NSColor, Bool)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for _ in 0..<3 {
                let dot = CALayer()
                dot.cornerRadius = LoadingDots.dot / 2
                layer?.addSublayer(dot)
                dots.append(dot)
            }
        }

        required init?(coder: NSCoder) { nil }

        override var intrinsicContentSize: NSSize { LoadingDots.size }

        override func layout() {
            super.layout()
            let y = (bounds.height - LoadingDots.dot) / 2
            for (i, dot) in dots.enumerated() {
                dot.frame = CGRect(x: CGFloat(i) * (LoadingDots.dot + LoadingDots.gap), y: y,
                                   width: LoadingDots.dot, height: LoadingDots.dot)
            }
        }

        func configure(color: NSColor, reduceMotion: Bool) {
            if let configured, configured.0 == color, configured.1 == reduceMotion { return }
            configured = (color, reduceMotion)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for dot in dots { dot.backgroundColor = color.cgColor; dot.removeAllAnimations() }
            CATransaction.commit()
            animating = false
            guard !reduceMotion else {
                for dot in dots { dot.opacity = 0.7 }
                return
            }
            let now = CACurrentMediaTime()
            for (i, dot) in dots.enumerated() {
                dot.opacity = 0.45
                let scale = CAKeyframeAnimation(keyPath: "transform.scale")
                scale.values = [1.0, 1.45, 1.0, 1.0]
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0.45, 1.0, 0.45, 0.45]
                let group = CAAnimationGroup()
                group.animations = [scale, fade]
                for a in [scale, fade] {
                    a.keyTimes = [0, 0.25, 0.5, 1]
                    a.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
                }
                group.duration = LoadingDots.period
                group.repeatCount = .infinity
                group.beginTime = now + Double(i) * LoadingDots.period / 6
                group.fillMode = .backwards
                dot.add(group, forKey: "loading")
            }
            animating = true
        }
    }
}
