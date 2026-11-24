import Foundation
import RxSwift
import SpeechFoundation
import SpeechInput
#if DEBUG
import AppKit
#endif

@MainActor final class VoxloomFlow {
    static let insertionSentNotice = "已发送插入请求"

    private typealias CapturedTarget = Result<CaretInsertion.Destination, Error>

    private enum InsertionRequest {
        case manual(CaretInsertion.Destination)
        case automatic(CapturedTarget)
    }
    private struct HeldRecording {
        let target: CapturedTarget
        let appendsToDraft: Bool
        var opensEditor = false
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
    private(set) var didSendInsertion = false
    var onChange: (() -> Void)?
    var onOpenDraft: (() -> Void)?
    #if DEBUG
    var debugContextLog: DebugContextLog?
    #endif

    var canStart: Bool {
        heldRecording == nil && startup == nil && insertionRequest == nil && (state?.live.phase ?? .idle) == .idle
    }
    var canInsert: Bool {
        guard heldRecording == nil, startup == nil, let state, !didSendInsertion,
              !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return (state.phase == .editing || state.phase == .confirmed) &&
            (state.live.phase == .idle || (editedTarget == nil && state.live.phase == .finishing))
    }
    var editsRecordingOnRelease: Bool { heldRecording?.opensEditor == true }

    private let capture: () -> any AudioCapturing
    private let makeRecognizer: (DictationSettings) -> any SpeechRecognizer
    private let corrector: (DictationSettings) -> (any TextCorrecting)?
    private let insertion: CaretInsertion
    private let readContext: (DictationSettings) -> (@Sendable () async -> DesktopContextReading)?
    private let prepareVoiceIsolation: () throws -> VoiceIsolationPreparation
    private let recognitionAvailable: (DictationSettings) -> Bool
    private var session: DictationSession?
    private var observation: (any Disposable)?
    private var startup: Task<Void, Never>?
    private var enginePreparation: Task<Void, Never>?
    private var activeEngine: (configuration: RecognitionEngine, recognizer: any SpeechRecognizer)?
    private var heldRecording: HeldRecording?
    private var editedTarget: CapturedTarget?
    private var insertionRequest: InsertionRequest?

    init(settings: DictationSettings, capture: @escaping () -> any AudioCapturing,
         recognizer: @escaping (DictationSettings) -> any SpeechRecognizer,
         corrector: @escaping (DictationSettings) -> (any TextCorrecting)?, insertion: CaretInsertion,
         readContext: @escaping (DictationSettings) -> (@Sendable () async -> DesktopContextReading)? = { _ in nil },
         prepareVoiceIsolation: @escaping () throws -> VoiceIsolationPreparation = {
             throw VoiceIsolationSetupError.unavailable
         },
         recognitionAvailable: @escaping (DictationSettings) -> Bool = { _ in true }) {
        self.settings = settings
        self.capture = capture
        makeRecognizer = recognizer
        self.corrector = corrector
        self.insertion = insertion
        self.readContext = readContext
        self.prepareVoiceIsolation = prepareVoiceIsolation
        self.recognitionAvailable = recognitionAvailable
    }

    func handle(_ action: FunctionKeyGesture.Action) {
        switch action {
        case .start:
            guard canStart else { return }
            guard recognitionAvailable(settings) else {
                showNotice("转写模型尚未就绪，请在设置中查看下载进度")
                return
            }
            begin(capture())
        case .stop: stopRecording(automatic: true)
        case .interrupted: stopRecording(automatic: false)
        case .confirm: insertDraft()
        }
    }

    func requestRecordingEdit() -> Bool {
        guard heldRecording != nil else { return false }
        heldRecording?.opensEditor = true
        onChange?()
        return true
    }

    func cancelHeldRecording() -> Bool {
        guard heldRecording != nil else { return false }
        clearOrCancel(notice: "本轮已取消，松开 \(settings.trigger.name) 后可重录")
        return true
    }

    func apply(_ settings: DictationSettings) {
        self.settings = settings
        onChange?()
    }

    func prepareForFirstRecording() {
        guard canStart, settings.model == .qwen, activeEngine == nil, recognitionAvailable(settings) else { return }
        let recognizer = makeRecognizer(settings)
        activeEngine = (RecognitionEngine(settings), recognizer)
        enginePreparation = Task(priority: .utility) { await recognizer.prepare() }
    }

