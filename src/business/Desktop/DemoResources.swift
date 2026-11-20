import Foundation
import SpeechInput
import SpeechFoundation

public struct DemoResources: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func corrector(useGPU: Bool = true) -> any TextCorrecting {
        QwenTextCorrector(configuration: .init(executable: root.appendingPathComponent("llama-completion"),
            model: root.appendingPathComponent("Qwen3-4B-Instruct-2507-Q4_K_M.gguf"), useGPU: useGPU))
    }
    public func recognizer(model: Int, useGPU: Bool = true) -> any SpeechRecognizer {
        if model == 3 {
            return QwenASRRecognizer(configuration: .init(executable: root.appendingPathComponent("qwen-asr-runtime/qwen-asr"),
                model: root.appendingPathComponent("Qwen3-ASR-1.7B-4bit")))
        }
        let weights = ["ggml-base.bin", "ggml-tiny.bin", "ggml-large-v3-turbo-q5_0.bin"]
        return WhisperRecognizer(configuration: .init(executable: root.appendingPathComponent("whisper-cli"),
            model: root.appendingPathComponent(weights[model]), useGPU: useGPU,
            vadModel: root.appendingPathComponent("ggml-silero-v5.1.2.bin"), flashAttention: useGPU))
    }
    public func sample(english: Bool) throws -> AudioClip {
        try WAVCodec.decode(Data(contentsOf: root.appendingPathComponent(english ? "english.wav" : "chinese.wav")))
    }
}
