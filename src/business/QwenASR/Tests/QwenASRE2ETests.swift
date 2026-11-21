import Foundation
import SpeechFoundation
import SpeechInput
import Testing

private let root = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { path, _ in path.deletingLastPathComponent() }
private let bundleResources = ProcessInfo.processInfo.environment["VOICE_INPUT_DEMO_RESOURCES"].map { URL(fileURLWithPath: $0) }
private let asrExecutable = bundleResources?.appendingPathComponent("qwen-asr-runtime/qwen-asr") ?? root.appendingPathComponent(".runtime/qwen-asr-runtime/qwen-asr")
private let asrModel = bundleResources?.appendingPathComponent("Qwen3-ASR-1.7B-4bit") ?? root.appendingPathComponent("models/Qwen3-ASR-1.7B-4bit")
private let llmExecutable = bundleResources?.appendingPathComponent("llama-completion") ?? root.appendingPathComponent(".runtime/llama-build/bin/llama-completion")
private let llmModel = bundleResources?.appendingPathComponent("Qwen3-4B-Instruct-2507-Q4_K_M.gguf") ?? root.appendingPathComponent("models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")
private let chineseAudio = bundleResources?.appendingPathComponent("chinese.wav") ?? root.appendingPathComponent(".runtime/asr_zh.wav")
private let englishAudio = bundleResources?.appendingPathComponent("english.wav") ?? root.appendingPathComponent(".runtime/whisper.cpp-1.8.2/samples/jfk.wav")

@Suite(.serialized) struct QwenASRE2ETests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: asrModel.appendingPathComponent("model.safetensors").path)))
    func residentASRAndLLMProduceSeparateTextsInTheRealOfflinePipeline() async throws {
        let asr: any SpeechRecognizer = QwenASRRecognizer(configuration: .init(
            executable: asrExecutable, model: asrModel))
        let corrector: any TextCorrecting = QwenTextCorrector(configuration: .init(
            executable: llmExecutable, model: llmModel))
        do {
            let audio = try WAVCodec.decode(Data(contentsOf: chineseAudio))
            let original = try await asr.transcribe(audio, options: .init(language: .chinese))
            let candidate = try await corrector.correct(.init(text: original.text))
            #expect(original.text.contains("交易"))
            #expect(candidate.original == original.text)
            #expect(candidate.text.contains("交易"))
            await asr.shutdown()
        } catch { await asr.shutdown(); throw error }
    }
    @Test(.enabled(if: FileManager.default.fileExists(atPath: asrModel.appendingPathComponent("model.safetensors").path)))
    func realResidentModelTranscribesChineseEnglishAndSilenceViaPublicInterface() async throws {
        let recognizer: any SpeechRecognizer = QwenASRRecognizer(configuration: .init(
            executable: asrExecutable, model: asrModel))
        do {
            let chinese = try WAVCodec.decode(Data(contentsOf: chineseAudio))
            let result = try await recognizer.transcribe(chinese, options: .init(language: .chinese, context: "交易 停滞"))
            #expect(result.text.contains("甚至出现交易几乎停滞的情况"))
            let english = try WAVCodec.decode(Data(contentsOf: englishAudio))
            let en = try await recognizer.transcribe(english, options: .init(language: .english))
            #expect(en.text.lowercased().contains("ask not what your country can do for you"))
            let silence = try await recognizer.transcribe(AudioClip(samples: Array(repeating: 0, count: 16_000)), options: .init(language: .chinese))
            #expect(silence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            await recognizer.shutdown()
        } catch {
            await recognizer.shutdown()
            throw error
        }
    }
}
