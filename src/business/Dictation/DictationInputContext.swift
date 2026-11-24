import Foundation
import NaturalLanguage
import SpeechFoundation

public struct DictationContextSnapshot: Sendable {
    public let draft: String
    /// Text from the current conversation, in chronological order.
    public let recentMessages: [String]
    public let nearbyChatText: [String]

    public init(draft: String = "", recentMessages: [String] = [], nearbyChatText: [String] = []) {
        self.draft = draft
        self.recentMessages = recentMessages
        self.nearbyChatText = nearbyChatText
    }
}

/// A single, local snapshot shared by the recognizer and corrector for one hold.
struct DictationInputContext: Sendable {
    private let snapshot: Task<Hints, Never>?
    private let promptByteLimit: Int?
    private let summaries: DictationContextSummaries?
    private let includesOriginalMessages: Bool

    @MainActor init(read: (@Sendable () async -> DictationContextSnapshot)?, promptByteLimit: Int?,
                    summaries: DictationContextSummaries?, includesOriginalMessages: Bool) {
        let recording = summaries?.beginRecording()
        snapshot = read.map { read in
            Task.detached(priority: .userInitiated) {
                let context = await read()
                guard !Task.isCancelled else { return Hints(draft: "", recentMessages: [], originalMessages: [], source: nil) }
                let messages = includesOriginalMessages ? Array(context.recentMessages.suffix(2)) : context.recentMessages
                let source: RecognitionContextSource?
                if messages.count < 2, !context.nearbyChatText.isEmpty { source = .nearbyText(context.nearbyChatText) }
                else { source = messages.isEmpty ? nil : .messages(messages) }
                if let summaries, let recording {
                    await summaries.prepare(source, for: recording)
                }
                return Hints(draft: context.draft, recentMessages: messages,
                             originalMessages: includesOriginalMessages ? messages : [], source: source)
            }
        }
        self.promptByteLimit = promptByteLimit
        self.summaries = summaries
        self.includesOriginalMessages = includesOriginalMessages
    }

    func cancel() { snapshot?.cancel() }

    func recognizer(_ provider: any SpeechRecognizer) -> any SpeechRecognizer {
        ContextualRecognizer(provider: provider, snapshot: snapshot, promptByteLimit: promptByteLimit, summaries: summaries,
                             includesOriginalMessages: includesOriginalMessages)
    }

    func corrector(_ provider: any TextCorrecting) -> any TextCorrecting {
        guard let snapshot else { return provider }
        return ContextualCorrector(provider: provider, snapshot: snapshot)
    }

    private struct Hints: Sendable {
        let text: String
        let terms: [String]
        let originalMessages: [String]
        let source: RecognitionContextSource?

        init(draft: String, recentMessages: [String], originalMessages: [String], source: RecognitionContextSource?) {
            text = String(decoding: draft.utf8.prefix(720), as: UTF8.self)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            terms = DictationRecognitionPrompt.terms(draft: text, recentMessages: recentMessages)
            self.originalMessages = originalMessages
            self.source = source
        }

        func conversation(using summaries: DictationContextSummaries?) async -> (messages: [String], summary: RecognitionContextSummary?) {
            guard let source, let summary = await summaries?.summary(for: source) else { return (originalMessages, nil) }
            guard case .nearbyText = source else { return (originalMessages, summary) }
            guard originalMessages.allSatisfy({ summary.originalMessages.contains($0) }) else { return (originalMessages, nil) }
            return (summary.originalMessages, summary)
        }
    }

    private struct ContextualRecognizer: SpeechRecognizer {
        let provider: any SpeechRecognizer
        let snapshot: Task<Hints, Never>?
        let promptByteLimit: Int?
        let summaries: DictationContextSummaries?
        let includesOriginalMessages: Bool

        func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
            let hints = await snapshot?.value
            let conversation = await hints?.conversation(using: summaries)
            try Task.checkCancellation()
            var seen = Set(options.context.split(whereSeparator: \.isWhitespace).map { $0.lowercased() })
            let terms = (conversation?.summary?.terms ?? []) + (hints?.terms ?? [])
            let automatic = terms.filter { seen.insert($0.lowercased()).inserted }.joined(separator: " ")
            let hint = [options.context, automatic].filter { !$0.isEmpty }.joined(separator: "\n")
            let merged: String
            if includesOriginalMessages {
                merged = DictationRecognitionPrompt.withConversation(manual: options.context, messages: conversation?.messages ?? [],
                    summary: conversation?.summary?.summary, additionalTerms: automatic, byteLimit: promptByteLimit ?? 4096)
            } else if let promptByteLimit {
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
    private struct ConversationPrompt: Encodable {
        struct Hints: Encodable {
            var instruction: String?
            var terms: String?
        }

        var currentActivity: String?
        var recentMessages: [String]?
        var asrHints: Hints?
    }

    static func withConversation(manual: String, messages: [String], summary: String?, additionalTerms: String,
                                 byteLimit: Int) -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var content = ConversationPrompt()
        var result = ""

        @discardableResult
        func includeIfFits(_ candidate: ConversationPrompt) -> Bool {
            guard let data = try? encoder.encode(candidate) else { return false }
            let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<|", with: #"\u003c|"#)
            guard json.utf8.count <= byteLimit else { return false }
            content = candidate
            result = json
            return true
        }

        func appendTerms(_ text: String) {
            let words = text.replacingOccurrences(of: "\0", with: "").split(whereSeparator: \.isWhitespace)
            for word in words {
                var candidate = content
                var hints = candidate.asrHints ?? .init()
                hints.terms = hints.terms.map { $0 + " " + word } ?? String(word)
                candidate.asrHints = hints
                guard includeIfFits(candidate) else { break }
            }
        }

        appendTerms(manual)
        for message in messages.suffix(2).reversed() {
            var candidate = content
            candidate.recentMessages = [message] + (content.recentMessages ?? [])
            includeIfFits(candidate)
        }
        if let summary, !summary.isEmpty {
            var candidate = content
            candidate.currentActivity = summary
            includeIfFits(candidate)
        }
        appendTerms(additionalTerms)
        if !result.isEmpty {
            var candidate = content
            var hints = candidate.asrHints ?? .init()
            hints.instruction = "按当前录音转写，结合背景辨认近音词，保留中英文术语的拼写。"
            candidate.asrHints = hints
            includeIfFits(candidate)
        }
        return result
    }

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
