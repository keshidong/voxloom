import Foundation
import NaturalLanguage
import SpeechFoundation

public struct DictationContextSnapshot: Sendable {
    public let draft: String
    /// Text from the current conversation, in chronological order.
    public let recentMessages: [String]

    public init(draft: String = "", recentMessages: [String] = []) {
        self.draft = draft
        self.recentMessages = recentMessages
    }
}

/// A single, local snapshot shared by the recognizer and corrector for one hold.
struct DictationInputContext: Sendable {
    private let snapshot: Task<Hints, Never>?
    private let promptByteLimit: Int?

    init(read: (@Sendable () async -> DictationContextSnapshot)?, promptByteLimit: Int?) {
        snapshot = read.map { read in
            Task.detached(priority: .userInitiated) {
                let context = await read()
                return Hints(Task.isCancelled ? .init() : context)
            }
        }
        self.promptByteLimit = promptByteLimit
    }

    func cancel() { snapshot?.cancel() }

    func recognizer(_ provider: any SpeechRecognizer) -> any SpeechRecognizer {
        ContextualRecognizer(provider: provider, snapshot: snapshot, promptByteLimit: promptByteLimit)
    }

    func corrector(_ provider: any TextCorrecting) -> any TextCorrecting {
        guard let snapshot else { return provider }
        return ContextualCorrector(provider: provider, snapshot: snapshot)
    }

    private struct Hints: Sendable {
        let text: String
        let terms: [String]

        init(_ context: DictationContextSnapshot) {
            text = String(decoding: context.draft.utf8.prefix(720), as: UTF8.self)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            terms = DictationRecognitionPrompt.terms(draft: text, recentMessages: context.recentMessages)
        }
    }

    private struct ContextualRecognizer: SpeechRecognizer {
        let provider: any SpeechRecognizer
        let snapshot: Task<Hints, Never>?
        let promptByteLimit: Int?

        func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
            let terms = await snapshot?.value.terms ?? []
            try Task.checkCancellation()
            let manual = Set(options.context.split(whereSeparator: \.isWhitespace).map { $0.lowercased() })
            let automatic = terms.filter { !manual.contains($0.lowercased()) }.joined(separator: " ")
            let hint = [options.context, automatic].filter { !$0.isEmpty }.joined(separator: "\n")
            let merged: String
            if let promptByteLimit {
                merged = DictationRecognitionPrompt.bounded(hint, byteLimit: promptByteLimit)
            } else {
                merged = hint.utf8.count <= 4096 ? hint : options.context
            }
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

enum DictationRecognitionPrompt {
    static func terms(draft: String, recentMessages: [String]) -> [String] {
        let draftLimit = recentMessages.isEmpty ? 16 : 8
        let draftTerms = prioritized(words(in: draft)).prefix(draftLimit)
        let recentTerms = recentMessages.suffix(6).reversed().flatMap { message in
            let excerpt = String(decoding: message.utf8.prefix(320), as: UTF8.self)
            return words(in: excerpt)
        }
        var seen = Set<String>()
        let candidates = Array(draftTerms) + prioritized(recentTerms)
        return Array(candidates.filter { seen.insert($0.lowercased()).inserted }.prefix(16))
    }

    private static func prioritized(_ words: [String]) -> [String] {
        var distinctive: [String] = []
        var ordinary: [String] = []
        for word in words {
            if word.dropFirst().contains(where: { $0.isUppercase || $0.isNumber || $0 == "_" }) {
                distinctive.append(word)
            } else {
                ordinary.append(word)
            }
        }
        return distinctive + ordinary
    }

    private static func words(in text: String) -> [String] {
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
        return Array(words.reversed())
    }

    static func bounded(_ text: String, byteLimit: Int) -> String {
        var prompt = ""
        var remaining = byteLimit
        let text = text.replacingOccurrences(of: "\0", with: "")
        for word in text.split(whereSeparator: \.isWhitespace) {
            let separator = prompt.isEmpty ? "" : " "
            let bytes = separator.utf8.count + word.utf8.count
            guard bytes <= remaining else { break }
            prompt += separator + word
            remaining -= bytes
        }
        return prompt
    }
}
