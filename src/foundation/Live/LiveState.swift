import Foundation

public enum LivePhase: Sendable, Equatable { case idle, authorizing, recording, finishing }

public struct LiveState: Sendable, Equatable {
    public var phase: LivePhase = .idle
    public var session = 0
    public var samples: [Int16] = []
    public var text = ""
    public var error: String?
    public var level: Double = 0
    public var submitted = 0
    public var busy = false
    public var hasVoice = false
    fileprivate var submissionIsFinal = false
    fileprivate var consecutivePreviewFailures = 0
    fileprivate var latestVoiceSample = 0
    public init() {}
    public var seconds: Double { Double(samples.count) / Double(AudioClip.sampleRate) }
}

public enum LiveEvent: Sendable {
    case start
    case ready(Int)
    case audio(Int, [Int16])
    case pulse
    case stop
    case result(Int, Int, String)
    case previewFailed(Int, Int)
    case failed(Int, String)
    case cancel
    case clear
}

public enum LiveEffect: Sendable, Equatable {
    case authorize(Int)
    case capture(Int)
    case stopCapture
    case recognize(Int, [Int16])
    case cancelRecognition
}

public struct LiveTransition: Sendable {
    public let state: LiveState
    public let effects: [LiveEffect]
}

public enum LiveReducer {
    /// Preprocessed previews can opt into an earlier first submission and faster retries before text appears.
    public static func reduce(_ previous: LiveState, _ event: LiveEvent,
                              recognizesWhileRecording: Bool = true, requiresFinalRecognition: Bool = false,
                              usesShortPreviewCadence: Bool = false) -> LiveTransition {
        let firstPreviewSamples = usesShortPreviewCadence ? AudioClip.sampleRate * 3 / 4 : AudioClip.sampleRate
        let emptyPreviewRefreshSamples = usesShortPreviewCadence ? AudioClip.sampleRate / 4 : AudioClip.sampleRate / 2
        let refreshSamples = AudioClip.sampleRate / 2
        var state = previous
        var effects: [LiveEffect] = []
        func submit() {
            let isFinal = state.phase == .finishing
            // One retry on new audio recovers transient preview errors without restarting a broken worker indefinitely.
            guard !state.busy, state.hasVoice, !state.samples.isEmpty,
                  isFinal || state.consecutivePreviewFailures < 2 else { return }
            state.busy = true
            state.submissionIsFinal = isFinal
            state.submitted = state.samples.count
            effects.append(.recognize(state.session, state.samples))
        }
        func submitPreviewIfReady() {
            guard recognizesWhileRecording, state.phase == .recording,
                  state.latestVoiceSample > state.submitted else { return }
            let minimumNewSamples: Int
            if state.submitted == 0 { minimumNewSamples = firstPreviewSamples }
            else if state.text.isEmpty { minimumNewSamples = emptyPreviewRefreshSamples }
            else { minimumNewSamples = refreshSamples }
            if state.samples.count - state.submitted >= minimumNewSamples { submit() }
        }
        func finish() {
            state.level = 0
            effects.append(.stopCapture)
            if !state.hasVoice || (!requiresFinalRecognition && !state.busy && state.submitted == state.samples.count) {
                state.phase = .idle
            } else {
                state.phase = .finishing
                submit()
            }
        }
        switch event {
        case .start where state.phase == .idle:
            state = LiveState()
            state.session = previous.session + 1
            state.phase = .authorizing
            effects = [.authorize(state.session)]
        case .ready(let session) where session == state.session && state.phase == .authorizing:
            state.phase = .recording
            effects = [.capture(session)]
        case .audio(let session, let samples) where session == state.session && state.phase == .recording:
            state.samples.append(contentsOf: samples.prefix(AudioClip.maximumSamples - state.samples.count))
            state.level = samples.isEmpty ? 0 : sqrt(samples.reduce(0.0) { $0 + pow(Double($1) / 32768, 2) } / Double(samples.count))
            state.hasVoice = state.hasVoice || state.level > 0.002
            if state.level > 0.001 { state.latestVoiceSample = state.samples.count }
            if state.samples.count == AudioClip.maximumSamples { finish() }
            else { submitPreviewIfReady() }
        case .pulse where state.phase == .recording:
            if state.submitted > 0 { submitPreviewIfReady() }
        case .result(let session, let revision, let text) where session == state.session && state.busy && revision == state.submitted:
            if state.submissionIsFinal || !text.isEmpty { state.text = text }
            state.busy = false
            state.consecutivePreviewFailures = 0
            if state.phase == .finishing {
                if state.submitted == state.samples.count && (!requiresFinalRecognition || state.submissionIsFinal) {
                    state.phase = .idle
                }
                else { submit() }
            } else { submitPreviewIfReady() }
        case .previewFailed(let session, let revision)
            where session == state.session && state.busy && revision == state.submitted && !state.submissionIsFinal:
            state.consecutivePreviewFailures += 1
            state.busy = false
            if state.phase == .finishing { submit() }
            else { submitPreviewIfReady() }
        case .stop where state.phase == .recording:
            finish()
        case .failed(let session, let message) where session == state.session && state.phase != .idle:
            state.phase = .idle
            state.level = 0
            state.busy = false
            state.error = message
            effects = [.stopCapture, .cancelRecognition]
        case .cancel,
             .stop where state.phase == .authorizing:
            state.session += 1
            state.phase = .idle
            state.level = 0
            state.busy = false
            effects = [.stopCapture, .cancelRecognition]
        case .clear where state.phase == .idle:
            let session = state.session
            state = LiveState()
            state.session = session
        default: break
        }
        return LiveTransition(state: state, effects: effects)
    }
}
