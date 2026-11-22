import Foundation
import SpeechFoundation
import SpeechInput
import Testing
@testable import VoxloomDesktop

@MainActor struct VoxloomFlowTests {
    @Test func holdingFnCapturesOneContextAndTurningItOffSkipsTheNextRead() async throws {
        let capture = FlowCapture()
        let recognizer = ContextSinkRecognizer()
        var snapshots = 0
        let flow = VoxloomFlow(settings: .init(), capture: { capture }, recognizer: { _ in recognizer },
            corrector: { _ in nil }, insertion: .init(foregroundTarget: { 101 }, canPost: { false }, paste: { _, _ in false }),
            readInputContext: {
                snapshots += 1
                return { "排查 Voxloom 的输入框" }
            })

        for enabled in [true, false] {
            var settings = flow.settings
            settings.usesInputContext = enabled
            flow.apply(settings)
            flow.handle(.start)
            try await reaches { capture.receive != nil }
            capture.receive?([3000, -3000])
            try await reaches { flow.state?.live.samples.count == 2 }
            flow.handle(.stop)
            try await reaches { flow.canStart }
        }

        let calls = await recognizer.contexts
        try #require(calls.count == 2)
        #expect(snapshots == 1)
        #expect(calls[0].contains("Voxloom"))
        #expect(calls[1].isEmpty)
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
