import AVFoundation
import Foundation
import SpeechFoundation
import SpeechInput
import RxSwift
import Testing

private final class AudioEvents: @unchecked Sendable {
    let lock = NSLock()
    var values: [Int16] = []
    var ends = 0
    func append(_ samples: [Int16]) { lock.lock(); defer { lock.unlock() }; values += samples }
    func end() { lock.lock(); defer { lock.unlock() }; ends += 1 }
}

@MainActor struct SampleCaptureTests {
    @Test func existingRecordingCanBeRecognizedAgainWithoutRealTimeReplay() throws {
        let values = AudioEvents()
        let audio = try AudioClip(samples: [1, -1])
        let capture = SampleCapture(audio: audio, realtime: false)
        try capture.start(samples: { values.append($0) }, ended: { _ in values.end() })
        #expect(values.values == audio.samples)
        #expect(values.ends == 1)
        capture.stop()
    }
    @Test func virtualTimeDeliversOrderedPCMAndOneCompletionAndStopDisposesTimer() async throws {
        let clock = HistoricalScheduler()
        let values = AudioEvents()
        let audio = try AudioClip(samples: Array(repeating: [Int16(1), -1], count: 1600).flatMap { $0 })
        let capture = SampleCapture(audio: audio, scheduler: clock)
        try await capture.requestAccess()
        try capture.start(samples: { values.append($0) }, ended: { _ in values.end() })
        clock.advanceTo(Date(timeIntervalSince1970: 0.1))
        #expect(values.values.count == 1600)
        clock.advanceTo(Date(timeIntervalSince1970: 1))
        #expect(values.values == audio.samples)
        #expect(values.ends == 1)
        try capture.start(samples: { values.append($0) }, ended: { _ in values.end() })
        capture.stop()
        clock.advanceTo(Date(timeIntervalSince1970: 2))
        #expect(values.ends == 1)
    }

    @Test func microphoneStopIsIdempotentAndMissingPermissionFailsWithoutPrompting() throws {
        let capture = MicrophoneCapture()
        capture.stop(); capture.stop()
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            #expect(throws: CaptureError.self) { try capture.start(samples: { _ in }, ended: { _ in }) }
        }
        for error in [CaptureError.denied, .unavailable, .conversion] { #expect(!error.localizedDescription.isEmpty) }
    }
}
