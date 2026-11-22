import AppKit
import QuartzCore

@MainActor final class VoiceWaveformView: NSView {
    private static let size = NSSize(width: 22, height: 20)
    private static let lineWidth: CGFloat = 2
    private static let spacing: CGFloat = 4
    private static let bars: [(resting: CGFloat, quiet: CGFloat, peak: CGFloat)] = [
        (4, 3, 10), (9, 3.5, 16), (15, 4, 19), (9, 3.5, 14), (4, 3, 9)
    ]
    private static let animationKey = "level"

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        setAccessibilityIdentifier("dictation-waveform")
        wantsLayer = true
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height)
        ])
        update(level: nil, isSample: false)
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer {
        let glyph = CAShapeLayer()
        glyph.lineWidth = Self.lineWidth
        glyph.lineCap = .round
        glyph.fillColor = nil
        return glyph
    }

    /// The level is normalized to 0...1. Nil returns the glyph to its resting shape.
    func update(level: Double?, isSample: Bool) {
        guard let glyph = layer as? CAShapeLayer else { return }
        let tint: NSColor = level != nil && !isSample ? .systemOrange : .systemMint
        let target = makePath(level: level)
        let changed = glyph.path != target
        let previous = glyph.presentation()?.path ?? glyph.path

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.strokeColor = tint.cgColor
        if changed { glyph.path = target }
        CATransaction.commit()

        guard changed else { return }
        glyph.removeAnimation(forKey: Self.animationKey)
        guard let previous, window?.isVisible == true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let movement = CABasicAnimation(keyPath: "path")
        movement.fromValue = previous
        movement.toValue = target
        movement.duration = target.boundingBoxOfPath.height > previous.boundingBoxOfPath.height ? 0.08 : 0.15
        movement.timingFunction = CAMediaTimingFunction(name: .easeOut)
        glyph.add(movement, forKey: Self.animationKey)
    }

    private func makePath(level: Double?) -> CGPath {
        let strength = level.map { CGFloat(min(1, max(0, $0))).squareRoot() }
        let firstX = (Self.size.width - Self.spacing * CGFloat(Self.bars.count - 1)) / 2
        let center = Self.size.height / 2
        let path = CGMutablePath()
        for (index, bar) in Self.bars.enumerated() {
            let height = strength.map { bar.quiet + (bar.peak - bar.quiet) * $0 } ?? bar.resting
            let x = firstX + CGFloat(index) * Self.spacing
            let radius = (height - Self.lineWidth) / 2
            path.move(to: CGPoint(x: x, y: center - radius))
            path.addLine(to: CGPoint(x: x, y: center + radius))
        }
        return path
    }
}
