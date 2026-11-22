import Foundation

struct DraftTextBuffer: Sendable, Equatable {
    struct Anchors: Sendable {
        let document: UUID
        let identifiers: [Int]
        let preceding: Int?
    }

    private struct Entry: Sendable, Equatable {
        let id: Int
        let character: Character
    }

    private let document = UUID()
    private let hasPreviousSection: Bool
    private var entries: [Entry]
    private var nextID: Int
    private var sectionStart: Int
    private(set) var text: String

    init(previousText: String) {
        text = previousText
        entries = previousText.enumerated().map { Entry(id: $0.offset, character: $0.element) }
        sectionStart = entries.count
        nextID = entries.count
        hasPreviousSection = !entries.isEmpty
    }

    func captureCurrentSection() -> (String, Anchors) {
        var start = sectionStart
        if hasPreviousSection, start < entries.count, entries[start].character.isNewline { start += 1 }
        let tail = entries[start...]
        let preceding = start > 0 ? entries[start - 1].id : nil
        return (String(tail.map(\.character)), Anchors(document: document, identifiers: tail.map(\.id), preceding: preceding))
    }

    mutating func reconcile(_ value: String) {
        guard value != text else { return }
        apply(TextEdit.changes(from: entries.map(\.character), to: Array(value)))
    }

    mutating func apply(_ edits: [TextEdit], at anchors: Anchors) {
        guard anchors.document == document else { return }
        let positions = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })
        let relocated = edits.compactMap { edit -> TextEdit? in
            guard let range = locate(edit.range, in: anchors, using: positions), range.lowerBound >= sectionStart else { return nil }
            return TextEdit(range: range, replacement: edit.replacement)
        }
        apply(relocated)
    }

    private func locate(_ original: Range<Int>, in anchors: Anchors, using positions: [Int: Int]) -> Range<Int>? {
        let ids = anchors.identifiers
        guard original.lowerBound >= 0, original.upperBound <= ids.count else { return nil }
        if !original.isEmpty {
            guard let start = positions[ids[original.lowerBound]], original.count <= entries.count - start else { return nil }
            let range = start..<(start + original.count)
            // Deletion, replacement or a new character inside the span means the released edit conflicts.
            return zip(entries[range], ids[original]).allSatisfy { $0.id == $1 } ? range : nil
        }

        let offset = original.lowerBound
        let left = offset > 0 ? ids[offset - 1] : anchors.preceding
        let right = offset < ids.count ? ids[offset] : nil
        let start: Int
        if let left {
            guard let index = positions[left] else { return nil }
            start = index + 1
        } else {
            start = 0
        }
        if let right {
            guard positions[right] == start else { return nil }
        } else if start != entries.count {
            return nil
        }
        return start..<start
    }

    mutating func apply(_ edits: [TextEdit]) {
        guard !edits.isEmpty else { return }
        for edit in edits.reversed() {
            let startID = nextID
            let replacement = edit.replacement.enumerated().map { Entry(id: startID + $0.offset, character: $0.element) }
            nextID += replacement.count
            if edit.range.lowerBound < sectionStart {
                sectionStart = max(sectionStart - edit.range.upperBound, 0) + edit.range.lowerBound + replacement.count
            }
            entries.replaceSubrange(edit.range, with: replacement)
        }
        text = String(entries.map(\.character))
    }
}
