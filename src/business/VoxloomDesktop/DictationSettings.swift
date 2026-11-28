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

enum DictationCorrectionModel: String, CaseIterable {
    case text, off, omni

    var title: String {
        switch self {
        case .text: "Qwen3-4B Instruct"
        case .off: "关闭纠错"
        case .omni: "Qwen3-Omni 音频复核"
        }
    }

    var downloadGroup: String? {
        switch self {
        case .text: "correction"
        case .off: nil
        case .omni: "omniCorrection"
        }
    }
}

struct DictationSettings: Equatable {
    var model: RecognitionModel = .qwen
    var trigger: DictationTrigger = .fn
    var language: RecognitionLanguage = .chinese
    var correctionModel: DictationCorrectionModel = .off
    var correctsText: Bool {
        get { correctionModel == .text }
        set { correctionModel = newValue ? .text : .off }
    }
    var usesGPU = true
    var usesVoiceIsolation = false
    var vocabulary = ""

    init() {}

    init(defaults: UserDefaults) {
        let saved = defaults.dictionary(forKey: Self.key)
        model = (saved?["model"] as? String).flatMap(RecognitionModel.init(rawValue:)) ?? .qwen
        trigger = DictationTrigger(stored: saved?["trigger"] as? [String: Any]) ?? .fn
        language = (saved?["language"] as? String).flatMap(RecognitionLanguage.init(rawValue:)) ?? language
        correctionModel = (saved?["correctionModel"] as? String).flatMap(DictationCorrectionModel.init(rawValue:))
            ?? (saved?["correction"] as? Bool == true ? .text : .off)
        usesGPU = saved?["gpu"] as? Bool ?? true
        usesVoiceIsolation = saved?["voiceIsolation"] as? Bool ?? usesVoiceIsolation
        vocabulary = saved?["vocabulary"] as? String ?? ""
    }

    func save(to defaults: UserDefaults) {
        defaults.set([
            "model": model.rawValue, "trigger": trigger.stored, "language": language.rawValue, "correction": correctsText,
            "correctionModel": correctionModel.rawValue,
            "gpu": usesGPU, "vocabulary": vocabulary,
            "voiceIsolation": usesVoiceIsolation
        ], forKey: Self.key)
    }

    private static let key = "dictation.settings"
}
