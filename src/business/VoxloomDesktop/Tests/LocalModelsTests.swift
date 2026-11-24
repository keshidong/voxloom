import Foundation
import SpeechFoundation
import SpeechInput
import Testing
@testable import VoxloomDesktop

struct LocalModelsTests {
    @Test func externalModelsGateRecognitionAndLeaveUninstalledCorrectionOptional() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cache = root.appending(path: "installed")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = """
        {"qwen":[{"path":"Qwen3-ASR-1.7B-4bit/model.safetensors",
        "url":"https://example.com/weights","sha256":"2689367b205c16ce32ed4200942b8b8b1e262dfc70d9bc9fbc77c49699a4f1df","bytes":2}]}
        """
        try Data(manifest.utf8).write(to: root.appending(path: "model-downloads.json"))
        let models = LocalModels(root: root, downloadDirectory: cache)
        let downloads = try #require(models.downloads)
        var settings = DictationSettings()
        settings.correctsText = true
        #expect(!models.canRecognize(settings.model))
        #expect(models.corrector(for: settings) == nil)

        try await downloads.install("qwen", download: { _, _ in
            let file = cache.appending(path: "received")
            try Data("ok".utf8).write(to: file)
            return file
        })
        #expect(models.canRecognize(settings.model))
        #expect(models.corrector(for: settings) == nil)
    }

    @Test func preferencesSelectLocalProviders() {
        let models = LocalModels(root: FileManager.default.temporaryDirectory)
        var settings = DictationSettings()
        #expect(models.recognizer(for: settings) is QwenASRRecognizer)
        #expect(models.corrector(for: settings) == nil)
        settings.correctsText = true
        #expect(models.corrector(for: settings) is QwenTextCorrector)
        for model in [RecognitionModel.whisperBase, .whisperTiny, .whisperTurbo] {
            settings.model = model
            #expect(models.recognizer(for: settings) is WhisperRecognizer)
        }
        settings.correctsText = false
        #expect(models.corrector(for: settings) == nil)
    }
}
