import Foundation
import NaturalLanguage
import SpeechFoundation

enum MandarinContextTerms {
    private struct Sound {
        let syllables: [Substring]
        let key: String

        init?(_ word: String) {
            guard word.count >= 2, word.range(of: #"^\p{Han}+$"#, options: .regularExpression) != nil,
                  let pinyin = CorrectionPrompt.pronunciation(of: word) else { return nil }
            let folded = pinyin.folding(options: .diacriticInsensitive, locale: nil)
            syllables = folded.split(separator: " ")
            key = folded.replacingOccurrences(of: #"(?<!\S)([zcs])h"#, with: "$1", options: .regularExpression)
        }

        func close(to other: Sound) -> Bool {
            zip(syllables, other.syllables).lazy.filter { $0.0 != $0.1 }.prefix(2).count <= 1
        }
    }

    private struct Term {
        let text: String
        let sound: Sound
    }

    private static let chineseNumerals = CharacterSet(charactersIn: "零〇一二两三四五六七八九十百千万亿点")

    static func annotate(_ transcript: String, context: String) -> (transcript: String, matches: [String: [String]]) {
        guard !context.isEmpty else { return (transcript, [:]) }
        var termsBySound: [String: [Term]] = [:]
        var distinct: Set<String> = []
        for word in windowTerms(context) {
            guard distinct.insert(word).inserted, let sound = Sound(word) else { continue }
            termsBySound[sound.key, default: []].append(Term(text: word, sound: sound))
        }
        guard !termsBySound.isEmpty else { return (transcript, [:]) }

        var annotated = ""
        var start = transcript.startIndex
        var count = 0
        var matches: [String: [String]] = [:]
        for range in draftRanges(transcript) where range.lowerBound >= start {
            let draft = String(transcript[range])
            guard !draft.unicodeScalars.allSatisfy(chineseNumerals.contains) else { continue }
            guard let sound = Sound(draft), let terms = termsBySound[sound.key] else { continue }
            let candidates = terms.filter { $0.text != draft && sound.close(to: $0.sound) }
            let exact = candidates.filter { $0.sound.syllables == sound.syllables }
            let similar = candidates.filter { $0.sound.syllables != sound.syllables }
            let alternatives = (exact + similar).prefix(3).map(\.text)
            guard !alternatives.isEmpty else { continue }
            annotated += transcript[start..<range.lowerBound]
            annotated += "〔" + (alternatives + [draft]).joined(separator: "／") + "〕"
            start = range.upperBound
            matches[draft] = alternatives
            count += 1
            if count == 8 { break }
        }
        annotated += transcript[start...]
        return (annotated, matches)
    }

    private static func windowTerms(_ context: String) -> [String] {
        let words = context.split(whereSeparator: \.isWhitespace)
        let joined = zip(words, words.dropFirst()).compactMap { pair -> String? in
            let (left, right) = pair
            guard left.count == 1, right.count == 1 else { return nil }
            return String(left) + String(right)
        }
        return words.reversed().map(String.init) + Array(joined.reversed())
    }

    private static func draftRanges(_ transcript: String) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = transcript
        let tokens = tokenizer.tokens(for: transcript.startIndex..<transcript.endIndex)
        return tokens.indices.flatMap { index -> [Range<String.Index>] in
            let current = tokens[index]
            guard index + 1 < tokens.count else { return [current] }
            let next = tokens[index + 1]
            guard current.upperBound == next.lowerBound,
                  transcript[current].count == 1, transcript[next].count == 1 else { return [current] }
            return [current.lowerBound..<next.upperBound, current]
        }
    }
}
