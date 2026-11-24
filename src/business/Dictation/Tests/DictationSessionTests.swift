import Foundation
import RxSwift
import SpeechFoundation
import SpeechInput
import Testing

@MainActor struct DictationSessionTests {
    @Test func keyboardEditsScheduleCorrectionAndTheNextJobUsesTheLiveRebasedDraft() async throws {
        let clock = HistoricalScheduler(initialClock: Date(timeIntervalSince1970: 0))
        let finish = AsyncStream<Void>.makeStream()
        defer { finish.continuation.finish() }
        let corrector = CollaborativeCorrector(finish: finish.stream)
        let session = DictationSession(live: LiveSpeechSession(capture: DraftCapture()), correctionScheduler: clock)
        session.setCorrector(corrector, vocabulary: "地名")
        session.edit("甲公圆。", basedOn: "")
        clock.advanceTo(clock.clock.addingTimeInterval(0.79))
        #expect(session.state.correction == .idle)
        clock.advanceTo(clock.clock.addingTimeInterval(0.02))
        try await waitUntil { session.state.correction == .working }

        session.edit("甲公圆。甲公圆。", basedOn: session.state.text, replacedRange: NSRange(location: 0, length: 0))
        finish.continuation.finish()
        try await waitUntil { session.state.text == "甲公圆。甲公园。" }
        clock.advanceTo(clock.clock.addingTimeInterval(0.81))
        try await waitUntil {
            if case .candidate(let candidate) = session.state.correction { return candidate.original == "甲公圆。甲公园。" }
            return false
        }
        #expect(await corrector.requests == ["甲公圆。", "甲公圆。甲公园。"])
        await session.shutdown()
    }

    @Test func capturesImmediatelyAndUsesTheSameInputContextForRecognitionAndCorrection() async throws {
        let capture = DraftCapture()
        let field = AsyncStream<String>.makeStream()
        defer { field.continuation.finish() }
        let session = DictationSession(live: LiveSpeechSession(capture: capture), readInputContext: {
            var reader = field.stream.makeAsyncIterator()
            return await reader.next() ?? ""
        })
        let recognizer = ContextRecordingRecognizer()
        let corrector = DraftCorrector()
        session.setCorrector(corrector, vocabulary: "项目词汇 Voxloom")
        session.start(recognizer: recognizer, options: .init(context: "项目词汇 Voxloom"))
        try await waitUntil { capture.sink != nil }
        capture.sink?([1000, -1000])
        try await waitUntil { session.state.live.samples.count == 2 }
        session.stopForAutomaticInsertion()
        let surrounding = "刚讨论 Voxloom 的语音功能。"
        field.continuation.yield(surrounding)
        field.continuation.finish()
        try await waitUntil { session.state.isReadyForAutomaticInsertion }
        let hints = try #require(await recognizer.options.first?.context)
        #expect(hints.contains("项目词汇"))
        #expect(hints.contains("Voxloom"))
        #expect(hints.split(whereSeparator: \.isWhitespace).filter { $0 == "Voxloom" }.count == 1)
        #expect(!hints.contains(surrounding))
        #expect(await corrector.requests == [.init(text: "去公园。", vocabulary: "项目词汇 Voxloom", surroundingText: surrounding)])
        #expect(session.state.text == "去公园。")
        await session.shutdown()
    }

    @Test(arguments: [false, true])
    func automaticInsertionWaitsForFinalCorrectionWithABoundedDeadline(timesOut: Bool) async throws {
        let scheduler = HistoricalScheduler(initialClock: Date(timeIntervalSince1970: 0))
        let capture = DraftCapture()
        let finish = AsyncStream<Void>.makeStream()
        defer { finish.continuation.finish() }
        let live = LiveSpeechSession(capture: capture, scheduler: scheduler)
        let session = DictationSession(live: live, correctionScheduler: scheduler)
        session.setCorrector(DelayedCorrection(finish: finish.stream), vocabulary: "")
        session.start(recognizer: DraftRecognizer())
        try await waitUntil { capture.sink != nil }
        capture.sink?([1000, -1000])
        try await waitUntil { session.state.live.samples.count == 2 }
        session.stopForAutomaticInsertion()
        try await waitUntil { session.state.live.phase == .idle }
        #expect(session.state.text == "去公园。")
        #expect(!session.state.isReadyForAutomaticInsertion)
        if timesOut {
            scheduler.advanceTo(scheduler.clock.addingTimeInterval(2.9))
            #expect(!session.state.isReadyForAutomaticInsertion)
            scheduler.advanceTo(scheduler.clock.addingTimeInterval(0.2))
            #expect(session.state.isReadyForAutomaticInsertion)
            #expect(session.state.text == "去公园。")
        } else {
            finish.continuation.finish()
        }
        try await waitUntil { session.state.isReadyForAutomaticInsertion }
        #expect(session.state.text == (timesOut ? "去公园。" : "去公园！"))
        await session.shutdown()
    }

