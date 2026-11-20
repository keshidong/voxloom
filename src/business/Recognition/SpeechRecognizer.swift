import SpeechFoundation

/// One bounded recording to its original-language transcript.
/// Cancellation throws CancellationError; providers must stop their owned work.
public protocol SpeechRecognizer: Sendable {
    func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript
    func shutdown() async
}

extension SpeechRecognizer {
    public func shutdown() async {}
    public func transcribe(_ audio: AudioClip) async throws -> Transcript {
        try await transcribe(audio, options: RecognitionOptions())
    }
}
