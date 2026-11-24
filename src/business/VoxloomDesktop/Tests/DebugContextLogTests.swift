#if DEBUG
import SpeechInput
import Testing
@testable import VoxloomDesktop

@MainActor struct DebugContextLogTests {
    @Test func explainsWhyAnEnabledConversationReturnedZeroMessages() {
        let log = DebugContextLog()
        var settings = DictationSettings()
        settings.usesConversationContext = true
        let id = log.begin(settings: settings, readerAvailable: true, target: "Example App")
        log.record(.init(), for: id, conversationError: .noHistoryArea)
        #expect(log.text.contains("找不到辅助功能标记的聊天记录区域"))
        #expect(log.text.contains("0 条"))
    }

    @Test func displaysTheReadContentAndExactPromptForOnlyTheLatestRecording() {
        let log = DebugContextLog()
        let settings = DictationSettings()
        let first = log.begin(settings: settings, readerAvailable: true, target: "Example Chat")
        log.record(.init(draft: "Previous draft"), for: first)
        let current = log.begin(settings: settings, readerAvailable: true, target: "Example Chat")
        log.record(.init(draft: "Current draft", recentMessages: ["部署 NightlyCompiler"]), for: current)
        log.record(prompt: "Voxloom NightlyCompiler", for: current)
        log.record(prompt: "Late update from another recording", for: first)

        #expect(log.text.contains("Example Chat"))
        #expect(log.text.contains("Current draft"))
        #expect(log.text.contains("部署 NightlyCompiler"))
        #expect(log.text.contains("Voxloom NightlyCompiler"))
        #expect(log.text.contains("/ 512"))
        #expect(!log.text.contains("Previous draft"))
        #expect(!log.text.contains("Late update"))

        log.clear()
        log.record(prompt: "Stale after clear", for: current)
        #expect(!log.text.contains("NightlyCompiler"))
        #expect(!log.text.contains("Stale after clear"))
    }
}
#endif
