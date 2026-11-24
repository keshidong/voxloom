import Foundation
import Testing
@testable import VoxloomDesktop

struct DictationSettingsTests {
    @Test func correctionIsOffByDefaultAndCanBeEnabled() throws {
        let identifier = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: identifier))
        defer { defaults.removePersistentDomain(forName: identifier) }

        #expect(!DictationSettings().correctsText)
        #expect(!DictationSettings(defaults: defaults).correctsText)

        defaults.set(["language": "zh", "inputContext": true], forKey: "dictation.settings")
        var settings = DictationSettings(defaults: defaults)
        #expect(!settings.correctsText)
        #expect(settings.usesInputContext)
        #expect(!settings.usesConversationContext)

        settings.correctsText = true
        settings.save(to: defaults)
        #expect(DictationSettings(defaults: defaults).correctsText)
    }

    @Test func savedModelsAndOptionsLoadIntoANewSettingsInstance() throws {
        let identifier = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: identifier))
        defer { defaults.removePersistentDomain(forName: identifier) }
        #expect(DictationSettings(defaults: defaults) == DictationSettings())
        var settings = DictationSettings()
        settings.model = .whisperTurbo
        settings.language = .english
        settings.correctsText = false
        settings.usesGPU = false
        settings.usesInputContext = false
        settings.usesConversationContext = true
        settings.usesVoiceIsolation = true
        settings.vocabulary = "Core Audio"
        settings.save(to: defaults)
        #expect(DictationSettings(defaults: try #require(UserDefaults(suiteName: identifier))) == settings)
    }
}
