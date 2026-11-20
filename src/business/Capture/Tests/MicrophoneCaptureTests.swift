import AVFoundation
import Foundation
@testable import SpeechInput
import Testing

private final class CapturedFrames: @unchecked Sendable {
    let lock = NSLock()
    private var storedCount = 0
    private var storedEnded = false
    var count: Int { lock.lock(); defer { lock.unlock() }; return storedCount }
    var ended: Bool { lock.lock(); defer { lock.unlock() }; return storedEnded }
    func append(_ samples: [Int16]) { lock.lock(); defer { lock.unlock() }; storedCount += samples.count }
    func end() { lock.lock(); defer { lock.unlock() }; storedEnded = true }
}

@MainActor struct MicrophoneCaptureTests {
    @Test func realAVEngineInOfflineModeConvertsFramesAndReportsRouteChanges() async throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 8192)
        var tap: AVAudioNodeTapBlock?
        var tappedFormat: AVAudioFormat?
        let capture = MicrophoneCapture(requestPermission: { true }, isAuthorized: { true },
            makeInput: { (engine, engine.mainMixerNode) }, installTap: { node, format, callback in
                tap = callback
                tappedFormat = format
                node.installTap(onBus: 0, bufferSize: 2048, format: format, block: callback)
            })
        try await capture.requestAccess()
        let values = CapturedFrames()
        try capture.start(samples: { values.append($0) }, ended: { _ in values.end() })
        let sourceFormat = try #require(tappedFormat)
        let input = try #require(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 8192))
        input.frameLength = 8192
        for channel in 0..<Int(sourceFormat.channelCount) {
            for frame in 0..<8192 { input.floatChannelData![channel][frame] = 0.25 }
        }
        // Supply the external device callback explicitly; offline engines do not
        // deliver hardware taps. The engine, conversion and notification path are real.
        let callback = try #require(tap)
        callback(input, AVAudioTime(sampleTime: 0, atRate: sourceFormat.sampleRate))
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        capture.stop(); capture.stop()
        #expect(values.count > 0)
        #expect(values.ended)
    }
}
