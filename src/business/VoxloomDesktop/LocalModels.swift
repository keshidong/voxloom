import Foundation
import SpeechFoundation
import SpeechInput

struct LocalModels {
    let root: URL

    func recognizer(for settings: DictationSettings) -> any SpeechRecognizer {
        let weight: String
        switch settings.model {
        case .qwen:
            return QwenASRRecognizer(configuration: .init(executable: file("qwen-asr-runtime/qwen-asr"),
                                                          model: file("Qwen3-ASR-1.7B-4bit")))
        case .whisperTurbo: weight = "ggml-large-v3-turbo-q5_0.bin"
        case .whisperBase: weight = "ggml-base.bin"
        case .whisperTiny: weight = "ggml-tiny.bin"
        }
        return WhisperRecognizer(configuration: .init(executable: file("whisper-cli"), model: file(weight),
            useGPU: settings.usesGPU, vadModel: file("ggml-silero-v5.1.2.bin"), flashAttention: settings.usesGPU))
    }

    func corrector(for settings: DictationSettings) -> (any TextCorrecting)? {
        guard settings.correctsText else { return nil }
        return QwenTextCorrector(configuration: .init(executable: file("llama-completion"),
            model: file("Qwen3-4B-Instruct-2507-Q4_K_M.gguf"), useGPU: settings.usesGPU, mode: .interactive))
    }

    func sample(for settings: DictationSettings) throws -> AudioClip {
        try WAVCodec.decode(Data(contentsOf: file(settings.language == .english ? "english.wav" : "chinese.wav")))
    }

    private func file(_ name: String) -> URL { root.appendingPathComponent(name) }
}
