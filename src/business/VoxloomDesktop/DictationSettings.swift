import Foundation
import SpeechFoundation

enum RecognitionModel: String, CaseIterable {
    case qwen, whisperTurbo, whisperBase, whisperTiny

    var title: String {
        switch self {
        case .qwen: "Qwen3-ASR 1.7B"
        case .whisperTurbo: "Whisper Turbo"
        case .whisperBase: "Whisper Base"
        case .whisperTiny: "Whisper Tiny"
        }
    }
}

struct DictationSettings: Equatable {
    var model: RecognitionModel = .qwen
    var language: RecognitionLanguage = .automatic
    var correctsText = true
    var usesGPU = true
    var usesInputContext = true
    var vocabulary = ""

    init() {}

    init(defaults: UserDefaults) {
        let saved = defaults.dictionary(forKey: Self.key)
        model = (saved?["model"] as? String).flatMap(RecognitionModel.init(rawValue:)) ?? .qwen
        language = (saved?["language"] as? String).flatMap(RecognitionLanguage.init(rawValue:)) ?? .automatic
        correctsText = saved?["correction"] as? Bool ?? true
        usesGPU = saved?["gpu"] as? Bool ?? true
        usesInputContext = saved?["inputContext"] as? Bool ?? true
        vocabulary = saved?["vocabulary"] as? String ?? ""
    }

    func save(to defaults: UserDefaults) {
        defaults.set([
            "model": model.rawValue, "language": language.rawValue, "correction": correctsText,
            "gpu": usesGPU, "vocabulary": vocabulary, "inputContext": usesInputContext
        ], forKey: Self.key)
    }

    private static let key = "dictation.settings"
}
