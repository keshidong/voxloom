import Foundation
import SpeechFoundation
import SpeechInput
import Testing
import RxSwift

private struct ProposedCorrector: TextCorrecting {
    func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate { .init(text: "充值额度为10", original: request.text) }
}

@MainActor struct CorrectionSessionTests {
    @Test func invalidEngineResponseShowsAnActionableMessageInsteadOfAnInternalCaseName() async throws {
        let session = CorrectionSession(corrector: InvalidResponseCorrector())
        session.run(.init(text: "明天开会"))
        await settle()
        guard case .failed(let message) = session.state else { Issue.record("Expected a visible failure"); return }
        #expect(!message.contains("invalidResult"))
        #expect(message.contains("完整"))
        await session.shutdown()
    }
    @Test func replacementWaitsForCancelledEngineCleanupBeforeStartingLatestRequest() async throws {
        let corrector = CleanupCorrector()
        let session = CorrectionSession(corrector: corrector)
        session.run(.init(text: "旧文字"))
        while !(await corrector.started) { await Task.yield() }
        session.run(.init(text: "最新文字"))
        while !(await corrector.cleaning) { await Task.yield() }
        await settle()
        await corrector.finishCleanup()
        var completed = session.states
            .filter { $0 != .idle && $0 != .working }
            .timeout(.seconds(2), scheduler: MainScheduler.instance)
            .take(1).values.makeAsyncIterator()
        let result = try await completed.next()
        #expect(result == .candidate(.init(text: "最新文字", original: "最新文字")))
        await session.shutdown()
    }
    @Test func failureCanBeRetriedAndCancelledOldResultsCannotReplaceNewText() async throws {
        let corrector = FailingOnceCorrector()
        let session = CorrectionSession(corrector: corrector)
        session.run(.init(text: "同一句"))
        await settle()
        if case .failed = session.state {} else { Issue.record("Expected visible correction failure") }
        session.run(.init(text: "同一句"))
        await settle()
        #expect(session.state == .candidate(.init(text: "同一句", original: "同一句")))
        session.run(.init(text: "延迟结果"))
        while !(await corrector.waiting) { await Task.yield() }
        session.cancel()
        session.run(.init(text: "新录音"))
        await settle()
        await corrector.release()
        await settle()
        #expect(session.state == .candidate(.init(text: "新录音", original: "新录音")))
        await session.shutdown()
    }
    @Test func recordingCorrectionsUseStableTextAndPeriodicLatestTextWithoutWaitingForStop() async throws {
        let scheduler = HistoricalScheduler(initialClock: Date(timeIntervalSince1970: 0))
        let session = CorrectionSession(corrector: ProposedCorrector(), scheduler: scheduler)
        session.update(.init(text: "第一段"))
        scheduler.advanceTo(scheduler.clock.addingTimeInterval(0.79))
        await settle()
        #expect(session.state == .idle)
        scheduler.advanceTo(scheduler.clock.addingTimeInterval(0.02))
        await settle()
        #expect(session.state == .candidate(.init(text: "充值额度为10", original: "第一段")))
        session.cancel()
        await settle()
        for index in 0..<7 {
            session.update(.init(text: "持续讲话\(index)"))
            scheduler.advanceTo(scheduler.clock.addingTimeInterval(0.42))
        }
        #expect(session.state == .idle)
        scheduler.advanceTo(scheduler.clock.addingTimeInterval(0.07))
        await settle()
        #expect(session.state == .candidate(.init(text: "充值额度为10", original: "持续讲话6")))
        session.cancel()
        scheduler.advanceTo(scheduler.clock.addingTimeInterval(10))
        await settle()
        #expect(session.state == .idle)
        // A new recording may contain exactly the same words.
        session.update(.init(text: "持续讲话6"))
        scheduler.advanceTo(scheduler.clock.addingTimeInterval(0.81))
        await settle()
        #expect(session.state == .candidate(.init(text: "充值额度为10", original: "持续讲话6")))
        await session.shutdown()
    }

    @Test func textUpdatesKeepTheActiveCorrectionAndOnlyRunTheNewestWaitingText() async throws {
        let scheduler = HistoricalScheduler(initialClock: Date(timeIntervalSince1970: 0))
        let corrector = GatedCorrector()
        let session = CorrectionSession(corrector: corrector, scheduler: scheduler)
        var delivered: [String] = []
        let observation = session.states.subscribe(onNext: {
            if case .candidate(let candidate) = $0 { delivered.append(candidate.original) }
        })
        defer { observation.dispose() }
        session.update(.init(text: "第一段"))
        scheduler.advanceTo(scheduler.clock.addingTimeInterval(0.8))
        while !(await corrector.started) { await Task.yield() }
        for text in ["途中更新", "最新文字"] {
            session.update(.init(text: text))
            scheduler.advanceTo(scheduler.clock.addingTimeInterval(0.8))
        }
        await corrector.release()
        await settle()
        #expect(delivered == ["第一段", "最新文字"])
        #expect(await corrector.requests == ["第一段", "最新文字"])
        await session.shutdown()
    }

