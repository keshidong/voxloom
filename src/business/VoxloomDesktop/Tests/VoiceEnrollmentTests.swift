import Foundation
import SpeechFoundation
import Testing
@testable import VoxloomDesktop

@MainActor struct VoiceEnrollmentTests {
    @Test func playsTheSavedSampleAndStopsWhenRecordingStarts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = VoiceSampleStore(directory: folder)
        let quiet = try clip(64)
        let normal = try clip(350)
        try store.write(quiet, for: .quiet)
        try store.write(normal, for: .normal)
        let player = TestVoiceSamplePlayer()
        let enrollment = VoiceEnrollment(store: store, makeCapture: { FlowCapture() }, player: player)
        defer { enrollment.cancel() }

        enrollment.togglePlayback(.loud)
        #expect(player.audio == nil)
        enrollment.togglePlayback(.quiet)
        #expect(player.audio == quiet)
        #expect(enrollment.playing == .quiet)
        let firstCompletion = player.completion

        enrollment.togglePlayback(.normal)
        #expect(player.audio == normal)
        firstCompletion?(true)
        #expect(enrollment.playing == .normal)
        player.finish()
        #expect(enrollment.playing == nil)

        enrollment.togglePlayback(.quiet)
        enrollment.togglePlayback(.quiet)
        #expect(player.audio == nil)
        enrollment.togglePlayback(.normal)
        enrollment.toggle(.normal)
        #expect(player.audio == nil)
        #expect(enrollment.playing == nil)
        enrollment.togglePlayback(.quiet)
        #expect(player.audio == nil)
    }

    @Test func reRecordingOneStylePreservesTheOthersAndAShortAttemptKeepsTheOldSample() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = FlowCapture()
        let store = VoiceSampleStore(directory: folder)
        let enrollment = VoiceEnrollment(store: store, makeCapture: { capture })
        let quiet = try clip(64)
        let normal = try clip(350)
        try store.write(quiet, for: .quiet)
        try store.write(normal, for: .normal)

        enrollment.toggle(.quiet)
        try await until { capture.receive != nil }
        capture.receive?([40, -40])
        await Task.yield()
        enrollment.toggle(.quiet)
        #expect(try store.read(.quiet) == quiet)

        enrollment.toggle(.loud)
        try await until { capture.receive != nil }
        let loud = try clip(2500, count: VoiceEnrollment.maximumSamples)
        capture.receive?(loud.samples)
        try await until { enrollment.active == nil }
        #expect(try store.read(.quiet) == quiet)
        #expect(try store.read(.normal) == normal)
        #expect(try store.read(.loud) == loud)

        try store.remove(.normal)
        #expect(try store.read(.normal) == nil)
        #expect(try store.read(.quiet) == quiet)
    }

    private func clip(_ amplitude: Int16, count: Int = VoiceEnrollment.minimumSamples) throws -> AudioClip {
        try AudioClip(samples: (0..<count).map { $0.isMultiple(of: 2) ? amplitude : -amplitude })
    }

    private func until(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !ready() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(ready())
    }
}

@MainActor final class TestVoiceSamplePlayer: VoiceSamplePlaying {
    private(set) var audio: AudioClip?
    private(set) var completion: (@MainActor (Bool) -> Void)?

    func play(_ clip: AudioClip, completion: @escaping @MainActor (Bool) -> Void) throws {
        audio = clip
        self.completion = completion
    }

    func stop() {
        audio = nil
        completion = nil
    }

    func finish() {
        let completed = completion
        stop()
        completed?(true)
    }
}
