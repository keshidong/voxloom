import AppKit

@MainActor final class DraftEditor: NSTextView, NSTextViewDelegate {
    var onEdit: ((String, String, NSRange?) -> Void)?
    private var presentedText = ""
    private var presenting = false
    private var keyboardRange: NSRange?

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if !presenting, !textView.hasMarkedText(), textView.string == presentedText {
            keyboardRange = replacementString == nil ? nil : affectedCharRange
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        if !hasMarkedText() { sendEdit() }
    }

    func finishKeyboardEdit() {
        if hasMarkedText() { unmarkText() }
        sendEdit()
    }

    private func sendEdit() {
        guard !presenting else { return }
        let range = keyboardRange
        keyboardRange = nil
        if string != presentedText { onEdit?(string, presentedText, range) }
    }

    func present(_ text: String) {
        guard !hasMarkedText() else { return }
        presentedText = text
        guard string != text else { return }

        // Update the storage without moving the user's insertion point to the start.
        let old = Array(string)
        let new = Array(text)
        let prefix = zip(old, new).prefix { $0.0 == $0.1 }.count
        let suffix = zip(old.dropFirst(prefix).reversed(), new.dropFirst(prefix).reversed())
            .prefix { $0.0 == $0.1 }.count
        let removed = String(old[prefix..<(old.count - suffix)])
        let inserted = String(new[prefix..<(new.count - suffix)])
        let range = NSRange(location: String(old.prefix(prefix)).utf16.count, length: removed.utf16.count)
        let selection = selectedRange()
        let start = adjusted(selection.location, replacing: range, with: inserted.utf16.count)
        let end = adjusted(NSMaxRange(selection), replacing: range, with: inserted.utf16.count)
        presenting = true
        textStorage?.replaceCharacters(in: range, with: inserted)
        setSelectedRange(NSRange(location: start, length: end - start))
        presenting = false
    }

    private func adjusted(_ offset: Int, replacing range: NSRange, with length: Int) -> Int {
        if offset <= range.location { return offset }
        if offset >= NSMaxRange(range) { return offset - range.length + length }
        return range.location + length
    }
}
