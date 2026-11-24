import Foundation
import SpeechFoundation
import SpeechInput

struct LocalModels {
    let root: URL
    let downloads: ModelDownloads?

    init(root: URL, downloadDirectory: URL? = nil) {
        self.root = root
        if let downloadDirectory,
           let manifest = try? Data(contentsOf: root.appending(path: "model-downloads.json")),
           let assets = try? JSONDecoder().decode([String: [ModelDownloads.Asset]].self, from: manifest) {
            downloads = ModelDownloads(root: downloadDirectory, assets: assets)
        } else {
            downloads = nil
        }
    }

    func canRecognize(_ model: RecognitionModel) -> Bool {
        downloads?.isInstalled(model.rawValue) ?? true
    }

    func recognizer(for settings: DictationSettings) -> any SpeechRecognizer {
        let weight: String
        switch settings.model {
        case .qwen:
            return QwenASRRecognizer(configuration: .init(executable: file("qwen-asr-runtime/qwen-asr"),
                model: weightFile("Qwen3-ASR-1.7B-4bit", group: settings.model.rawValue)))
        case .whisperTurbo: weight = "ggml-large-v3-turbo-q5_0.bin"
        case .whisperBase: weight = "ggml-base.bin"
        case .whisperTiny: weight = "ggml-tiny.bin"
        }
        let group = settings.model.rawValue
        return WhisperRecognizer(configuration: .init(executable: file("whisper-cli"), model: weightFile(weight, group: group),
            useGPU: settings.usesGPU, vadModel: weightFile("ggml-silero-v5.1.2.bin", group: group),
            flashAttention: settings.usesGPU))
    }

    func corrector(for settings: DictationSettings) -> (any TextCorrecting)? {
        guard settings.correctsText, downloads?.isInstalled("correction") ?? true else { return nil }
        return QwenTextCorrector(configuration: .init(executable: file("llama-completion"), model: qwenTextWeights,
            useGPU: settings.usesGPU, mode: .interactive))
    }

    func contextSummarizer(for settings: DictationSettings) -> (any RecognitionContextSummarizing)? {
        guard settings.summarizesConversation, downloads?.isInstalled("correction") ?? true else { return nil }
        return QwenContextSummarizer(executable: file("llama-completion"), model: qwenTextWeights, useGPU: settings.usesGPU)
    }

    func voiceIsolator() -> VoiceIsolator? {
        let executable = file("voice-isolation-runtime/voice-isolation")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return VoiceIsolator(executable: executable, weightsDirectory: downloads?.directory(for: "voiceIsolation"))
    }

    private var qwenTextWeights: URL { weightFile("Qwen3-4B-Instruct-2507-Q4_K_M.gguf", group: "correction") }

    private func weightFile(_ name: String, group: String) -> URL {
        downloads?.directory(for: group).appending(path: name) ?? file(name)
    }

    private func file(_ name: String) -> URL { root.appendingPathComponent(name) }
}
