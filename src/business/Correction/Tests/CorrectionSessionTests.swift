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
        await settle()
        #expect(session.state == .candidate(.init(text: "最新文字", original: "最新文字")))
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
        #expect(session.state == .idle)
        scheduler.advanceTo(scheduler.clock.addingTimeInterval(0.02))
        await settle()
        #expect(session.state == .candidate(.init(text: "充值额度为10", original: "第一段")))
        session.cancel()
        await settle()
        for index in 0..<4 {
            session.update(.init(text: "持续讲话\(index)"))
            scheduler.advanceTo(scheduler.clock.addingTimeInterval(0.6))
        }
        await settle()
        #expect(session.state == .candidate(.init(text: "充值额度为10", original: "持续讲话3")))
        session.cancel()
        scheduler.advanceTo(scheduler.clock.addingTimeInterval(10))
        await settle()
        #expect(session.state == .idle)
        // A new recording may contain exactly the same words.
        session.update(.init(text: "持续讲话3"))
        scheduler.advanceTo(scheduler.clock.addingTimeInterval(0.81))
        await settle()
        #expect(session.state == .candidate(.init(text: "充值额度为10", original: "持续讲话3")))
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
