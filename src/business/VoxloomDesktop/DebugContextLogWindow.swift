#if DEBUG
import AppKit

@MainActor final class DebugContextLogWindow: NSWindowController {
    private let log: DebugContextLog
    private let output = NSTextView()

    init(log: DebugContextLog) {
        self.log = log
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 470),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "ASR 上下文日志"
        window.minSize = NSSize(width: 360, height: 260)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        output.isEditable = false
        output.isRichText = false
        output.isVerticallyResizable = true
        output.autoresizingMask = [.width]
        output.textContainer?.widthTracksTextView = true
        output.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        output.textContainerInset = NSSize(width: 12, height: 12)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = output

        let note = NSTextField(labelWithString: "仅显示最近一轮，关闭 App 后清除。")
        note.textColor = .secondaryLabelColor
        let clear = NSButton(title: "清空", target: self, action: #selector(clearLog))
        let footer = NSStackView(views: [note, NSView(), clear])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        let stack = NSStackView(views: [scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let content = window.contentView {
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
            ])
        }
        log.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    private func refresh() {
        output.string = log.text
    }

    @objc private func clearLog() { log.clear() }
}
#endif
