import Foundation
import Testing
@testable import VoxloomDesktop

struct DictationSettingsTests {
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
        settings.vocabulary = "Core Audio"
        settings.save(to: defaults)
        #expect(DictationSettings(defaults: try #require(UserDefaults(suiteName: identifier))) == settings)
    }
}
