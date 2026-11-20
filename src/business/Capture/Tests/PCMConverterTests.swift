import AVFoundation
@testable import SpeechInput
import Testing

struct PCMConverterTests {
    @Test func continuous24kAirPodsStyleBuffersPreserveDurationAndSpeechBandSignal() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false))
        let converter = try PCMConverter(format: format)
        var output: [Int16] = []
        for start in stride(from: 0, to: 24000, by: 2048) {
            let count = min(2048, 24000 - start)
            let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            input.frameLength = AVAudioFrameCount(count)
            for frame in 0..<count { input.floatChannelData![0][frame] = Float(sin(Double(start + frame) * 2 * .pi * 1000 / 24000) * 0.25) }
            output += try converter.convert(input)
        }
        #expect(output.count == 16000)
        // Resampling has filter startup transients; measure tone coherence rather
        // than counting the first few zero crossings as full cycles.
        var sine = 0.0, cosine = 0.0, energy = 0.0
        for (index, sample) in output.enumerated() {
            let value = Double(sample)
            let angle = Double(index) * 2 * .pi * 1000 / 16000
            sine += value * sin(angle)
            cosine += value * cos(angle)
            energy += value * value
        }
        let coherentFraction = 2 * (sine * sine + cosine * cosine) / (Double(output.count) * energy)
        #expect(coherentFraction > 0.98)
    }
    @Test func convertsActualStereoFloatAudioToMono16kPCM() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        for channel in 0..<2 { for frame in 0..<4800 { buffer.floatChannelData![channel][frame] = 0.25 } }
        let output = try PCMConverter(format: format).convert(buffer)
        #expect(output.count == 1600)
        #expect(output.contains { $0 > 1000 })
    }

    @Test func emptyAndWrongFormatBuffersAreHandledWithoutCallingTheConverterWithInvalidInput() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
        let converter = try PCMConverter(format: format)
        let empty = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        #expect(try converter.convert(empty).isEmpty)
        let other = try #require(AVAudioPCMBuffer(pcmFormat: .init(standardFormatWithSampleRate: 44100, channels: 1)!, frameCapacity: 8))
        #expect(throws: CaptureError.self) { try converter.convert(other) }
    }
}
