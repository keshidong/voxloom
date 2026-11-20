import Foundation
import SpeechFoundation
import SpeechInput
import Testing

private let projectRoot = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { path, _ in path.deletingLastPathComponent() }
private let engine = projectRoot.appendingPathComponent(".runtime/whisper-build/bin/whisper-cli")
private let model = projectRoot.appendingPathComponent("models/ggml-tiny.bin")
private let sample = projectRoot.appendingPathComponent(".runtime/whisper.cpp-1.8.2/samples/jfk.wav")

struct WhisperE2ETests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("models/ggml-large-v3-turbo-q5_0.bin").path)
                   && FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("models/ggml-silero-v5.1.2.bin").path),
                   "Turbo and Silero resources required; execute with access to Metal"))
    func realTurboPreviewAndFinalUseAcceleratedPublicAPI() async throws {
        let audio = try WAVCodec.decode(Data(contentsOf: projectRoot.appendingPathComponent(".runtime/asr_zh.wav")))
        let provider: any SpeechRecognizer = WhisperRecognizer(configuration: .init(executable: engine,
            model: projectRoot.appendingPathComponent("models/ggml-large-v3-turbo-q5_0.bin"),
            vadModel: projectRoot.appendingPathComponent("models/ggml-silero-v5.1.2.bin"), flashAttention: true))
        var results: [[String: Any]] = []
        var final = ""
        for count in [16_000, 32_000, audio.samples.count] {
            let started = ContinuousClock.now
            let result = try await provider.transcribe(AudioClip(samples: Array(audio.samples.prefix(count))), options: .init(language: .chinese))
            let duration = started.duration(to: .now)
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            results.append(["audioSeconds": Double(count) / 16000, "inferenceSeconds": seconds, "text": result.text])
            #expect(result.language == "zh")
            final = result.text
        }
        #expect(final.contains("交易"))
        #expect(final.contains("停滞"))
        let report = projectRoot.appendingPathComponent(".build/reports/turbo-preview-e2e.json")
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: report)
    }
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: engine.path)
                   && FileManager.default.fileExists(atPath: model.path)
                   && FileManager.default.fileExists(atPath: sample.path),
                   "Run scripts/prepare-whisper.sh tiny to install real offline resources"))
    func realWhisperTranscribesAnOfflineRecordingThroughPublicAPI() async throws {
        let audio = try WAVCodec.decode(Data(contentsOf: sample))
        let provider: any SpeechRecognizer = WhisperRecognizer(configuration: .init(executable: engine, model: model, useGPU: false))
        let result = try await provider.transcribe(audio, options: .init(language: .english))
        #expect(result.language == "en")
        #expect(result.text.lowercased().contains("country"))
        #expect(result.text.lowercased().contains("ask"))
    }
}
