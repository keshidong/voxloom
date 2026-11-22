import Foundation
import RxSwift
import SpeechFoundation
import SpeechInput

@MainActor final class VoxloomFlow {
    private typealias CapturedTarget = Result<CaretInsertion.Destination, Error>

    private enum InsertionRequest {
        case manual(CaretInsertion.Destination)
        case automatic(CapturedTarget)
    }

    private(set) var settings: DictationSettings
    var state: DictationState? { session?.state }
    private(set) var notice: String?
    private(set) var usesSample = false
    private(set) var didSendInsertion = false
    var onChange: (() -> Void)?

    var canStart: Bool {
        !heldRecording && startup == nil && insertionRequest == nil && (state?.live.phase ?? .idle) == .idle
    }
    var canTrySample: Bool { canStart && (didSendInsertion || state?.text.isEmpty != false) }
    var canInsert: Bool {
        guard !heldRecording, startup == nil, let state, !didSendInsertion,
              !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return (state.phase == .editing || state.phase == .confirmed) &&
            (state.live.phase == .idle || state.live.phase == .finishing)
    }

    private let capture: () -> any AudioCapturing
    private let recognizer: (DictationSettings) -> any SpeechRecognizer
    private let corrector: (DictationSettings) -> (any TextCorrecting)?
    private let insertion: CaretInsertion
    private let readInputContext: () -> (@Sendable () async -> String)?
    private var session: DictationSession?
    private var observation: (any Disposable)?
    private var startup: Task<Void, Never>?
    private var heldRecording = false
    private var recordingTarget: CapturedTarget?
    private var insertionRequest: InsertionRequest?

    init(settings: DictationSettings, capture: @escaping () -> any AudioCapturing,
         recognizer: @escaping (DictationSettings) -> any SpeechRecognizer,
         corrector: @escaping (DictationSettings) -> (any TextCorrecting)?, insertion: CaretInsertion,
         readInputContext: @escaping () -> (@Sendable () async -> String)? = { nil }) {
        self.settings = settings
        self.capture = capture
        self.recognizer = recognizer
        self.corrector = corrector
        self.insertion = insertion
        self.readInputContext = readInputContext
    }

    func handle(_ action: FunctionKeyGesture.Action) {
        switch action {
        case .start:
            guard canStart else { return }
            begin(capture(), held: true)
        case .stop: stopRecording(automatic: true)
        case .interrupted: stopRecording(automatic: false)
        case .confirm: insertDraft()
        }
    }

    func trySample(_ audio: AudioClip) {
        guard canTrySample else { return }
        begin(SampleCapture(audio: audio, realtime: false), held: false)
    }

    func apply(_ settings: DictationSettings) {
        self.settings = settings
        onChange?()
    }

    func edit(_ text: String, basedOn visibleText: String, replacedRange: NSRange? = nil) {
        notice = nil
        session?.edit(text, basedOn: visibleText, replacedRange: replacedRange)
    }

    func clearOrCancel() {
        if case .automatic? = insertionRequest, state?.live.phase == .idle {
            insertionRequest = nil
            notice = nil
            session?.cancelAutomaticInsertion()
            return
        }
        let cancelRecording = !canStart
        recordingTarget = nil
        insertionRequest = nil
        heldRecording = false
        notice = nil
        startup?.cancel()
        if cancelRecording { session?.cancelRecording() } else { session?.cancel() }
        onChange?()
    }

    func showNotice(_ text: String) {
        notice = text
        onChange?()
    }

    func shutdown() async {
        recordingTarget = nil
        insertionRequest = nil
        observation?.dispose()
        startup?.cancel()
        await startup?.value
        await session?.shutdown()
    }

    private func begin(_ audio: any AudioCapturing, held: Bool) {
        let previous = session
        let selected = settings
        let existingText = didSendInsertion ? "" : (previous?.state.text ?? "")
        let contextReader = held && selected.usesInputContext ? readInputContext() : nil
        let next = DictationSession(live: LiveSpeechSession(capture: audio), existingText: existingText,
                                    readInputContext: contextReader)
        notice = nil
        heldRecording = held
        usesSample = !held
        didSendInsertion = false
        insertionRequest = nil
        recordingTarget = held && existingText.isEmpty
            ? Result { try insertion.destination(requireFocusedInput: true) }
            : nil
        observation?.dispose()
        session = next
        observation = next.states.subscribe(onNext: { [weak self] _ in self?.refresh() })
        next.setCorrector(corrector(selected), vocabulary: selected.vocabulary)
        startup = Task { [weak self] in
            await previous?.shutdown()
            guard let self, session === next else { return }
            startup = nil
            if !Task.isCancelled {
                next.start(recognizer: recognizer(selected),
                           options: .init(language: selected.language, context: selected.vocabulary))
            }
            onChange?()
        }
        onChange?()
    }

    private func stopRecording(automatic: Bool) {
        guard heldRecording, let session else { return }
        heldRecording = false
        let target = recordingTarget
        recordingTarget = nil
        if automatic, startup == nil, let target {
            insertionRequest = .automatic(target)
            if case .success = target {
                session.stopForAutomaticInsertion()
                return
            }
        }
        startup?.cancel()
        session.stop()
    }

    private func insertDraft() {
        guard canInsert, let session else { return }
        do {
            insertionRequest = .manual(try insertion.destination())
            notice = nil
            if session.state.phase == .confirmed { refresh() }
            else { session.confirm() }
        } catch { showNotice(error.localizedDescription) }
    }

    private func refresh() {
        if let state, let insertionRequest {
            switch insertionRequest {
            case .manual(let target) where state.phase == .confirmed:
                self.insertionRequest = nil
                if let text = state.confirmedText { insert(text, at: target) }
            case .automatic(let target) where state.live.phase == .idle:
                insertAutomatically(state, target: target)
            default: break
            }
        }
        onChange?()
    }

    private func insertAutomatically(_ state: DictationState, target: CapturedTarget) {
        guard state.live.error == nil, !state.live.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            insertionRequest = nil
            return
        }
        switch target {
        case .success(let target):
            guard state.isReadyForAutomaticInsertion else { return }
            insertionRequest = nil
            if !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { insert(state.text, at: target) }
        case .failure(let error):
            insertionRequest = nil
            notice = error.localizedDescription
        }
    }

    private func insert(_ text: String, at target: CaretInsertion.Destination) {
        do {
            try insertion.insert(text, at: target)
            didSendInsertion = true
            notice = "已发送插入请求"
        } catch { notice = error.localizedDescription }
    }
}
