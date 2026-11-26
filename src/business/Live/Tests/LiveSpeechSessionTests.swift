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
    private(set) var didShutdown = false

    func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
        Transcript(text: "实时中文 English", language: "zh")
    }

    func shutdown() async { didShutdown = true }
}

@MainActor struct LiveSpeechSessionTests {
    @Test(arguments: [true, false])
    func isolatedPreviewUsesFilteredAudioAndStillFinalizesTheOriginalRecording(previewAvailable: Bool) async throws {
        let capture = FakeCapture()
        let recognizer = AudioRecorder()
        let raw = Array(repeating: Int16(1000), count: AudioClip.sampleRate * 3 / 4)
        let session = LiveSpeechSession(capture: capture, prepareFinalAudio: { clip in
            #expect(clip.samples == raw)
            return try AudioClip(samples: [321, -321])
        }, preparePreviewAudio: { clip in
            #expect(clip.samples == raw)
            guard previewAvailable else { throw RecognitionError.invalidResult }
            return try AudioClip(samples: [123, -123])
        })
        session.start(recognizer: recognizer)
        try await waitUntil { session.state.phase == .recording }
        capture.sink?(raw)
        try await waitUntil { session.state.submitted == raw.count && !session.state.busy }
        #expect(session.state.phase == .recording)
        #expect(await recognizer.clips == (previewAvailable ? [[123, -123]] : []))

        session.stop()
        try await waitUntil { session.state.phase == .idle }
        #expect(await recognizer.clips == (previewAvailable ? [[123, -123], [321, -321]] : [[321, -321]]))
        await session.shutdown()
    }

    @Test(arguments: [true, false])
    func finalAudioPreparationSkipsRawPreviewsAndSilentResults(containsTarget: Bool) async throws {
        let capture = FakeCapture()
        let recognizer = AudioRecorder()
        let session = LiveSpeechSession(capture: capture, prepareFinalAudio: { _ in
            try AudioClip(samples: containsTarget ? [321, -321] : [])
        })
        session.start(recognizer: recognizer)
        try await waitUntil { session.state.phase == .recording }
        capture.sink?(Array(repeating: 1000, count: 16_000))
        try await waitUntil { session.state.samples.count == 16_000 }
        let hasRawPreview = session.state.busy
        #expect(!hasRawPreview)
        session.stop()
        try await waitUntil { session.state.phase == .idle }
        let calls = await recognizer.clips
        let expected: [[Int16]] = containsTarget ? [[321, -321]] : []
        #expect(calls == expected)
        await session.shutdown()
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Expected state was not reached")
            await Task.yield()
        }
    }
    @Test func audioProducesAndRefreshesThePreviewWithoutAdvancingTheClock() async throws {
        let capture = FakeCapture()
        let clock = HistoricalScheduler(initialClock: Date(timeIntervalSince1970: 0))
        let session = LiveSpeechSession(capture: capture, scheduler: clock)
        session.start(recognizer: FixedRecognizer())
        try await waitUntil { session.state.phase == .recording }
        #expect(session.state.phase == .recording)
        let firstSamples = AudioClip.sampleRate
        capture.sink?(Array(repeating: 1000, count: firstSamples))
        try await waitUntil { !session.state.text.isEmpty }
        #expect(session.state.text == "实时中文 English")
        #expect(session.state.phase == .recording)
        let additionalSamples = AudioClip.sampleRate / 2
        capture.sink?(Array(repeating: 1000, count: additionalSamples))
        try await waitUntil { session.state.submitted == firstSamples + additionalSamples && !session.state.busy }
        session.stop()
        try await waitUntil { session.state.phase == .idle }
        #expect(session.state.phase == .idle)
        #expect(capture.stopped)
        session.clear()
        try await waitUntil { session.state.text.isEmpty }
        await session.shutdown()
    }

    @Test(arguments: [true, false])
    func stoppingASessionClosesOnlyTheRecognizerItOwns(ownsRecognizer: Bool) async throws {
        let recognizer = FixedRecognizer()
        let session = LiveSpeechSession(capture: FakeCapture(), ownsRecognizer: ownsRecognizer)
        session.start(recognizer: recognizer)
        try await waitUntil { session.state.phase == .recording }
        await session.shutdown()
        #expect(await recognizer.didShutdown == ownsRecognizer)
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

private actor AudioRecorder: SpeechRecognizer {
    private(set) var clips: [[Int16]] = []

    func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
        clips.append(audio.samples)
        return Transcript(text: "voice")
    }
}
