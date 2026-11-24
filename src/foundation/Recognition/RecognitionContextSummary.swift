public enum RecognitionContextSource: Sendable, Equatable {
    /// Text read from a conversation log, ordered from earlier to later.
    case messages([String])
    /// Candidate text from near the composer, ordered from earlier to later.
    case nearbyText([String])
}

/// Brief background and the untouched lines selected from the current conversation.
public struct RecognitionContextSummary: Sendable, Equatable {
    public let summary: String
    public let terms: [String]
    /// Up to two exact source strings in their original order.
    public let originalMessages: [String]

    public init(summary: String, terms: [String], originalMessages: [String] = []) {
        self.summary = summary
        self.terms = terms
        self.originalMessages = originalMessages
    }
}

public protocol RecognitionContextSummarizing: Sendable {
    func summarize(_ source: RecognitionContextSource) async throws -> RecognitionContextSummary
}
