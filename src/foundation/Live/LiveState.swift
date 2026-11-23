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
    public static func reduce(_ previous: LiveState, _ event: LiveEvent) -> LiveTransition {
        let firstPreviewSamples = AudioClip.sampleRate
        let refreshSamples = AudioClip.sampleRate / 2
        var state = previous
        var effects: [LiveEffect] = []
        func submit() {
            guard !state.busy, state.hasVoice, !state.samples.isEmpty else { return }
            state.busy = true
            state.submitted = state.samples.count
            effects.append(.recognize(state.session, state.samples))
        }
        func finish() {
            state.level = 0
            effects.append(.stopCapture)
            if !state.hasVoice || (!state.busy && state.submitted == state.samples.count) {
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
            if state.samples.count == AudioClip.maximumSamples { finish() }
            else if state.submitted == 0 && state.samples.count >= firstPreviewSamples { submit() }
        case .pulse where state.phase == .recording:
            if state.submitted > 0 && state.samples.count - state.submitted >= refreshSamples { submit() }
        case .result(let session, let revision, let text) where session == state.session && state.busy && revision == state.submitted:
            state.text = text
            state.busy = false
            if state.phase == .finishing {
                if state.submitted == state.samples.count { state.phase = .idle }
                else { submit() }
            } else if state.samples.count - state.submitted >= refreshSamples { submit() }
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
