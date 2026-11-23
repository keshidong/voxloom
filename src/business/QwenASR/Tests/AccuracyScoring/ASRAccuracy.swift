import Foundation

enum AccuracyGroup: String, Codable, Sendable { case zh, en, mixed }

struct AccuracyScore: Codable, Equatable, Sendable {
    let referenceUnits: Int
    let edits: Int
}

enum ASRAccuracy {
    /// Returns unit-cost insertions, deletions and substitutions as a total edit count.
    /// Mandarin uses letter and number graphemes. English uses words. Mixed speech splits
    /// Han characters and uses word units for the remaining text. Han text is simplified
    /// for Mandarin and mixed speech, and case and width are folded for every group.
    /// Punctuation separates words except within contractions and decimal literals.
    /// Number words and written digits retain their literal forms.
    static func score(reference: String, hypothesis: String, group: AccuracyGroup) -> AccuracyScore {
        let expected = units(in: reference, group: group)
        let actual = units(in: hypothesis, group: group)
        return AccuracyScore(referenceUnits: expected.count, edits: editDistance(expected, actual))
    }

    private static func units(in text: String, group: AccuracyGroup) -> [String] {
        let folded = text.folding(options: [.widthInsensitive, .caseInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        switch group {
        case .zh:
            return simplified(folded).filter { $0.isLetter || $0.isNumber }.map(String.init)
        case .en:
            return words(in: folded)
        case .mixed:
            return words(in: separatingHanCharacters(in: simplified(folded)))
        }
    }

    private static func simplified(_ text: String) -> String {
        text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
    }

    private static func separatingHanCharacters(in text: String) -> String {
        var separated = ""
        for character in text {
            let ideographic = character.unicodeScalars.first?.properties.isIdeographic == true
            if ideographic { separated.append(" ") }
            separated.append(character)
            if ideographic { separated.append(" ") }
        }
        return separated
    }

    private static func words(in text: String) -> [String] {
        let normalizedApostrophes = text.replacingOccurrences(of: "’", with: "'")
        return normalizedApostrophes.matches(of: #/\d+(?:\.\d+)+|[\p{L}\p{N}]+(?:'[\p{L}\p{N}]+)*/#)
            .map { String($0.output) }
    }

    static func editDistance<Token: Equatable>(_ expected: [Token], _ actual: [Token]) -> Int {
        var row = Array(0...expected.count)
        for (offset, token) in actual.enumerated() {
            var diagonal = row[0]
            row[0] = offset + 1
            for (index, target) in expected.enumerated() {
                let column = index + 1
                let above = row[column]
                row[column] = min(above + 1, row[index] + 1, diagonal + (token == target ? 0 : 1))
                diagonal = above
            }
        }
        return row[expected.count]
    }
}
