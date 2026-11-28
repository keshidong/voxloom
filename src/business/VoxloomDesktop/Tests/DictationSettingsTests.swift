import Foundation
import Testing
@testable import VoxloomDesktop

struct DictationSettingsTests {
    @Test func recognitionDefaultsToChineseAndKeepsAnExplicitLanguage() throws {
        let identifier = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: identifier))
        defer { defaults.removePersistentDomain(forName: identifier) }

        #expect(DictationSettings().language == .chinese)
        #expect(DictationSettings(defaults: defaults).language == .chinese)
        defaults.set(["language": "unknown"], forKey: "dictation.settings")
        #expect(DictationSettings(defaults: defaults).language == .chinese)

        var selected = DictationSettings()
        selected.language = .automatic
        selected.save(to: defaults)
        #expect(DictationSettings(defaults: defaults).language == .automatic)
    }

    @Test func correctionIsOffByDefaultAndCanBeEnabled() throws {
        let identifier = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: identifier))
        defer { defaults.removePersistentDomain(forName: identifier) }

        #expect(DictationSettings().correctionModel == .off)
        #expect(DictationSettings(defaults: defaults).correctionModel == .off)

        defaults.set(["language": "zh"], forKey: "dictation.settings")
        var settings = DictationSettings(defaults: defaults)
        #expect(settings.correctionModel == .off)

        settings.correctionModel = .omni
        settings.save(to: defaults)
        #expect(DictationSettings(defaults: defaults).correctionModel == .omni)
    }

    @Test func retiredTextCorrectionSettingsLoadWithCorrectionOff() throws {
        let identifier = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: identifier))
        defer { defaults.removePersistentDomain(forName: identifier) }

        defaults.set(["correctionModel": "text", "correction": true], forKey: "dictation.settings")
        #expect(DictationSettings(defaults: defaults).correctionModel == .off)

        defaults.set(["correction": true], forKey: "dictation.settings")
        #expect(DictationSettings(defaults: defaults).correctionModel == .off)

        defaults.set(["correctionModel": "unknown"], forKey: "dictation.settings")
        #expect(DictationSettings(defaults: defaults).correctionModel == .off)

        defaults.set(["correctionModel": "omni", "correction": true], forKey: "dictation.settings")
        #expect(DictationSettings(defaults: defaults).correctionModel == .omni)
    }

    @Test func savedModelsAndOptionsLoadIntoANewSettingsInstance() throws {
        let identifier = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: identifier))
        defer { defaults.removePersistentDomain(forName: identifier) }
        #expect(DictationSettings(defaults: defaults) == DictationSettings())
        var settings = DictationSettings()
        settings.model = .whisperTurbo
        settings.language = .english
        settings.usesGPU = false
        settings.usesVoiceIsolation = true
        settings.vocabulary = "Core Audio"
        settings.save(to: defaults)
        #expect(DictationSettings(defaults: try #require(UserDefaults(suiteName: identifier))) == settings)
    }
}
