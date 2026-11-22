import Foundation
import RxSwift
import SpeechFoundation

public enum DictationPhase: Sendable, Equatable { case editing, confirming, confirmed, discarded }

public struct DictationState: Sendable, Equatable {
    public fileprivate(set) var phase: DictationPhase = .editing
    public fileprivate(set) var live = LiveState()
    public fileprivate(set) var text = ""
    public fileprivate(set) var correction: CorrectionStatus = .idle
    public fileprivate(set) var isReadyForAutomaticInsertion = false
    public var confirmedText: String? {
        guard phase == .confirmed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

/// Coordinates one recording with an editable draft and an optional local corrector.
@MainActor public final class DictationSession {
    private enum AutomaticInsertion { case waitingForTranscript, waitingForCorrection }

    public let live: LiveSpeechSession
    public private(set) var state: DictationState
    public var states: Observable<DictationState> { output.asObservable() }
    public var sourceDescription: String { live.sourceDescription }
    private let output: BehaviorSubject<DictationState>
    private let scheduler: any SchedulerType
    private let existingText: String
    private let inputContext: DictationInputContext?
    private let bag = DisposeBag()
    private let correctionObservation = SerialDisposable()
    private let finalCorrectionTimer = SerialDisposable()
    private var correction: CorrectionSession?
    private var draft: DictationDraft
    private var inputRevision = 0
    private var vocabulary = ""
    private var cancellingRecording: Int?
    private var automaticInsertion: AutomaticInsertion?

    public init(live: LiveSpeechSession, existingText: String = "",
                correctionScheduler: any SchedulerType = MainScheduler.instance,
                readInputContext: (@Sendable () async -> String)? = nil) {
        self.live = live
        scheduler = correctionScheduler
        self.existingText = existingText
        inputContext = readInputContext.map { DictationInputContext(read: $0) }
        let initial = DictationState(text: existingText)
        state = initial
        output = BehaviorSubject(value: initial)
        draft = DictationDraft(existingText: existingText)
        correctionObservation.disposed(by: bag)
        finalCorrectionTimer.disposed(by: bag)
        live.states.subscribe(onNext: { [weak self] in self?.receive($0) }).disposed(by: bag)
    }

    public func start(recognizer: any SpeechRecognizer, options: RecognitionOptions = .init()) {
        guard state.phase == .editing else { return }
        vocabulary = options.context
        live.start(recognizer: inputContext?.recognizer(recognizer) ?? recognizer, options: options)
    }

    public func stop() { live.stop() }

    /// Stops capture, then gives the final transcript up to three seconds for correction.
    public func stopForAutomaticInsertion() {
        guard state.phase == .editing, automaticInsertion == nil, !state.isReadyForAutomaticInsertion else { return }
        automaticInsertion = .waitingForTranscript
        if state.live.phase == .idle {
            prepareAutomaticInsertion()
            publish()
        } else {
            live.stop()
        }
    }

    /// Keeps the editable draft and allows any current correction to finish normally.
    public func cancelAutomaticInsertion() {
        resetAutomaticInsertion()
        publish()
    }

    public func setCorrector(_ corrector: (any TextCorrecting)?, vocabulary: String) {
        self.vocabulary = vocabulary
        correctionObservation.disposable = Disposables.create()
        correction?.cancel()
        correction = nil
        state.correction = .idle
        if let corrector, state.phase == .editing {
            let next = CorrectionSession(corrector: inputContext?.corrector(corrector) ?? corrector, scheduler: scheduler)
            correction = next
            correctionObservation.disposable = next.states.subscribe(onNext: { [weak self] in self?.receive($0) })
            if inputRevision > 0 { scheduleCorrection() }
        }
        publish()
    }

    public func edit(_ text: String, basedOn visibleText: String, replacedRange: NSRange? = nil) {
        guard state.phase == .editing else { return }
        let before = draft.text
        draft.edit(text, basedOn: visibleText, replacedRange: replacedRange)
        if before != draft.text { inputChanged() }
        publish()
    }

    public func confirm() {
        guard state.phase == .editing else { return }
        resetAutomaticInsertion()
        state.phase = .confirming
        correction?.cancel()
        if state.correction == .working { state.correction = .idle }
        switch live.state.phase {
        case .idle: state.phase = .confirmed
        case .authorizing: live.cancel()
        case .recording: live.stop()
        case .finishing: break
        }
        publish()
    }

    public func cancel() {
        discard()
        live.cancel()
    }

    /// Discards this recording and restores the draft captured before it began.
    public func cancelRecording() {
        guard !existingText.isEmpty else { cancel(); return }
        guard cancellingRecording == nil else { return }
        cancellingRecording = state.live.session
        inputContext?.cancel()
        resetAutomaticInsertion()
        correction?.cancel()
        state.phase = .editing
        state.correction = .idle
        draft = DictationDraft(existingText: existingText)
        inputRevision += 1
        live.cancel()
        live.clear()
        publish()
    }

    public func clear() {
        discard()
        live.clear()
    }

    public func shutdown() async {
        if state.phase == .editing || state.phase == .confirming { discard() }
        await live.shutdown()
        await correction?.shutdown()
    }

    private func discard() {
        inputContext?.cancel()
        cancellingRecording = nil
        resetAutomaticInsertion()
        state.phase = .discarded
        state.correction = .idle
        correction?.cancel()
        draft = DictationDraft()
        publish()
    }

    private func receive(_ liveState: LiveState) {
        let changed = state.live.text != liveState.text
        state.live = liveState
        if let cancelled = cancellingRecording {
            if liveState.session != cancelled, liveState.phase == .idle, liveState.samples.isEmpty {
                cancellingRecording = nil
            }
        } else if changed, state.phase == .editing || state.phase == .confirming {
            let before = draft.text
            draft.recognize(liveState.text)
            if state.phase == .editing, before != draft.text { inputChanged() }
        }
        if state.phase == .confirming, liveState.phase == .idle, cancellingRecording == nil {
            state.phase = .confirmed
        }
        if liveState.phase == .idle, automaticInsertion == .waitingForTranscript {
            prepareAutomaticInsertion()
        }
        publish()
    }

    private func receive(_ status: CorrectionStatus) {
        guard state.phase == .editing, cancellingRecording == nil else { return }
        state.correction = status
        if automaticInsertion == .waitingForCorrection, status != .working, status != .idle,
           correction?.hasImmediateWork != true {
            finishAutomaticInsertion()
        }
        publish()
    }

    private func prepareAutomaticInsertion() {
        if state.live.error == nil, !state.live.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let correction, correction.prepareFinalDraft({ [weak self] in self?.currentCorrectionJob() }) {
            automaticInsertion = .waitingForCorrection
            finalCorrectionTimer.disposable = scheduler.scheduleRelative((), dueTime: .seconds(3)) { [weak self] _ in
                if let self, automaticInsertion == .waitingForCorrection {
                    correction.cancel()
                    finishAutomaticInsertion()
                    publish()
                }
                return Disposables.create()
            }
        } else {
            finishAutomaticInsertion()
        }
    }

    private func finishAutomaticInsertion() {
        correction?.discardScheduledWork()
        resetAutomaticInsertion()
        state.isReadyForAutomaticInsertion = true
    }

    private func resetAutomaticInsertion() {
        automaticInsertion = nil
        finalCorrectionTimer.disposable = Disposables.create()
        state.isReadyForAutomaticInsertion = false
    }

    private func inputChanged() {
        inputRevision += 1
        scheduleCorrection()
    }

    private func scheduleCorrection() {
        guard cancellingRecording == nil, !state.isReadyForAutomaticInsertion else { return }
        if draft.text.isEmpty { correction?.cancel() }
        else { correction?.updateDraft { [weak self] in self?.currentCorrectionJob() } }
    }

    private func currentCorrectionJob() -> CorrectionSession.Job? {
        guard state.phase == .editing, cancellingRecording == nil else { return nil }
        let snapshot = draft.correctionSnapshot
        guard !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .init(request: .init(text: snapshot.text, vocabulary: vocabulary), inputRevision: inputRevision) { [weak self] candidate in
            self?.draft.correct(candidate, basedOn: snapshot)
        }
    }

    private func publish() {
        state.text = draft.text
        output.onNext(state)
    }
}
