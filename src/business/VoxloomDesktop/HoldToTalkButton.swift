import AppKit

/// Reports the whole mouse press, including a release outside the control.
@MainActor final class HoldToTalkButton: NSButton {
    var onPressChanged: ((Bool, TimeInterval) -> Void)?
    var onCancelPress: (() -> Void)?
    private var isPressed = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        title = ""
        bezelStyle = .circular
        setAccessibilityLabel("按住说话")
        toolTip = "用鼠标按住说话，松开结束"
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !isPressed else { return }
        isPressed = true
        highlight(true)
        onPressChanged?(true, event.timestamp)
    }

    override func mouseDragged(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard endPress() else { return }
        onPressChanged?(false, event.timestamp)
    }

    func cancelPress() {
        if endPress() { onCancelPress?() }
    }

    private func endPress() -> Bool {
        guard isPressed else { return false }
        isPressed = false
        highlight(false)
        return true
    }
}