    @Test func recentMessagesSupplyTermsToRecognitionWhileCorrectionReceivesTheDraft() async throws {
        let capture = DraftCapture()
        let draft = "先检查 LocalDraft。"
        let message = "昨天刚部署了 NightlyCompiler，今天继续。"
        let session = DictationSession(live: LiveSpeechSession(capture: capture),
            readContext: { .init(draft: draft, recentMessages: [message]) }, recognitionPromptByteLimit: 192)
        let recognizer = ContextRecordingRecognizer()
        let corrector = DraftCorrector()
        session.setCorrector(corrector, vocabulary: "Core Audio")
        session.start(recognizer: recognizer, options: .init(context: "Core Audio"))
        try await waitUntil { capture.sink != nil }
        capture.sink?([1000, -1000])
        try await waitUntil { session.state.live.samples.count == 2 }
        session.stopForAutomaticInsertion()
        try await waitUntil { session.state.isReadyForAutomaticInsertion }

        let prompt = try #require(await recognizer.options.first?.context)
        #expect(prompt.hasPrefix("Core Audio"))
        #expect(prompt.contains("LocalDraft"))
        #expect(prompt.contains("NightlyCompiler"))
        #expect(!prompt.contains(message))
        #expect(await corrector.requests == [.init(text: "去公园。", vocabulary: "Core Audio", surroundingText: draft)])
        await session.shutdown()
    }

    @Test func releasingFnLetsTheInFlightEditFinishBeforeTakingTheLatestSnapshot() async throws {
        let clock = HistoricalScheduler(initialClock: Date(timeIntervalSince1970: 0))
        let capture = DraftCapture()
        let finish = AsyncStream<Void>.makeStream()
        defer { finish.continuation.finish() }
        let corrector = CollaborativeCorrector(finish: finish.stream, firstResult: "去公园！")
        let live = LiveSpeechSession(capture: capture, scheduler: clock)
        let session = DictationSession(live: live, correctionScheduler: clock)
        session.setCorrector(corrector, vocabulary: "")
        session.start(recognizer: DraftRecognizer())
        try await waitUntil { capture.sink != nil }

        capture.sink?(Array(repeating: 1000, count: 16_000))
        try await waitUntil { session.state.live.samples.count == 16_000 }
        clock.advanceTo(clock.clock.addingTimeInterval(0.5))
        try await waitUntil { session.state.text == "去公园。" }
        clock.advanceTo(clock.clock.addingTimeInterval(0.81))
        try await waitUntil { session.state.correction == .working }
        try await corrector.waitForFirstRequest()

        capture.sink?([1000])
        try await waitUntil { session.state.live.samples.count == 16_001 }
        session.stopForAutomaticInsertion()
        try await waitUntil { session.state.live.phase == .idle }
        finish.continuation.finish()
        try await waitUntil { session.state.isReadyForAutomaticInsertion }
        #expect(session.state.text == "去公园！顺便买书。")
        #expect(await corrector.requests == ["去公园。", "去公园！顺便买书。"])
        await session.shutdown()
    }

    @Test func continuedRecordingShowsThePreviousDraftAndCorrectsOnlyNewSpeech() async throws {
        let scheduler = HistoricalScheduler(initialClock: Date(timeIntervalSince1970: 0))
        let capture = DraftCapture()
        let live = LiveSpeechSession(capture: capture, scheduler: scheduler)
        let session = DictationSession(live: live, existingText: "这段已经改好。", correctionScheduler: scheduler)
        #expect(session.state.text == "这段已经改好。")
        let corrector = DraftCorrector()
        session.setCorrector(corrector, vocabulary: "公园")
        session.start(recognizer: DraftRecognizer())
        try await waitUntil { capture.sink != nil }
        #expect(session.state.text == "这段已经改好。")
        capture.sink?([1000, -1000])
        try await waitUntil { session.state.live.samples.count == 2 }
        session.stop()
        try await waitUntil { session.state.live.phase == .idle }
        #expect(session.state.text == "这段已经改好。\n去公园。")
        scheduler.advanceTo(scheduler.clock.addingTimeInterval(0.81))
        try await waitUntil {
            if case .candidate = session.state.correction { return true }
            return false
        }
        #expect(await corrector.requests.map(\.text) == ["去公园。"])
        #expect(session.state.text == "这段已经改好。\n去公园。")
        await session.shutdown()
    }