    @Test(arguments: [false, true])
    func newInputWhileTheEngineIsBusyRestartsQuietTimeButNotTheThreeSecondLimit(atDeadline: Bool) async throws {
        let scheduler = HistoricalScheduler(initialClock: Date(timeIntervalSince1970: 0))
        let corrector = GatedCorrector()
        let session = CorrectionSession(corrector: corrector, scheduler: scheduler)
        session.run(.init(text: "第一稿"))
        while !(await corrector.started) { await Task.yield() }

        session.update(.init(text: "下一稿"))
        scheduler.advanceTo(scheduler.clock.addingTimeInterval(atDeadline ? 3.01 : 0.81))
        session.update(.init(text: "更新后的下一稿"))
        await corrector.release()
        await settle()

        if !atDeadline {
            #expect(await corrector.requests == ["第一稿"])
            scheduler.advanceTo(scheduler.clock.addingTimeInterval(0.79))
            await settle()
            #expect(await corrector.requests == ["第一稿"])
            scheduler.advanceTo(scheduler.clock.addingTimeInterval(0.02))
            await settle()
        }
        #expect(await corrector.requests == ["第一稿", "更新后的下一稿"])
        await session.shutdown()
    }

    @Test func finalCorrectionSkipsTheQuietTimerAndReusesTheSameRequest() async {
        let scheduler = HistoricalScheduler(initialClock: Date(timeIntervalSince1970: 0))
        let corrector = GatedCorrector()
        let session = CorrectionSession(corrector: corrector, scheduler: scheduler)
        let final = CorrectionRequest(text: "最终转录。")
        session.update(.init(text: "未完成的转录"))
        #expect(session.prepareFinal(final))
        await settle()
        #expect(await corrector.requests == [final.text])
        #expect(session.prepareFinal(final))
        await corrector.release()
        await settle()
        #expect(!session.prepareFinal(final))
        scheduler.advanceTo(scheduler.clock.addingTimeInterval(6))
        await settle()
        #expect(await corrector.requests == [final.text])
        await corrector.release()
        await session.shutdown()
    }
    private func settle() async { for _ in 0..<200 { await Task.yield() } }
    @Test func finalTextProducesASeparateCandidateAndCancelResetsTheSession() async throws {
        let session = CorrectionSession(corrector: ProposedCorrector())
        session.run(.init(text: "充斥额图为10"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while session.state == .idle && ContinuousClock.now < deadline { await Task.yield() }
        #expect(session.state != .idle)
        while session.state == .working && ContinuousClock.now < deadline { await Task.yield() }
        #expect(session.state == .candidate(.init(text: "充值额度为10", original: "充斥额图为10")))
        session.cancel()
        for _ in 0..<50 { await Task.yield() }
        #expect(session.state == .idle)
        await session.shutdown()
    }
}

private actor FailingOnceCorrector: TextCorrecting {
    var failed = false
    var waiting = false
    var continuation: CheckedContinuation<Void, Never>?
    func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        if !failed { failed = true; throw CorrectionError.engineUnavailable }
        if request.text == "延迟结果" {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
        }
        return .init(text: request.text, original: request.text)
    }
    func release() { continuation?.resume(); continuation = nil }
}

private struct InvalidResponseCorrector: TextCorrecting {
    func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate { throw CorrectionError.invalidResult }
}

private actor GatedCorrector: TextCorrecting {
    var requests: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?
    var started: Bool { continuation != nil }

    func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        requests.append(request.text)
        if requests.count == 1 { await withCheckedContinuation { continuation = $0 } }
        return .init(text: request.text, original: request.text)
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor CleanupCorrector: TextCorrecting {
    var busy = false
    var started = false
    var cleaning = false
    var continuation: CheckedContinuation<Void, Never>?
    func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        guard !busy else { throw CorrectionError.busy }
        busy = true
        defer { busy = false }
        if request.text == "旧文字" {
            started = true
            do { try await Task.sleep(for: .seconds(60)) }
            catch {
                cleaning = true
                await withCheckedContinuation { continuation = $0 }
                throw CancellationError()
            }
        }
        return .init(text: request.text, original: request.text)
    }
    func finishCleanup() { continuation?.resume(); continuation = nil }
}