    func edit(_ text: String, basedOn visibleText: String, replacedRange: NSRange? = nil) {
        notice = nil
        session?.edit(text, basedOn: visibleText, replacedRange: replacedRange)
    }

    func clearOrCancel(notice: String? = nil) {
        if case .automatic? = insertionRequest, state?.live.phase == .idle {
            insertionRequest = nil
            self.notice = notice
            session?.cancelAutomaticInsertion()
            return
        }
        let cancelRecording = !canStart
        insertionRequest = nil
        heldRecording = nil
        self.notice = notice
        startup?.cancel()
        if cancelRecording { session?.cancelRecording() }
        else {
            editedTarget = nil
            session?.cancel()
        }
        onChange?()
    }

    func showNotice(_ text: String) {
        notice = text
        onChange?()
    }

    func shutdown() async {
        heldRecording = nil
        editedTarget = nil
        insertionRequest = nil
        observation?.dispose()
        startup?.cancel()
        await startup?.value
        await session?.shutdown()
        await releaseRecognizer()
    }

    private func begin(_ audio: any AudioCapturing) {
        let previous = session
        let selected = settings
        let voiceIsolation: VoiceIsolationPreparation?
        do {
            voiceIsolation = selected.usesVoiceIsolation ? try prepareVoiceIsolation() : nil
        } catch {
            showNotice(error.localizedDescription)
            return
        }
        let existingText = didSendInsertion ? "" : (previous?.state.text ?? "")
        let usesContext = selected.usesInputContext || selected.usesConversationContext
        let sourceReader = usesContext ? readContext(selected) : nil
        let snapshotReader = sourceReader.map { reader in { @Sendable in await reader().snapshot } }
        #if DEBUG
        var contextReader = snapshotReader
        let diagnostic: (log: DebugContextLog, id: UUID)?
        if let log = debugContextLog {
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
        let live = LiveSpeechSession(capture: audio, ownsRecognizer: false,
                                     prepareFinalAudio: voiceIsolation?.final, preparePreviewAudio: voiceIsolation?.preview)
        let next = DictationSession(live: live, existingText: existingText,
                                    readContext: contextReader, recognitionPromptByteLimit: selected.model.promptByteLimit)
        notice = nil
        didSendInsertion = false
        insertionRequest = nil
        if existingText.isEmpty { editedTarget = nil }
        heldRecording = HeldRecording(target: Result { try insertion.destination(requireFocusedInput: true) },
                                     appendsToDraft: !existingText.isEmpty)
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
        let preparation = enginePreparation
        enginePreparation = nil
        preparation?.cancel()
        await engine?.recognizer.shutdown()
        await preparation?.value
    }

    private func stopRecording(automatic: Bool) {
        guard let recording = heldRecording, let session else { return }
        heldRecording = nil
        let opensEditor = automatic && recording.opensEditor
        if opensEditor { editedTarget = recording.target }
        if automatic, !opensEditor, !recording.appendsToDraft, startup == nil {
            let target = recording.target
            insertionRequest = .automatic(target)
            if case .success = target {
                session.stopForAutomaticInsertion()
                return
            }
        }
        startup?.cancel()
        if opensEditor { onOpenDraft?() }
        session.stop()
    }

    private func insertDraft() {
        guard canInsert, let session else { return }
        do {
            if let editedTarget {
                insert(session.state.text, at: try editedTarget.get())
                if didSendInsertion {
                    self.editedTarget = nil
                    session.confirm()
                } else { onChange?() }
                return
            }
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
            notice = Self.insertionSentNotice
        } catch { notice = error.localizedDescription }
    }
}

struct VoiceIsolationPreparation {
    let preview: LiveSpeechSession.PrepareAudio
    let final: LiveSpeechSession.PrepareAudio
}

enum VoiceIsolationSetupError: LocalizedError {
    case unavailable, missingSamples

    var errorDescription: String? {
        switch self {
        case .unavailable: "人声分离模型尚未安装"
        case .missingSamples: "先在设置里录一段你的声音"
        }
    }
}
