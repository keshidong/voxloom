import Foundation
import SpeechFoundation
@testable import SpeechInput
import Testing

private final class ASRBoundary: JSONWorkerRunning, @unchecked Sendable {
    let lock = NSLock()
    var calls = 0
    var preparations = 0
    func prepare() async throws { lock.withLock { preparations += 1 } }
    func request(_ data: Data) async throws -> Data {
        let request = try JSONSerialization.jsonObject(with: data) as! [String: String]
        #expect(request["context"] == "图书卡 预付费 USD")
        #expect(request["language"] == "zh")
        let audio = try Data(contentsOf: URL(fileURLWithPath: request["audio"]!))
        #expect(try WAVCodec.decode(audio).samples == [1, -1])
        lock.withLock { calls += 1 }
        return Data(#"{"text":"图书卡额度采用预付费模式","language":"zh"}"#.utf8)
    }
    func close() {}
}

struct QwenASRRecognizerTests {
    @Test func backgroundPreparationReusesTheWorkerWithoutSubmittingAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("model.safetensors"))
        let boundary = ASRBoundary()
        let provider = QwenASRRecognizer(configuration: .init(executable: URL(fileURLWithPath: "/usr/bin/true"),
                                                               model: root), temporaryDirectory: root,
            factory: { boundary })
        await provider.prepare()
        await provider.prepare()
        #expect(boundary.preparations == 1)
        #expect(boundary.calls == 0)
        let result = try await provider.transcribe(AudioClip(samples: [1, -1]),
            options: .init(language: .chinese, context: "图书卡 预付费 USD"))
        #expect(result.text == "图书卡额度采用预付费模式")
        #expect(boundary.calls == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["model.safetensors"])
        await provider.shutdown()
    }

    @Test func configurationMissingResourcesInvalidResultAndFileErrorsRemainDistinct() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data().write(to: model.appendingPathComponent("model.safetensors"))
        let exe = URL(fileURLWithPath: "/usr/bin/true")
        let audio = try AudioClip(samples: [1])
        for (config, expected) in [
            (QwenASRConfiguration(executable: exe, model: model, timeout: .zero), RecognitionError.invalidConfiguration),
            (.init(executable: URL(fileURLWithPath: "/missing"), model: model), .engineUnavailable),
            (.init(executable: exe, model: root), .modelUnavailable)] {
            let provider = QwenASRRecognizer(configuration: config)
            await #expect(throws: expected) { try await provider.transcribe(audio, options: .init()) }
        }
        let provider = QwenASRRecognizer(configuration: .init(executable: exe, model: model), temporaryDirectory: root,
            factory: { InvalidASRBoundary() })
        await #expect(throws: RecognitionError.emptyAudio) { try await provider.transcribe(AudioClip(samples: []), options: .init()) }
        await #expect(throws: RecognitionError.invalidConfiguration) {
            try await provider.transcribe(audio, options: .init(context: String(repeating: "x", count: 4097)))
        }
        await #expect(throws: RecognitionError.invalidResult) { try await provider.transcribe(audio, options: .init()) }
        await provider.shutdown()
        let noDirectory = QwenASRRecognizer(configuration: .init(executable: exe, model: model),
            temporaryDirectory: model.appendingPathComponent("model.safetensors"), factory: { InvalidASRBoundary() })
        await #expect(throws: RecognitionError.fileAccess) { try await noDirectory.transcribe(audio, options: .init()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["model"])
    }
    @Test func digitalSilenceReturnsNoInventedWords() async throws {
        let provider = QwenASRRecognizer(configuration: .init(executable: URL(fileURLWithPath: "/missing"), model: URL(fileURLWithPath: "/missing-model")))
        let result = try await provider.transcribe(AudioClip(samples: Array(repeating: 0, count: 16_000)), options: .init())
        #expect(result.text.isEmpty)
    }
    @Test func commonInterfacePassesLanguageAndContextToAResidentWorker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data().write(to: model.appendingPathComponent("model.safetensors"))
        let boundary = ASRBoundary()
        let provider: any SpeechRecognizer = QwenASRRecognizer(configuration: .init(executable: URL(fileURLWithPath: "/usr/bin/true"), model: model),
            temporaryDirectory: root, factory: { boundary })
        for _ in 0..<2 {
            let result = try await provider.transcribe(AudioClip(samples: [1, -1]), options: .init(language: .chinese, context: "图书卡 预付费 USD"))
            #expect(result.text == "图书卡额度采用预付费模式")
        }
        #expect(boundary.calls == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["model"])
    }
}

private struct InvalidASRBoundary: JSONWorkerRunning {
    func request(_ data: Data) async throws -> Data { Data(#"{"error":"inference_failed"}"#.utf8) }
    func close() {}
}
