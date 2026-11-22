import AppKit
import Carbon

@MainActor final class SystemPaste {
    private let board: NSPasteboard
    private let post: (CGEvent, pid_t) -> Void
    private var restoreTask: Task<Void, Never>?
    private var snapshot: [[NSPasteboard.PasteboardType: Data]] = []
    private var temporaryChange: Int?

    init(board: NSPasteboard = .general, post: @escaping (CGEvent, pid_t) -> Void = { $0.postToPid($1) }) {
        self.board = board
        self.post = post
    }

    static func foregroundTarget() -> pid_t? {
        guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return app.processIdentifier
    }

    func paste(_ text: String, to pid: pid_t) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        guard stageClipboard(text) else { return false }
        post(down, pid)
        post(up, pid)
        return true
    }

    // Preserve existing representations when the pasteboard still belongs to this insertion.
    func stageClipboard(_ text: String) -> Bool {
        restoreTask?.cancel()
        if board.changeCount != temporaryChange {
            snapshot = (board.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
            }
        }
        board.clearContents()
        let written = board.setString(text, forType: .string)
        temporaryChange = board.changeCount
        if !written { restoreClipboard(); return false }
        restoreTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            self?.restoreClipboard()
        }
        return true
    }

    func restoreClipboard() {
        restoreTask?.cancel()
        restoreTask = nil
        defer { snapshot = []; temporaryChange = nil }
        guard board.changeCount == temporaryChange else { return }
        let items = snapshot.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        board.clearContents()
        if !items.isEmpty { board.writeObjects(items) }
    }
}
