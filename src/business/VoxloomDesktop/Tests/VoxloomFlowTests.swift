import Foundation
import SpeechFoundation
import SpeechInput
import Testing
@testable import VoxloomDesktop

@MainActor struct VoxloomFlowTests {
    @Test func consecutiveDictationsReuseTheLoadedEngineAndApplyNewRecognitionOptions() async throws {
        let capture = FlowCapture()
        let recognizer = ResidentFlowRecognizer()
        var posted: [String] = []
        let flow = VoxloomFlow(settings: .init(), capture: { capture }, recognizer: { _ in recognizer },
            corrector: { _ in nil }, insertion: .init(foregroundTarget: { 101 }, canPost: { true },
                paste: { text, _ in posted.append(text); return true }, captureFocus: { _ in { true } }))

        for language in [RecognitionLanguage.chinese, .english] {
            var settings = flow.settings
            settings.language = language
            flow.apply(settings)
            try await recordShortClip(in: flow, capture: capture)
        }

        #expect(posted == ["语音草稿", "English draft"])
        #expect(await recognizer.loads == 1)
        #expect(await recognizer.loaded)
        await flow.shutdown()
        #expect(await !recognizer.loaded)
    }

    @Test func switchingModelsReleasesThePreviousEngineBeforeTheNextRecording() async throws {
        let capture = FlowCapture()
        let qwen = ResidentFlowRecognizer()
        let whisper = ResidentFlowRecognizer()
        let flow = VoxloomFlow(settings: .init(), capture: { capture },
            recognizer: { $0.model == .qwen ? qwen : whisper }, corrector: { _ in nil },
            insertion: .init(foregroundTarget: { 101 }, canPost: { false }, paste: { _, _ in false }))

        func record(using model: RecognitionModel) async throws {
            var settings = flow.settings
            settings.model = model
            flow.apply(settings)
            try await recordShortClip(in: flow, capture: capture)
        }

        try await record(using: .qwen)
        #expect(await qwen.loaded)
        try await record(using: .whisperTiny)
        #expect(await !qwen.loaded)
        #expect(await whisper.loaded)
        try await record(using: .qwen)
        #expect(await !whisper.loaded)
        #expect(await qwen.loads == 2)
        await flow.shutdown()
        #expect(await !qwen.loaded)
    }

    @Test(arguments: [RecognitionModel.qwen, .whisperTurbo])
    func limitsManualVocabularyForTheSelectedEngine(model: RecognitionModel) async throws {
        let capture = FlowCapture()
        let recognizer = ContextSinkRecognizer()
        var settings = DictationSettings()
        settings.model = model
        let terms = ["Voxloom"] + (0..<55).map { "词汇编号\($0)" }
        settings.vocabulary = terms.joined(separator: " ")
        let flow = VoxloomFlow(settings: settings, capture: { capture }, recognizer: { _ in recognizer },
            corrector: { _ in nil }, insertion: .init(foregroundTarget: { 101 }, canPost: { false }, paste: { _, _ in false }))

        flow.handle(.start)
        try await reaches { capture.receive != nil }
        capture.receive?([3000, -3000])
        try await reaches { flow.state?.live.samples.count == 2 }
        flow.handle(.stop)
        try await reaches { flow.canStart }

        let prompt = try #require(await recognizer.contexts.first)
        let included = prompt.split(whereSeparator: \.isWhitespace).map(String.init)
        let limit = model == .qwen ? 512 : 192
        #expect(prompt.utf8.count <= limit)
        #expect(included.first == "Voxloom")
        #expect(included == Array(terms.prefix(included.count)))
        await flow.shutdown()
    }

    enum EndOfRecording: CaseIterable { case release, switchedField, interrupted }

