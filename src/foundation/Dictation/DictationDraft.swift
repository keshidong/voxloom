import Foundation

public struct DictationDraft: Sendable, Equatable {
    public struct CorrectionSnapshot: Sendable {
        public let text: String
        fileprivate let anchors: DraftTextBuffer.Anchors
    }

    public var text: String { buffer.text }
    private let existingText: String
    private var buffer: DraftTextBuffer
    private var raw = ""
    private var spoken = ""

    /// Seeds a new recording with the user's previously visible draft.
    public init(existingText: String = "") {
        self.existingText = existingText
        buffer = DraftTextBuffer(previousText: existingText)
    }

    public mutating func edit(_ text: String, basedOn visibleText: String, replacedRange: NSRange? = nil) {
        if visibleText == self.text, let replacedRange,
           let exactEdit = TextEdit.fromKeyboard(replacedRange, old: visibleText, new: text) {
            buffer.apply([exactEdit])
        } else {
            buffer.reconcile(TextEdit.merge(base: visibleText, preferred: text, incoming: self.text))
        }
    }

    public mutating func recognize(_ snapshot: String) {
        let updated = TextEdit.merge(base: raw, preferred: snapshot, incoming: spoken)
        changeSpeech(to: updated, keepNewClause: true)
        raw = snapshot
    }

    public mutating func correct(_ candidate: CorrectionCandidate) {
        let updated = TextEdit.merge(base: candidate.original, preferred: raw, incoming: candidate.text)
        changeSpeech(to: updated, keepNewClause: false)
    }

    /// Captures the editable portion of this recording and its original character positions.
    public var correctionSnapshot: CorrectionSnapshot {
        let (text, anchors) = buffer.captureCurrentSection()
        return CorrectionSnapshot(text: text, anchors: anchors)
    }

    /// Applies only the changes whose original positions survived typing or new speech.
    public mutating func correct(_ candidate: CorrectionCandidate, basedOn snapshot: CorrectionSnapshot) {
        guard candidate.original == snapshot.text, candidate.text != snapshot.text else { return }
        let original = Array(snapshot.text)
        let changes = candidate.sourceEdits?.flatMap { edit in
            TextEdit.changes(from: Array(original[edit.range]), to: Array(edit.replacement)).map { change in
                let start = edit.range.lowerBound + change.range.lowerBound
                return TextEdit(range: start..<(start + change.range.count), replacement: change.replacement)
            }
        } ?? TextEdit.changes(from: original, to: Array(candidate.text))
        buffer.apply(changes, at: snapshot.anchors)
    }

    private mutating func changeSpeech(to updated: String, keepNewClause: Bool) {
        buffer.reconcile(TextEdit.merge(base: joinedSpeech(spoken), preferred: text,
                                        incoming: joinedSpeech(updated), keepNewClause: keepNewClause))
        spoken = updated
    }

    private func joinedSpeech(_ speech: String) -> String {
        guard !existingText.isEmpty else { return speech }
        guard !speech.isEmpty else { return existingText }
        let separator = existingText.last?.isNewline == true || speech.first?.isNewline == true ? "" : "\n"
        return existingText + separator + speech
    }
}

struct TextEdit: Sendable, Equatable {
    let range: Range<Int>
    let replacement: [Character]

    static func fromKeyboard(_ range: NSRange, old: String, new: String) -> Self? {
        guard let replaced = Range(range, in: old) else { return nil }
        let prefix = old[..<replaced.lowerBound]
        let suffix = old[replaced.upperBound...]
        guard new.hasPrefix(prefix), new.hasSuffix(suffix), new.count >= prefix.count + suffix.count else { return nil }
        let replacement = new.dropFirst(prefix.count).dropLast(suffix.count)
        guard replacement != old[replaced] else { return nil }
        return Self(range: prefix.count..<(old.count - suffix.count), replacement: Array(replacement))
    }

    static func merge(base: String, preferred: String, incoming: String, keepNewClause: Bool = false) -> String {
        if base == preferred { return incoming }
        if base == incoming || preferred == incoming { return preferred }

        let source = Array(base)
        let accepted = changes(from: source, to: Array(preferred))
        var other = changes(from: source, to: Array(incoming))
        if keepNewClause, let tail = other.last, tail.range.upperBound == source.count,
           !tail.range.isEmpty, let boundary = tail.replacement.firstIndex(where: { "，。！？；,.!?;\n".contains($0) }),
           boundary > 0 {
            // A new clause can arrive in the same snapshot as a revised final word.
            other.removeLast()
            other.append(Self(range: tail.range, replacement: Array(tail.replacement[..<boundary])))
            other.append(Self(range: source.count..<source.count, replacement: Array(tail.replacement[boundary...])))
        }
        let edits = (accepted + other.filter { edit in
            !accepted.contains { $0 == edit || $0.conflicts(with: edit) }
        }).sorted {
            if $0.range.lowerBound != $1.range.lowerBound { return $0.range.lowerBound < $1.range.lowerBound }
            return $0.range.isEmpty && !$1.range.isEmpty
        }
        var cursor = 0
        var result = ""
        for edit in edits {
            result.append(contentsOf: source[cursor..<edit.range.lowerBound])
            result.append(contentsOf: edit.replacement)
            cursor = edit.range.upperBound
        }
        result.append(contentsOf: source[cursor...])
        return result
    }

    private func conflicts(with other: Self) -> Bool {
        if range.isEmpty { return other.range.lowerBound < range.lowerBound && range.lowerBound < other.range.upperBound }
        if other.range.isEmpty { return other.conflicts(with: self) }
        return range.overlaps(other.range)
    }

    static func changes(from old: [Character], to new: [Character]) -> [Self] {
        let prefix = zip(old, new).prefix { $0 == $1 }.count
        let suffix = zip(old.dropFirst(prefix).reversed(), new.dropFirst(prefix).reversed()).prefix { $0 == $1 }.count
        let oldMiddle = Array(old[prefix..<(old.count - suffix)])
        let newMiddle = Array(new[prefix..<(new.count - suffix)])
        guard !oldMiddle.isEmpty || !newMiddle.isEmpty else { return [] }
        if oldMiddle.isEmpty || newMiddle.isEmpty || newMiddle.count > 1_000_000 / oldMiddle.count {
            return [Self(range: prefix..<(old.count - suffix), replacement: newMiddle)]
        }
        return middleChanges(from: oldMiddle, to: newMiddle, offset: prefix)
    }

    private static func middleChanges(from old: [Character], to new: [Character], offset: Int) -> [Self] {
        let difference = new.difference(from: old)
        var removals = Set<Int>()
        var insertions = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }
        var edits: [Self] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if removals.contains(oldIndex) || insertions.contains(newIndex) {
                let start = oldIndex
                let replacementStart = newIndex
                while removals.contains(oldIndex) { oldIndex += 1 }
                while insertions.contains(newIndex) { newIndex += 1 }
                edits.append(Self(range: (offset + start)..<(offset + oldIndex), replacement: Array(new[replacementStart..<newIndex])))
            } else {
                oldIndex += 1
                newIndex += 1
            }
        }
        return edits
    }
}
