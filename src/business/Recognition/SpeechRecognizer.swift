import SpeechFoundation

/// One bounded recording to its original-language transcript.
/// Cancellation throws CancellationError; providers must stop their owned work.
public protocol SpeechRecognizer: Sendable {
    /// Gives resident engines an opportunity to start without accepting audio.
    func prepare() async
    func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript
    /// Transcribes the full prefix when there is new speech from the given sample offset.
    /// An empty transcript leaves the current live preview intact.
    func transcribePreview(_ audio: AudioClip, after sampleOffset: Int, options: RecognitionOptions) async throws -> Transcript
    func shutdown() async
}

extension SpeechRecognizer {
    public func prepare() async {}
    public func shutdown() async {}
    public func transcribe(_ audio: AudioClip) async throws -> Transcript {
        try await transcribe(audio, options: RecognitionOptions())
    }
    public func transcribePreview(_ audio: AudioClip, after sampleOffset: Int, options: RecognitionOptions) async throws -> Transcript {
        try await transcribe(audio, options: options)
    }
}
