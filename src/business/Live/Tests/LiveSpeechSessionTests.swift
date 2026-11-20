import Foundation
import SpeechFoundation
import SpeechInput
import Testing
import RxSwift

@MainActor final class FakeCapture: AudioCapturing {
    var sink: (@Sendable ([Int16]) -> Void)?
    var ended: (@Sendable (String?) -> Void)?
    var stopped = false
    var permissionError: (any Error)?
    var startError: (any Error)?
    var holdPermission = false
    var heldPermission: CheckedContinuation<Void, Never>?
    func requestAccess() async throws {
        if let permissionError { throw permissionError }
        if holdPermission { await withCheckedContinuation { heldPermission = $0 } }
    }
    func start(samples: @escaping @Sendable ([Int16]) -> Void, ended: @escaping @Sendable (String?) -> Void) throws {
        if let startError { throw startError }
        sink = samples; self.ended = ended
    }
    func stop() { stopped = true }
}

actor FixedRecognizer: SpeechRecognizer {
    func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
        Transcript(text: "实时中文 English", language: "zh")
    }
}

@MainActor struct LiveSpeechSessionTests {
    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Expected state was not reached")
            await Task.yield()
        }
    }
    @Test func clicksAudioAndVirtualTicksProduceTextBeforeStop() async throws {
        let capture = FakeCapture()
        let clock = HistoricalScheduler(initialClock: Date(timeIntervalSince1970: 0))
        let session = LiveSpeechSession(capture: capture, scheduler: clock)
        session.start(recognizer: FixedRecognizer())
        try await waitUntil { session.state.phase == .recording }
        #expect(session.state.phase == .recording)
        capture.sink?(Array(repeating: 1000, count: 24_000))
        try await waitUntil { session.state.samples.count == 24_000 }
        clock.advanceTo(Date(timeIntervalSince1970: 2))
        try await waitUntil { !session.state.text.isEmpty }
        #expect(session.state.text == "实时中文 English")
        #expect(session.state.phase == .recording)
        session.stop()
        try await waitUntil { session.state.phase == .idle }
        #expect(session.state.phase == .idle)
        #expect(capture.stopped)
        session.clear()
        try await waitUntil { session.state.text.isEmpty }
        await session.shutdown()
    }

    @Test func permissionAndCaptureFailuresAreVisibleAndRecoverable() async throws {
        for permission in [true, false] {
            let capture = FakeCapture()
            if permission { capture.permissionError = CaptureError.denied }
            else { capture.startError = CaptureError.unavailable }
            let session = LiveSpeechSession(capture: capture)
            session.start(recognizer: FixedRecognizer())
            try await waitUntil { session.state.error != nil }
            #expect(session.state.phase == .idle)
            #expect(capture.stopped)
            capture.permissionError = nil; capture.startError = nil
            session.start(recognizer: FixedRecognizer())
            try await waitUntil { session.state.phase == .recording }
            capture.ended?("设备断开")
            try await waitUntil { session.state.error == "设备断开" }
            await session.shutdown()
        }
    }

    @Test func captureCompletionFlushesAndCancelRejectsDelayedAudio() async throws {
        let capture = FakeCapture()
        let session = LiveSpeechSession(capture: capture)
        session.start(recognizer: FixedRecognizer())
        try await waitUntil { session.state.phase == .recording }
        session.start(recognizer: FixedRecognizer())
        capture.sink?([1000, -1000])
        capture.ended?(nil)
        try await waitUntil { session.state.phase == .idle && !session.state.text.isEmpty }
        session.start(recognizer: FixedRecognizer())
        try await waitUntil { session.state.phase == .recording }
        session.cancel()
        try await waitUntil { session.state.phase == .idle }
        capture.sink?([2000])
        await session.shutdown()
        #expect(session.state.samples.isEmpty)
    }

    @Test func quittingDoesNotWaitForAnUnansweredSystemPermissionDialog() async throws {
        let capture = FakeCapture()
        capture.holdPermission = true
        let session = LiveSpeechSession(capture: capture)
        session.start(recognizer: FixedRecognizer())
        try await waitUntil { capture.heldPermission != nil }
        var finished = false
        let quitting = Task { await session.shutdown(); finished = true }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !finished && ContinuousClock.now < deadline { await Task.yield() }
        let finishedBeforeReply = finished
        capture.heldPermission?.resume()
        await quitting.value
        #expect(finishedBeforeReply)
        #expect(capture.stopped)
    }
}
