/// Provider-neutral options. Context is a vocabulary hint, not a command to rewrite speech.
public struct RecognitionOptions: Sendable, Equatable {
    public let language: RecognitionLanguage
    public let context: String

    public init(language: RecognitionLanguage = .automatic, context: String = "") {
        self.language = language
        self.context = context
    }
}

public enum RecognitionLanguage: String, Sendable, CaseIterable {
    case automatic = "auto"
    case chinese = "zh"
    case english = "en"
}

/// Uncorrected ASR output. Empty text is a valid no-speech result.
public struct Transcript: Sendable, Equatable, Codable {
    public let text: String
    public let language: String?

    public init(text: String, language: String? = nil) {
        self.text = text
        self.language = language
    }
}

public enum RecognitionError: Error, Sendable, Equatable {
    case emptyAudio
    case invalidConfiguration
    case busy
    case engineUnavailable
    case modelUnavailable
    case fileAccess
    case engineFailed(exitCode: Int32)
    case invalidResult
    case timedOut
}