    @Test func confirmationKeepsManualEditsAndFinalSpeechWithoutStartingCorrection() async throws {
        let scheduler = HistoricalScheduler(initialClock: Date(timeIntervalSince1970: 0))
        let capture = DraftCapture()
        let live = LiveSpeechSession(capture: capture, scheduler: scheduler)
        let session = DictationSession(live: live, correctionScheduler: scheduler)
        let corrector = DraftCorrector()
        session.setCorrector(corrector, vocabulary: "Qwen")
        session.start(recognizer: DraftRecognizer())
        try await waitUntil { capture.sink != nil }
        capture.sink?(Array(repeating: 1000, count: 16_000))
        try await waitUntil { session.state.live.samples.count == 16_000 }
        scheduler.advanceTo(scheduler.clock.addingTimeInterval(0.5))
        try await waitUntil { session.state.text == "去公园。" }
        session.edit("去书店。", basedOn: session.state.text)
        capture.sink?([1000])
        try await waitUntil { session.state.live.samples.count == 16_001 }
        session.confirm()
        try await waitUntil { session.state.live.phase == .idle }
        #expect(session.state.confirmedText == "去书店。顺便买书。")
        scheduler.advanceTo(scheduler.clock.addingTimeInterval(6))
        session.confirm()
        session.edit("另一段", basedOn: session.state.text)
        #expect(session.state.confirmedText == "去书店。顺便买书。")
        await session.shutdown()
        #expect(await corrector.requests.isEmpty)
    }

    @Test func cancellingTheContinuationRestoresTheEarlierDraftAndIgnoresLateSpeech() async throws {
        let scheduler = HistoricalScheduler(initialClock: Date(timeIntervalSince1970: 0))
        let capture = DraftCapture()
        let finish = AsyncStream<Void>.makeStream()
        defer { finish.continuation.finish() }
        let session = DictationSession(live: LiveSpeechSession(capture: capture, scheduler: scheduler),
                                       existingText: "已有草稿。")
        session.start(recognizer: LateDraftRecognizer(finish: finish.stream))
        try await waitUntil { capture.sink != nil }
        capture.sink?(Array(repeating: 1000, count: 16_000))
        try await waitUntil { session.state.live.samples.count == 16_000 }
        scheduler.advanceTo(scheduler.clock.addingTimeInterval(0.5))
        try await waitUntil { session.state.text == "已有草稿。\n本轮预览。" }
        capture.sink?([1000])
        try await waitUntil { session.state.live.samples.count == 16_001 }
        session.stop()
        try await waitUntil { session.state.live.phase == .finishing }

        session.cancelRecording()
        #expect(session.state.text == "已有草稿。")
        finish.continuation.finish()
        try await waitUntil { session.state.live.phase == .idle }
        session.confirm()
        #expect(session.state.confirmedText == "已有草稿。")
        await session.shutdown()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
    }
}

@MainActor private final class DraftCapture: AudioCapturing {
    var sink: (@Sendable ([Int16]) -> Void)?
    func requestAccess() async throws {}
    func start(samples: @escaping @Sendable ([Int16]) -> Void, ended: @escaping @Sendable (String?) -> Void) throws {
        sink = samples
    }
    func stop() { sink = nil }
}

private struct DraftRecognizer: SpeechRecognizer {
    func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
        .init(text: audio.samples.count > 16_000 ? "去公园。顺便买书。" : "去公园。")
    }
}

private actor ContextRecordingRecognizer: SpeechRecognizer {
    var options: [RecognitionOptions] = []

    func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
        self.options.append(options)
        return .init(text: "去公园。")
    }
}

private struct LateDraftRecognizer: SpeechRecognizer {
    let finish: AsyncStream<Void>

    func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
        if audio.samples.count <= 16_000 { return .init(text: "本轮预览。") }
        for await _ in finish { break }
        return .init(text: "迟到的结果。")
    }
}

private actor DraftCorrector: TextCorrecting {
    var requests: [CorrectionRequest] = []
    func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        requests.append(request)
        return .init(text: request.text, original: request.text)
    }
}

private actor CollaborativeCorrector: TextCorrecting {
    let finish: AsyncStream<Void>
    let firstResult: String
    var requests: [String] = []

    init(finish: AsyncStream<Void>, firstResult: String = "甲公园。") {
        self.finish = finish
        self.firstResult = firstResult
    }

    func waitForFirstRequest() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while requests.isEmpty {
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
    }

    func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        requests.append(request.text)
        if requests.count == 1 {
            for await _ in finish { break }
            return .init(text: firstResult, original: request.text)
        }
        return .init(text: request.text, original: request.text)
    }
}

private struct DelayedCorrection: TextCorrecting {
    let finish: AsyncStream<Void>

    func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        for await _ in finish { break }
        return .init(text: "去公园！", original: request.text)
    }
}
