import Foundation
import SpeechFoundation

enum RecognitionModel: String, CaseIterable {
    case qwen, whisperTurbo, whisperBase, whisperTiny

    var promptByteLimit: Int { self == .qwen ? 512 : 192 }

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
    var trigger: DictationTrigger = .fn
    var language: RecognitionLanguage = .chinese
    var correctsText = false
    var usesGPU = true
    var usesVoiceIsolation = false
    var vocabulary = ""

    init() {}

    init(defaults: UserDefaults) {
        let saved = defaults.dictionary(forKey: Self.key)
        model = (saved?["model"] as? String).flatMap(RecognitionModel.init(rawValue:)) ?? .qwen
        trigger = DictationTrigger(stored: saved?["trigger"] as? [String: Any]) ?? .fn
        language = (saved?["language"] as? String).flatMap(RecognitionLanguage.init(rawValue:)) ?? language
        correctsText = saved?["correction"] as? Bool ?? correctsText
        usesGPU = saved?["gpu"] as? Bool ?? true
        usesVoiceIsolation = saved?["voiceIsolation"] as? Bool ?? usesVoiceIsolation
        vocabulary = saved?["vocabulary"] as? String ?? ""
    }

    func save(to defaults: UserDefaults) {
        defaults.set([
            "model": model.rawValue, "trigger": trigger.stored, "language": language.rawValue, "correction": correctsText,
            "gpu": usesGPU, "vocabulary": vocabulary,
            "voiceIsolation": usesVoiceIsolation
        ], forKey: Self.key)
    }

    private static let key = "dictation.settings"
}
