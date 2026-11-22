import Foundation

public enum DraftSelection {
    /// Moves an AppKit UTF-16 selection with edits made before or within it.
    public static func rebase(_ selection: NSRange, from previous: String, to updated: String) -> NSRange {
        let characters = Array(previous)
        let edits = TextEdit.changes(from: characters, to: Array(updated))
        var utf16Offsets = [0]
        for character in characters {
            utf16Offsets.append(utf16Offsets[utf16Offsets.count - 1] + String(character).utf16.count)
        }
        let length = utf16Offsets[characters.count]
        let start = min(max(selection.location, 0), length)
        let end = start + min(max(selection.length, 0), length - start)

        func map(_ offset: Int, afterInsertionAtOffset: Bool = false) -> Int {
            var shift = 0
            for edit in edits {
                let lower = utf16Offsets[edit.range.lowerBound]
                let upper = utf16Offsets[edit.range.upperBound]
                if offset < lower || (offset == lower && (!edit.range.isEmpty || !afterInsertionAtOffset)) { break }
                let inserted = String(edit.replacement).utf16.count
                if offset < upper { return lower + shift + inserted }
                shift += inserted - (upper - lower)
            }
            return offset + shift
        }

        let location = map(start, afterInsertionAtOffset: start < end)
        return NSRange(location: location, length: map(end) - location)
    }
}
