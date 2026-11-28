import SpeechFoundation

public struct DictationApplication: Sendable, Equatable {
    public let name: String?
    public let bundleIdentifier: String?

    public init(name: String?, bundleIdentifier: String?) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct AudioReviewRequest: Sendable, Equatable {
    public let audio: AudioClip
    public let transcript: String
    public let precedingText: String
    public let vocabulary: String
    public let application: DictationApplication?
    /// Optional source context as supplied by the caller. The desktop client supplies cleaned words from the focused window.
    public let applicationContext: String

    public init(audio: AudioClip, transcript: String, precedingText: String = "", vocabulary: String = "",
                application: DictationApplication? = nil, applicationContext: String = "") {
        self.audio = audio
        self.transcript = transcript
        self.precedingText = precedingText
        self.vocabulary = vocabulary
        self.application = application
        self.applicationContext = applicationContext
    }
}

/// Verifies one final ASR transcript against its audio. Cancellation throws CancellationError.
public protocol AudioReviewing: Sendable {
    func prepare(application: DictationApplication?, context: String) async
    func review(_ request: AudioReviewRequest) async throws -> String
}

public extension AudioReviewing {
    func prepare(application: DictationApplication?, context: String) async {}
}
