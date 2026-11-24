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
    var language: RecognitionLanguage = .automatic
    var correctsText = false
    var usesGPU = true
    var usesInputContext = true
    var usesConversationContext = false
    var usesVoiceIsolation = false
    var vocabulary = ""

    init() {}

    init(defaults: UserDefaults) {
        let saved = defaults.dictionary(forKey: Self.key)
        model = (saved?["model"] as? String).flatMap(RecognitionModel.init(rawValue:)) ?? .qwen
        language = (saved?["language"] as? String).flatMap(RecognitionLanguage.init(rawValue:)) ?? .automatic
        correctsText = saved?["correction"] as? Bool ?? correctsText
        usesGPU = saved?["gpu"] as? Bool ?? true
        usesInputContext = saved?["inputContext"] as? Bool ?? true
        usesConversationContext = saved?["conversationContext"] as? Bool ?? usesConversationContext
        usesVoiceIsolation = saved?["voiceIsolation"] as? Bool ?? usesVoiceIsolation
        vocabulary = saved?["vocabulary"] as? String ?? ""
    }

    func save(to defaults: UserDefaults) {
        defaults.set([
            "model": model.rawValue, "language": language.rawValue, "correction": correctsText,
            "gpu": usesGPU, "vocabulary": vocabulary, "inputContext": usesInputContext,
            "conversationContext": usesConversationContext, "voiceIsolation": usesVoiceIsolation
        ], forKey: Self.key)
    }

    private static let key = "dictation.settings"
}
