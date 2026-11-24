import Foundation
import RxSwift
import SpeechFoundation
import SpeechInput
#if DEBUG
import AppKit
#endif

@MainActor final class VoxloomFlow {
    private typealias CapturedTarget = Result<CaretInsertion.Destination, Error>

    private enum InsertionRequest {
        case manual(CaretInsertion.Destination)
        case automatic(CapturedTarget)
    }
    private struct RecognitionEngine: Equatable {
        let model: RecognitionModel
        let usesGPU: Bool

        init(_ settings: DictationSettings) {
            model = settings.model
            usesGPU = settings.model != .qwen && settings.usesGPU
        }
    }

    private(set) var settings: DictationSettings
    var state: DictationState? { session?.state }
    private(set) var notice: String?
    private(set) var usesSample = false
    private(set) var didSendInsertion = false
    var onChange: (() -> Void)?
    #if DEBUG
    var debugContextLog: DebugContextLog?
    #endif

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
    private let makeRecognizer: (DictationSettings) -> any SpeechRecognizer
    private let corrector: (DictationSettings) -> (any TextCorrecting)?
    private let insertion: CaretInsertion
    private let readContext: (DictationSettings) -> (@Sendable () async -> DesktopContextReading)?
    private var session: DictationSession?
    private var observation: (any Disposable)?
    private var startup: Task<Void, Never>?
    private var activeEngine: (configuration: RecognitionEngine, recognizer: any SpeechRecognizer)?
    private var heldRecording = false
    private var recordingTarget: CapturedTarget?
    private var insertionRequest: InsertionRequest?

    init(settings: DictationSettings, capture: @escaping () -> any AudioCapturing,
         recognizer: @escaping (DictationSettings) -> any SpeechRecognizer,
         corrector: @escaping (DictationSettings) -> (any TextCorrecting)?, insertion: CaretInsertion,
         readContext: @escaping (DictationSettings) -> (@Sendable () async -> DesktopContextReading)? = { _ in nil }) {
        self.settings = settings
        self.capture = capture
        makeRecognizer = recognizer
        self.corrector = corrector
        self.insertion = insertion
        self.readContext = readContext
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
        await releaseRecognizer()
    }

    private func begin(_ audio: any AudioCapturing, held: Bool) {
        let previous = session
        let selected = settings
        let existingText = didSendInsertion ? "" : (previous?.state.text ?? "")
        let usesContext = selected.usesInputContext || selected.usesConversationContext
        let sourceReader = held && usesContext ? readContext(selected) : nil
        let snapshotReader = sourceReader.map { reader in { @Sendable in await reader().snapshot } }
        #if DEBUG
        var contextReader = snapshotReader
        let diagnostic: (log: DebugContextLog, id: UUID)?
        if held, let log = debugContextLog {
            let app = NSWorkspace.shared.frontmostApplication
            let target = [app?.localizedName, app?.bundleIdentifier].compactMap { $0 }.joined(separator: " · ")
            let id = log.begin(settings: selected, readerAvailable: sourceReader != nil,
                               target: target.isEmpty ? nil : target)
            diagnostic = (log, id)
            if let reader = sourceReader { contextReader = log.tracking(reader, for: id) }
        } else {
            diagnostic = nil
        }
        #else
        let contextReader = snapshotReader
        #endif
        let next = DictationSession(live: LiveSpeechSession(capture: audio, ownsRecognizer: false), existingText: existingText,
                                    readContext: contextReader, recognitionPromptByteLimit: selected.model.promptByteLimit)
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
            if !Task.isCancelled, let provider = await recognizer(for: selected) {
                #if DEBUG
                let provider = diagnostic.map { $0.log.tracking(provider, for: $0.id) } ?? provider
                #endif
                next.start(recognizer: provider,
                           options: .init(language: selected.language, context: selected.vocabulary))
            }
            startup = nil
            onChange?()
        }
        onChange?()
    }

    private func recognizer(for settings: DictationSettings) async -> (any SpeechRecognizer)? {
        let configuration = RecognitionEngine(settings)
        if let activeEngine, activeEngine.configuration == configuration { return activeEngine.recognizer }
        await releaseRecognizer()
        guard !Task.isCancelled else { return nil }
        let recognizer = makeRecognizer(settings)
        activeEngine = (configuration, recognizer)
        return recognizer
    }

    private func releaseRecognizer() async {
        let engine = activeEngine
        activeEngine = nil
        await engine?.recognizer.shutdown()
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
