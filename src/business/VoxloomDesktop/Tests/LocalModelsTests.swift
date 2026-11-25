import Foundation
import SpeechFoundation
import SpeechInput
import Testing
@testable import VoxloomDesktop

struct LocalModelsTests {
    @Test func qwenStartsUsingTheVoiceDetectorWhenItsModelFinishesDownloading() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cache = root.appending(path: "installed")
        try FileManager.default.createDirectory(at: root.appending(path: "qwen-asr-runtime"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = """
        {"qwen":[{"path":"Qwen3-ASR-1.7B-4bit/model.safetensors","url":"https://example.com/qwen","sha256":"qwen","bytes":2}],
        "qwenVoiceActivity":[{"path":"ggml-silero-v5.1.2.bin","url":"https://example.com/vad","sha256":"vad","bytes":2}]}
        """
        try Data(manifest.utf8).write(to: root.appending(path: "model-downloads.json"))
        let models = LocalModels(root: root, downloadDirectory: cache)
        let downloads = try #require(models.downloads)

        let qwen = root.appending(path: "qwen-asr-runtime/qwen-asr")
        try writeExecutable("""
        #!/bin/sh
        printf '%s\n' '{"ready":true}'
        while IFS= read -r request; do
            printf '%s\n' '{"text":"测试转写","language":"zh"}'
        done
        """, to: qwen)
        try writeExecutable("""
        #!/bin/sh
        test -s "$2" || exit 1
        printf '%s\n' 'Detected 0 speech segments:'
        """, to: root.appending(path: "vad-speech-segments"))

        let speechWeights = downloads.directory(for: "qwen").appending(path: "Qwen3-ASR-1.7B-4bit")
        try FileManager.default.createDirectory(at: speechWeights, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: speechWeights.appending(path: "model.safetensors"))
        let recognizer = models.recognizer(for: .init())
        let audio = try AudioClip(samples: (0..<1600).map { $0.isMultiple(of: 2) ? 300 : -300 })
        let before = try await recognizer.transcribe(audio, options: .init())
        #expect(before.text == "测试转写")

        let activityWeights = downloads.directory(for: "qwenVoiceActivity")
        try FileManager.default.createDirectory(at: activityWeights, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: activityWeights.appending(path: "ggml-silero-v5.1.2.bin"))
        let after = try await recognizer.transcribe(audio, options: .init())
        #expect(after.text.isEmpty)
        await recognizer.shutdown()
    }

    private func writeExecutable(_ script: String, to path: URL) throws {
        try Data(script.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    }

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
