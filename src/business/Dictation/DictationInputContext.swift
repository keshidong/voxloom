import Foundation
import NaturalLanguage
import SpeechFoundation

/// A single, local snapshot shared by the recognizer and corrector for one hold.
struct DictationInputContext: Sendable {
    private let snapshot: Task<Hints, Never>

    init(read: @escaping @Sendable () async -> String) {
        snapshot = Task.detached(priority: .userInitiated) {
            let text = await read()
            return Task.isCancelled ? Hints("") : Hints(text)
        }
    }

    func cancel() { snapshot.cancel() }

    func recognizer(_ provider: any SpeechRecognizer) -> any SpeechRecognizer {
        ContextualRecognizer(provider: provider, snapshot: snapshot)
    }

    func corrector(_ provider: any TextCorrecting) -> any TextCorrecting {
        ContextualCorrector(provider: provider, snapshot: snapshot)
    }

    private struct Hints: Sendable {
        let text: String
        let terms: String

        init(_ excerpt: String) {
            let bounded = String(decoding: excerpt.utf8.prefix(720), as: UTF8.self)
            let text = bounded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            self.text = text
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = text
            var words: [String] = []
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let word = text[range]
                if (2...28).contains(word.count), word.first?.isLetter == true,
                   word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    words.append(String(word))
                }
                return true
            }
            var seen = Set<String>()
            terms = words.reversed().filter { seen.insert($0).inserted }.prefix(16).reversed().joined(separator: " ")
        }
    }

    private struct ContextualRecognizer: SpeechRecognizer {
        let provider: any SpeechRecognizer
        let snapshot: Task<Hints, Never>

        func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
            let terms = await snapshot.value.terms
            try Task.checkCancellation()
            let hint = [options.context, terms].filter { !$0.isEmpty }.joined(separator: "\n")
            let merged = hint.utf8.count <= 4096 ? hint : options.context
            return try await provider.transcribe(audio, options: .init(language: options.language, context: merged))
        }

        func shutdown() async { await provider.shutdown() }
    }

    private struct ContextualCorrector: TextCorrecting {
        let provider: any TextCorrecting
        let snapshot: Task<Hints, Never>

        func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
            let excerpt = await snapshot.value.text
            try Task.checkCancellation()
            return try await provider.correct(.init(text: request.text, vocabulary: request.vocabulary,
                                                    surroundingText: excerpt))
        }
    }
}
