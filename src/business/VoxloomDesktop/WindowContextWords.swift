import Foundation
import NaturalLanguage

enum WindowContextWords {
    private static let formattingPatterns = [
        #"\x1B(?:\][^\x07\x1B]*(?:\x07|\x1B\\)|\[[0-?]*[ -/]*[@-~])"#,
        #"(?ms)^[\t ]*(?:`{3,}|~{3,})[^\r\n]*(?:\R|\z).*?(?:^[\t ]*(?:`{3,}|~{3,})[\t ]*(?:\R|\z)|\z)"#,
        #"`+[^`\r\n]*`+|<[^<>\r\n]+>|(?<=\])\([^)\r\n]*\)|https?://[^\s<>()]+"#,
        #"(?<![\p{L}\p{N}_])(?:(?:export|const|let|var)[ \t]+)?[A-Za-z_][A-Za-z0-9_.]*[ \t]*=(?!=)[ \t]*(?:"(?:\\.|[^"\\\r\n])*"|'[^'\r\n]*'|[^\s,;]+)?"#,
        #"\$\{[^{}\r\n]*\}|\$[A-Za-z_][A-Za-z0-9_]*"#,
        #"(?<![\p{L}\p{N}_])[A-Za-z0-9]+(?:_[A-Za-z0-9_]+)+"#,
        #"(?<![\p{L}\p{N}_])(?:~?/|\.{1,2}/)[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*"#
    ]

    static func recent(in text: String) -> String {
        let cleaned = formattingPatterns.reduce(text) { text, pattern in
            text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = cleaned
        var words: [Substring] = []
        var previousEnd = cleaned.startIndex
        for range in tokenizer.tokens(for: cleaned.startIndex..<cleaned.endIndex) {
            // The tokenizer can skip letters in mixed-language text.
            words.append(contentsOf: wordsInGap(cleaned[previousEnd..<range.lowerBound]))
            let word = cleaned[range]
            if word.contains(where: \.isLetter) { words.append(word) }
            previousEnd = range.upperBound
        }
        words.append(contentsOf: wordsInGap(cleaned[previousEnd...]))
        return words.suffix(300).joined(separator: " ")
    }

    private static func wordsInGap(_ text: Substring) -> [Substring] {
        text.split { !$0.isLetter && !$0.isNumber }.filter { $0.contains(where: \.isLetter) }
    }
}
