import Foundation
import SpeechFoundation
import SpeechInput
import Testing
@testable import VoxloomDesktop

struct LocalModelsTests {
    @Test func preferencesSelectLocalProvidersAndTheSampleLanguage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try AudioClip(samples: [3000, -1000])
        try WAVCodec.encode(audio).write(to: root.appendingPathComponent("english.wav"))
        let models = LocalModels(root: root)
        var settings = DictationSettings()
        #expect(models.recognizer(for: settings) is QwenASRRecognizer)
        #expect(models.corrector(for: settings) == nil)
        settings.correctsText = true
        #expect(models.corrector(for: settings) is QwenTextCorrector)
        for model in [RecognitionModel.whisperBase, .whisperTiny, .whisperTurbo] {
            settings.model = model
            #expect(models.recognizer(for: settings) is WhisperRecognizer)
        }
        settings.language = .english
        #expect(try models.sample(for: settings) == audio)
        settings.correctsText = false
        #expect(models.corrector(for: settings) == nil)
    }
}
