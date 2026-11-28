#if DEBUG
import AppKit

@MainActor final class OmniContextPreview {
    private var latest = "提交一次 Omni 复核后，这里会显示该轮送入模型的目标窗口词汇。"
    private var output: NSTextView?
    private lazy var window = makeWindow()

    func record(_ text: String) {
        latest = text.isEmpty ? "本轮没有读到目标窗口的有效词汇。" : text
        output?.string = latest
    }

    private func makeWindow() -> NSWindow {
        let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 360),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        preview.title = "最近一次 Omni 上下文"
        preview.isReleasedWhenClosed = false
        preview.center()
        let text = NSTextView.scrollableTextView()
        let document = text.documentView as? NSTextView
        document?.isEditable = false
        document?.isRichText = false
        document?.allowsUndo = false
        document?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        document?.layoutManager?.allowsNonContiguousLayout = true
        document?.textContainerInset = NSSize(width: 12, height: 12)
        document?.string = latest
        output = document
        preview.contentView = text
        return preview
    }

    func show() { window.makeKeyAndOrderFront(nil) }
}
#endif
