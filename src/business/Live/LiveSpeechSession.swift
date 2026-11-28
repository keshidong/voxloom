import Foundation
import SpeechFoundation
import RxSwift

@MainActor public protocol AudioCapturing: AnyObject {
    var sourceDescription: String { get }
    func requestAccess() async throws
    func start(samples: @escaping @Sendable ([Int16]) -> Void, ended: @escaping @Sendable (String?) -> Void) throws
    func stop()
}

public extension AudioCapturing {
    var sourceDescription: String { "音频输入" }
}

/// Owns one live session. Rx coordinates audio, user actions, cadence and results.
@MainActor public final class LiveSpeechSession {
    public typealias PrepareAudio = @Sendable (AudioClip) async throws -> AudioClip
    public typealias PrepareFinalAudio = PrepareAudio

    public private(set) var state = LiveState()
    private let input = PublishSubject<LiveEvent>()
    private let output = BehaviorSubject<LiveState>(value: LiveState())
    private let bag = DisposeBag()
    private let scheduler: any SchedulerType
    private let capture: any AudioCapturing
    private let ownsRecognizer: Bool
    private let prepareFinalAudio: PrepareFinalAudio?
    private let preparePreviewAudio: PrepareAudio?
    private var authorization: Task<Void, Never>?
    private var recognition: Task<Void, Never>?
    private var clock: (any Disposable)?
    private var recognizer: (any SpeechRecognizer)?
    private var options = RecognitionOptions()
    private var transcribedPreviewSamples = 0
    var keepsAudioForReview = false
    private var recognitionAudio: (session: Int, samples: Int, clip: AudioClip)?
    public var states: Observable<LiveState> { output.asObservable() }
    public var sourceDescription: String { capture.sourceDescription }

    /// Pass `ownsRecognizer: false` when the caller will shut down a recognizer shared across sessions.
    public init(capture: any AudioCapturing, scheduler: any SchedulerType = MainScheduler.instance,
                ownsRecognizer: Bool = true, prepareFinalAudio: PrepareFinalAudio? = nil,
                preparePreviewAudio: PrepareAudio? = nil) {
        self.capture = capture
        self.scheduler = scheduler
        self.ownsRecognizer = ownsRecognizer
        self.prepareFinalAudio = prepareFinalAudio
        self.preparePreviewAudio = preparePreviewAudio
        let preparesPreviewAudio = preparePreviewAudio != nil
        input.observe(on: MainScheduler.asyncInstance)
            .scan(LiveReducer.reduce(LiveState(), .pulse)) { previous, event in
                LiveReducer.reduce(previous.state, event,
                    recognizesWhileRecording: prepareFinalAudio == nil || preparesPreviewAudio,
                    requiresFinalRecognition: preparesPreviewAudio,
                    usesShortPreviewCadence: preparesPreviewAudio)
            }.subscribe(onNext: { [weak self] transition in
                guard let self else { return }
                state = transition.state
                output.onNext(state)
                transition.effects.forEach(perform)
            }).disposed(by: bag)
    }

    public func start(recognizer: any SpeechRecognizer, options: RecognitionOptions = .init()) {
        guard state.phase == .idle else { return }
        self.recognizer = recognizer
        self.options = options
        input.onNext(.start)
    }
    public func stop() { input.onNext(.stop) }
    public func cancel() { input.onNext(.cancel) }
    public func clear() { input.onNext(.clear) }

    func takeCompletedAudio() -> AudioClip? {
        defer { recognitionAudio = nil }
        guard let recognitionAudio, state.phase == .idle, state.error == nil,
              recognitionAudio.session == state.session, recognitionAudio.samples == state.samples.count
        else { return nil }
        return recognitionAudio.clip
    }

    public func shutdown() async {
        let provider = recognizer
        recognizer = nil
        recognitionAudio = nil
        capture.stop()
        clock?.dispose()
        authorization?.cancel()
        recognition?.cancel()
        // A system permission prompt may ignore task cancellation. It has not
        // started owned audio work; its eventual reply is checked for cancellation.
        await recognition?.value
        if ownsRecognizer { await provider?.shutdown() }
    }

    private func perform(_ effect: LiveEffect) {
        switch effect {
        case .authorize(let id):
            authorization = Task { [weak self, capture] in
                do {
                    try await capture.requestAccess()
                    try Task.checkCancellation()
                    self?.input.onNext(.ready(id))
                } catch is CancellationError {} catch {
                    self?.input.onNext(.failed(id, error.localizedDescription))
                }
            }
        case .capture(let id):
            transcribedPreviewSamples = 0
            recognitionAudio = nil
            do {
                try capture.start(samples: { [weak self] samples in
                    DispatchQueue.main.async { [weak self] in self?.input.onNext(.audio(id, samples)) }
                }, ended: { [weak self] message in
                    DispatchQueue.main.async { [weak self] in
                        self?.input.onNext(message.map { .failed(id, $0) } ?? .stop)
                    }
                })
                clock = Observable<Int>.interval(.milliseconds(500), scheduler: scheduler)
                    .subscribe(onNext: { [weak self] _ in self?.input.onNext(.pulse) })
            } catch { input.onNext(.failed(id, error.localizedDescription)) }
        case .stopCapture:
            capture.stop()
            clock?.dispose()
            clock = nil
        case .recognize(let id, let samples):
            guard let recognizer else { return }
            let options = options
            let isPreview = state.phase == .recording
            let isIsolatedPreview = isPreview && preparePreviewAudio != nil
            let previewOffset = transcribedPreviewSamples
            let prepareAudio = isPreview ? preparePreviewAudio : prepareFinalAudio
            recognition = Task { [weak self] in
                do {
                    let inputAudio = try AudioClip(samples: samples)
                    let audio = try await prepareAudio?(inputAudio) ?? inputAudio
                    try Task.checkCancellation()
                    let text: String
                    if audio.samples.isEmpty {
                        text = ""
                    } else if isPreview {
                        text = try await recognizer.transcribePreview(audio, after: min(previewOffset, audio.samples.count),
                                                                      options: options).text
                    } else {
                        text = try await recognizer.transcribe(audio, options: options).text
                    }
                    guard let self, state.session == id, state.busy, state.submitted == samples.count else { return }
                    if isPreview, !text.isEmpty { transcribedPreviewSamples = audio.samples.count }
                    if keepsAudioForReview, !text.isEmpty { recognitionAudio = (id, samples.count, audio) }
                    input.onNext(.result(id, samples.count, text))
                } catch is CancellationError {} catch {
                    self?.input.onNext(isIsolatedPreview ? .previewFailed(id, samples.count) : .failed(id, "识别失败：\(error)"))
                }
            }
        case .cancelRecognition:
            authorization?.cancel()
            recognition?.cancel()
            recognitionAudio = nil
        }
    }
}
