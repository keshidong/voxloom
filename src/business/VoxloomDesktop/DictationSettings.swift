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

enum ContextExtractionModel: String, CaseIterable {
    case vocabulary, qwen

    var title: String {
        switch self {
        case .vocabulary: "提取词汇"
        case .qwen: "Qwen3-4B Instruct（最近两条）"
        }
    }
}

struct DictationSettings: Equatable {
    var model: RecognitionModel = .qwen
    var trigger: DictationTrigger = .fn
    var language: RecognitionLanguage = .chinese
    var correctsText = false
    var usesGPU = true
    var usesInputContext = true
    var usesConversationContext = false
    var contextModel: ContextExtractionModel = .qwen
    var usesVoiceIsolation = false
    var vocabulary = ""

    var summarizesConversation: Bool { usesConversationContext && contextModel == .qwen }
    var recognitionPromptByteLimit: Int { summarizesConversation && model == .qwen ? 1536 : model.promptByteLimit }

    init() {}

    init(defaults: UserDefaults) {
        let saved = defaults.dictionary(forKey: Self.key)
        model = (saved?["model"] as? String).flatMap(RecognitionModel.init(rawValue:)) ?? .qwen
        trigger = DictationTrigger(stored: saved?["trigger"] as? [String: Any]) ?? .fn
        language = (saved?["language"] as? String).flatMap(RecognitionLanguage.init(rawValue:)) ?? language
        correctsText = saved?["correction"] as? Bool ?? correctsText
        usesGPU = saved?["gpu"] as? Bool ?? true
        usesInputContext = saved?["inputContext"] as? Bool ?? true
        usesConversationContext = saved?["conversationContext"] as? Bool ?? usesConversationContext
        contextModel = (saved?["contextModel"] as? String).flatMap(ContextExtractionModel.init(rawValue:)) ?? contextModel
        usesVoiceIsolation = saved?["voiceIsolation"] as? Bool ?? usesVoiceIsolation
        vocabulary = saved?["vocabulary"] as? String ?? ""
    }

    func save(to defaults: UserDefaults) {
        defaults.set([
            "model": model.rawValue, "trigger": trigger.stored, "language": language.rawValue, "correction": correctsText,
            "gpu": usesGPU, "vocabulary": vocabulary, "inputContext": usesInputContext,
            "conversationContext": usesConversationContext, "contextModel": contextModel.rawValue,
            "voiceIsolation": usesVoiceIsolation
        ], forKey: Self.key)
    }

    private static let key = "dictation.settings"
}
