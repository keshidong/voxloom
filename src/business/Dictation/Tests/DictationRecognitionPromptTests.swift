import Foundation
import Testing
@testable import SpeechInput

struct DictationRecognitionPromptTests {
    @Test func givesRecognitionTheOriginalConversationCurrentTaskAndTranscriptionGuidance() throws {
        let messages = ["先检查  MLX Audio 的模型加载。", "接下来用同一批录音测 Qwen3-ASR。\n先测中英混说。"]
        let summary = "正在排查模型加载耗时，下一步对比中英混说转写。"
        let prompt = DictationRecognitionPrompt.withConversation(manual: "Voxloom", messages: messages,
            summary: summary, additionalTerms: "MLX Audio Qwen3-ASR", byteLimit: 1536)

        let context = try CapturedConversationPrompt.decode(prompt)
        #expect(context.recentMessages == messages)
        #expect(context.currentActivity == summary)
        #expect(context.asrHints?.instruction?.contains("按当前录音转写") == true)
        #expect(context.asrHints?.terms == "Voxloom MLX Audio Qwen3-ASR")
        #expect(prompt.utf8.count <= 1536)
    }

    @Test func dropsAnOverBudgetMessageWithoutChangingTheOtherOriginal() throws {
        let older = "旧消息：" + String(repeating: "测试", count: 100)
        let latest = "最新  MLX Audio\n继续测试。"
        let prompt = DictationRecognitionPrompt.withConversation(manual: "Voxloom", messages: [older, latest],
            summary: "正在测试转写。", additionalTerms: "ASR", byteLimit: 120)
        #expect(try CapturedConversationPrompt.decode(prompt).recentMessages == [latest])
        #expect(prompt.utf8.count <= 120)
    }

    @Test func keepsRecentTechnicalTermsWhenMessagesContainLotsOfOrdinaryWords() {
        let newest = "NightlyCompiler is ready and the team should see when the next release ships after lunch before we meet with the other team later today"
        let terms = DictationRecognitionPrompt.terms(
            draft: "让我们检查 Voxloom。", recentMessages: ["PreviousIndexer", newest]
        )
        #expect(terms.contains("Voxloom"))
        #expect(terms.contains("NightlyCompiler"))
        #expect(terms.firstIndex(of: "NightlyCompiler").map { $0 < 8 } == true)
        #expect(terms.count <= 16)
    }
}

struct CapturedConversationPrompt: Decodable {
    struct Hints: Decodable {
        let instruction: String?
        let terms: String?
    }

    let currentActivity: String?
    let recentMessages: [String]?
    let asrHints: Hints?

    static func decode(_ prompt: String) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Self.self, from: Data(prompt.utf8))
    }
}
