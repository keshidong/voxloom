import SpeechFoundation

/// Final ASR text to a proposed correction. Original text remains owned by the caller.
public protocol TextCorrecting: Sendable {
    func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate
}
