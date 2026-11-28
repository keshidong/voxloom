import Foundation
import SpeechFoundation
import SpeechInput

struct LocalModels {
    static let qwenVoiceActivityGroup = "qwenVoiceActivity"
    let root: URL
    let downloads: ModelDownloads?
    let omniServer: QwenOmniServer?

    init(root: URL, downloadDirectory: URL? = nil) {
        self.root = root
        let executable = root.appending(path: "llama-server")
        omniServer = FileManager.default.isExecutableFile(atPath: executable.path) ? QwenOmniServer(executable: executable) : nil
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
                model: weightFile("Qwen3-ASR-1.7B-4bit", group: settings.model.rawValue),
                voiceActivity: .init(executable: file("vad-speech-segments"),
                    model: weightFile("ggml-silero-v5.1.2.bin", group: Self.qwenVoiceActivityGroup),
                    workerExecutable: file("voxloom-vad"))))
        case .whisperTurbo: weight = "ggml-large-v3-turbo-q5_0.bin"
        case .whisperBase: weight = "ggml-base.bin"
        case .whisperTiny: weight = "ggml-tiny.bin"
        }
        let group = settings.model.rawValue
        return WhisperRecognizer(configuration: .init(executable: file("whisper-cli"), model: weightFile(weight, group: group),
            useGPU: settings.usesGPU, vadModel: weightFile("ggml-silero-v5.1.2.bin", group: group),
            flashAttention: settings.usesGPU))
    }

    var supportsOmni: Bool {
        guard let group = DictationCorrectionModel.omni.downloadGroup, downloads?.assets[group]?.isEmpty == false else { return false }
        return FileManager.default.isExecutableFile(atPath: file("llama-mtmd-cli").path)
    }

    func audioReviewer(for settings: DictationSettings,
                       onApplicationContextSubmitted: (@Sendable (String) async -> Void)? = nil) -> (any AudioReviewing)? {
        guard settings.correctionModel == .omni, let group = settings.correctionModel.downloadGroup,
              supportsOmni, downloads?.isInstalled(group) == true else { return nil }
        return QwenOmniAudioReviewer(configuration: .init(executable: file("llama-mtmd-cli"),
            model: weightFile("Qwen3-Omni-30B-A3B-Instruct-Q4_K_M.gguf", group: group),
            projector: weightFile("mmproj-Qwen3-Omni-30B-A3B-Instruct-Q8_0.gguf", group: group), useGPU: settings.usesGPU),
            server: omniServer, appContextLog: omniAppContextLog, onApplicationContextSubmitted: onApplicationContextSubmitted)
    }

    private var omniAppContextLog: URL? {
        #if DEBUG
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.voxloom.app.debug"
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs", directoryHint: .isDirectory)
            .appending(path: bundleID, directoryHint: .isDirectory).appending(path: "omni-app-context.json")
        #else
        return nil
        #endif
    }

    func voiceIsolator() -> VoiceIsolator? {
        let executable = file("voice-isolation-runtime/voice-isolation")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return VoiceIsolator(executable: executable, weightsDirectory: downloads?.directory(for: "voiceIsolation"))
    }

    private func weightFile(_ name: String, group: String) -> URL {
        downloads?.directory(for: group).appending(path: name) ?? file(name)
    }

    private func file(_ name: String) -> URL { root.appendingPathComponent(name) }
}