    @Test(arguments: EndOfRecording.allCases)
    func aReleasedRecordingInsertsOnlyAtItsOriginalField(end: EndOfRecording) async throws {
        let capture = FlowCapture()
        var field = 1
        var posted: [String] = []
        let flow = VoxloomFlow(settings: .init(), capture: { capture }, recognizer: { _ in FlowRecognizer() },
            corrector: { _ in nil }, insertion: .init(foregroundTarget: { 101 }, canPost: { true },
            paste: { text, _ in posted.append(text); return true }, captureFocus: { _ in
                let original = field
                return { field == original }
            }))
        flow.handle(.start)
        try await reaches { capture.receive != nil }
        capture.receive?([3000, -3000])
        try await reaches { flow.state?.live.samples.count == 2 }
        #expect(posted.isEmpty)
        if end == .switchedField { field = 2 }
        flow.handle(end == .interrupted ? .interrupted : .stop)
        try await reaches { flow.canStart }

        #expect(flow.state?.text == "语音草稿")
        #expect(posted == (end == .release ? ["语音草稿"] : []))
        #expect(flow.canInsert == (end != .release))
        if end == .switchedField { #expect(flow.notice == InsertionError.targetChanged.localizedDescription) }
        flow.handle(.stop)
        #expect(posted.count == (end == .release ? 1 : 0))
        await flow.shutdown()
    }

    @Test func editShortcutKeepsTheDraftUntilConfirmationAtTheOriginalField() async throws {
        let capture = FlowCapture()
        var field = 1
        var posted: [String] = []
        var opens = 0
        let flow = VoxloomFlow(settings: .init(), capture: { capture }, recognizer: { _ in FlowRecognizer() },
            corrector: { _ in nil }, insertion: .init(foregroundTarget: { 101 }, canPost: { true },
                paste: { text, _ in posted.append(text); return true }, captureFocus: { _ in
                    let original = field
                    return { field == original }
                }))
        flow.onOpenDraft = { opens += 1 }
        #expect(!flow.requestRecordingEdit())
        flow.handle(.start)
        try await reaches { capture.receive != nil }
        #expect(flow.requestRecordingEdit())
        #expect(opens == 0)
        capture.receive?([3000, -3000])
        try await reaches { flow.state?.live.samples.count == 2 }
        flow.handle(.stop)
        try await reaches { flow.canStart }
        #expect(opens == 1)
        #expect(posted.isEmpty)
        #expect(flow.canInsert)
        flow.edit("已改草稿", basedOn: "语音草稿")

        field = 2
        flow.handle(.confirm)
        #expect(posted.isEmpty)
        #expect(flow.notice == InsertionError.targetChanged.localizedDescription)
        #expect(flow.state?.phase == .editing)
        field = 1
        flow.handle(.confirm)
        #expect(posted == ["已改草稿"])
        await flow.shutdown()
    }

    @Test func cancellingAutomaticInsertionWhileCorrectingKeepsTheDraftEditable() async throws {
        let capture = FlowCapture()
        let finish = AsyncStream<Void>.makeStream()
        defer { finish.continuation.finish() }
        var pasted: [String] = []
        let flow = VoxloomFlow(settings: .init(), capture: { capture }, recognizer: { _ in FlowRecognizer() },
            corrector: { _ in FlowDelayedCorrector(finish: finish.stream) },
            insertion: .init(foregroundTarget: { 101 }, canPost: { true },
                paste: { text, _ in pasted.append(text); return true }, captureFocus: { _ in { true } }))
        flow.handle(.start)
        try await reaches { capture.receive != nil }
        capture.receive?([3000, -3000])
        try await reaches { flow.state?.live.samples.count == 2 }
        flow.handle(.stop)
        try await reaches { flow.state?.correction == .working && flow.state?.live.phase == .idle }
        #expect(pasted.isEmpty)
        #expect(!flow.canStart)
        flow.clearOrCancel()
        finish.continuation.finish()
        try await reaches { flow.state?.text == "校对后的稿件" }
        #expect(pasted.isEmpty)
        #expect(flow.canInsert)
        flow.edit("手动补充", basedOn: "校对后的稿件")
        #expect(flow.state?.text == "手动补充")
        await flow.shutdown()
    }

    @Test func holdReleaseAndConfirmInsertTheEditedDraftForTheSelectedModel() async throws {
        let fixture = FlowCapture()
        var settings = DictationSettings()
        settings.correctsText = false
        settings.model = .whisperTiny
        var models: [RecognitionModel] = []
        var inserted: [String] = []
        let flow = VoxloomFlow(settings: settings, capture: { fixture },
            recognizer: { models.append($0.model); return FlowRecognizer() },
            corrector: { _ in nil }, insertion: .init(foregroundTarget: { 101 }, canPost: { true },
                paste: { text, _ in inserted.append(text); return true }))
        flow.handle(.start)
        try await reaches { fixture.receive != nil }
        fixture.receive?([3000, -3000])
        try await reaches { flow.state?.live.samples.count == 2 }
        flow.handle(.stop)
        try await reaches { flow.canInsert }
        #expect(fixture.receive == nil)
        #expect(flow.state?.text == "语音草稿")
        #expect(models == [.whisperTiny])
        flow.edit("已改草稿", basedOn: "语音草稿")
        flow.handle(.confirm)
        #expect(inserted == ["已改草稿"])
        flow.handle(.confirm)
        #expect(inserted.count == 1)
        await flow.shutdown()
    }

    @Test func repeatedHoldsAppendUntilTheCombinedDraftIsInserted() async throws {
        let capture = FlowCapture()
        var posted: [String] = []
        let flow = VoxloomFlow(settings: .init(), capture: { capture }, recognizer: { _ in FlowRecognizer() },
            corrector: { _ in nil }, insertion: .init(foregroundTarget: { 101 }, canPost: { true },
                paste: { text, _ in posted.append(text); return true }))

        func recordOneSegment() async throws {
            try #require(flow.canStart)
            flow.handle(.start)
            try await reaches { capture.receive != nil }
            #expect(!flow.canInsert)
            capture.receive?([3000, -3000])
            try await reaches { flow.state?.live.samples.count == 2 }
            flow.handle(.stop)
            try await reaches { flow.state?.live.phase == .idle && flow.canInsert }
        }

        try await recordOneSegment()
        flow.edit("手动编辑的前一段", basedOn: "语音草稿")
        try await recordOneSegment()
        let combined = "手动编辑的前一段\n语音草稿"
        #expect(flow.state?.text == combined)
        #expect(posted.isEmpty)
        flow.handle(.start)
        try await reaches { capture.receive != nil }
        #expect(flow.state?.text == combined)
        flow.clearOrCancel()
        try await reaches { capture.receive == nil && flow.canStart }
        #expect(flow.state?.text == combined)
        flow.handle(.confirm)
        #expect(posted == [combined])
        try await recordOneSegment()
        #expect(flow.state?.text == "语音草稿")
        await flow.shutdown()
    }

    @Test(arguments: [true, false])
    func cancellingAHoldRestoresThePreviousDraftAndAllowsAnotherRecording(hasDraft: Bool) async throws {
        let capture = FlowCapture()
        var posted: [String] = []
        var opens = 0
        let flow = VoxloomFlow(settings: .init(), capture: { capture }, recognizer: { _ in FlowRecognizer() },
            corrector: { _ in nil }, insertion: .init(foregroundTarget: { 101 }, canPost: { true },
                paste: { text, _ in posted.append(text); return true }, captureFocus: { _ in { true } }))
        flow.onOpenDraft = { opens += 1 }
        if hasDraft {
            flow.handle(.start)
            try await reaches { capture.receive != nil }
            capture.receive?([3000, -3000])
            try await reaches { flow.state?.live.samples.count == 2 }
            flow.handle(.interrupted)
            try await reaches { flow.canStart }
            flow.edit("上一轮草稿", basedOn: "语音草稿")
        }
        let previous = hasDraft ? "上一轮草稿" : ""
        #expect(!flow.cancelHeldRecording())
        flow.handle(.start)
        try await reaches { capture.receive != nil }
        #expect(flow.requestRecordingEdit())
        capture.receive?([3000, -3000])
        try await reaches { flow.state?.live.samples.count == 2 }
        #expect(flow.cancelHeldRecording())
        flow.handle(.stop)
        try await reaches { capture.receive == nil && flow.canStart }
        #expect(flow.state?.text == previous)
        #expect(opens == 0)
        #expect(posted.isEmpty)

        try await recordShortClip(in: flow, capture: capture)
        #expect(flow.state?.text == (hasDraft ? "上一轮草稿\n语音草稿" : "语音草稿"))
        #expect(posted == (hasDraft ? [] : ["语音草稿"]))
        await flow.shutdown()
    }

    private func recordShortClip(in flow: VoxloomFlow, capture: FlowCapture) async throws {
        flow.handle(.start)
        try await reaches { capture.receive != nil }
        capture.receive?([3000, -3000])
        try await reaches { flow.state?.live.samples.count == 2 }
        flow.handle(.stop)
        try await reaches { flow.canStart }
    }

    private func reaches(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(1))
        while !predicate() && clock.now < end { await Task.yield() }
        try #require(predicate())
    }
}

@MainActor final class FlowCapture: AudioCapturing {
    var receive: (@Sendable ([Int16]) -> Void)?
    func requestAccess() async throws {}
    func start(samples: @escaping @Sendable ([Int16]) -> Void, ended: @escaping @Sendable (String?) -> Void) throws {
        receive = samples
    }
    func stop() { receive = nil }
}

private struct FlowRecognizer: SpeechRecognizer {
    func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
        .init(text: "语音草稿")
    }
}

private actor ResidentFlowRecognizer: SpeechRecognizer {
    private(set) var loaded = false
    private(set) var loads = 0

    func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
        if !loaded {
            loaded = true
            loads += 1
        }
        return .init(text: options.language == .english ? "English draft" : "语音草稿")
    }

    func shutdown() async { loaded = false }
}

private actor ContextSinkRecognizer: SpeechRecognizer {
    private(set) var contexts: [String] = []

    func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
        contexts.append(options.context)
        return .init(text: "语音草稿")
    }
}

private struct FlowDelayedCorrector: TextCorrecting {
    let finish: AsyncStream<Void>

    func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        for await _ in finish { break }
        return .init(text: "校对后的稿件", original: request.text)
    }
}
