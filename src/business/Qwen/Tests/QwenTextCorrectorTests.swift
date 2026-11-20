import Foundation
import SpeechFoundation
@testable import SpeechInput
import Testing

private struct CorrectionRunner: CommandRunning {
    let body: @Sendable ([String]) async throws -> Int32
    func run(executable: URL, arguments: [String]) async throws -> Int32 { try await body(arguments) }
}

struct QwenTextCorrectorTests {
    @Test func invalidConfigurationAndEngineFailuresLeaveNoTemporaryAudioOrPrompt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model.gguf")
        try Data().write(to: model)
        let exe = URL(fileURLWithPath: "/usr/bin/true")
        let input = CorrectionRequest(text: "明天开毁")
        for (configuration, expected) in [
            (QwenConfiguration(executable: exe, model: model, timeout: .zero), CorrectionError.invalidConfiguration),
            (.init(executable: URL(fileURLWithPath: "/missing"), model: model), .engineUnavailable),
            (.init(executable: exe, model: root), .modelUnavailable)] {
            let provider = QwenTextCorrector(configuration: configuration)
            await #expect(throws: expected) { try await provider.correct(input) }
        }
        for (engineError, expected) in [(RecognitionError.timedOut, CorrectionError.timedOut), (.fileAccess, .fileAccess), (.engineUnavailable, .engineUnavailable)] {
            let provider = QwenTextCorrector(configuration: .init(executable: exe, model: model),
                runner: CorrectionRunner { _ in throw engineError }, temporaryDirectory: root)
            await #expect(throws: expected) { try await provider.correct(input) }
        }
        let failed = QwenTextCorrector(configuration: .init(executable: exe, model: model, useGPU: false),
            runner: CorrectionRunner { args in
                #expect(args[args.firstIndex(of: "--gpu-layers")! + 1] == "0")
                return 7
            }, temporaryDirectory: root)
        await #expect(throws: CorrectionError.engineFailed(7)) { try await failed.correct(input) }
        let malformed = QwenTextCorrector(configuration: .init(executable: exe, model: model),
            runner: CorrectionRunner { _ in 0 }, temporaryDirectory: root)
        await #expect(throws: CorrectionError.invalidResult) { try await malformed.correct(input) }
        let unreadable = QwenTextCorrector(configuration: .init(executable: exe, model: model),
            runner: CorrectionRunner { args in
                let file = URL(fileURLWithPath: args[args.firstIndex(of: "--file")! + 1]).deletingLastPathComponent().appendingPathComponent("result.json")
                try FileManager.default.removeItem(at: file)
                return 0
            }, temporaryDirectory: root)
        await #expect(throws: CorrectionError.invalidResult) { try await unreadable.correct(input) }
        let noDirectory = QwenTextCorrector(configuration: .init(executable: exe, model: model),
            runner: CorrectionRunner { _ in 0 }, temporaryDirectory: model)
        await #expect(throws: CorrectionError.fileAccess) { try await noDirectory.correct(input) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["model.gguf"])
    }
    @Test func concurrentCorrectionIsRejectedAndCancellationReleasesTheSlot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model.gguf")
        try Data().write(to: model)
        let runner = WaitingCorrectionRunner()
        let provider = QwenTextCorrector(configuration: .init(executable: URL(fileURLWithPath: "/usr/bin/true"), model: model),
            runner: runner, temporaryDirectory: root)
        let task = Task { try await provider.correct(.init(text: "听写")) }
        while !(await runner.started) { await Task.yield() }
        await #expect(throws: CorrectionError.busy) { try await provider.correct(.init(text: "另一段")) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["model.gguf"])
    }
    @Test func genericCorrectionUsesLocalPromptAndReturnsANumericReviewableCandidate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model with spaces.gguf")
        try Data("fixture".utf8).write(to: model)
        let runner = CorrectionRunner { args in
            let promptIndex = try #require(args.firstIndex(of: "--file"))
            let file = URL(fileURLWithPath: args[promptIndex + 1])
            let prompt = try String(contentsOf: file, encoding: .utf8)
            #expect(prompt.contains("充值额度"))
            #expect(args.contains("--no-conversation"))
            #expect(args.contains("--json-schema"))
            try Data(#"{"text":"充值额度以USD计价，为10的整倍数。"}"#.utf8).write(to: file.deletingLastPathComponent().appendingPathComponent("result.json"))
            return 0
        }
        let provider: any TextCorrecting = QwenTextCorrector(configuration: .init(executable: URL(fileURLWithPath: "/usr/bin/true"), model: model),
            runner: runner, temporaryDirectory: root)
        let result = try await provider.correct(.init(text: "充斥额图以USD即将，为10的整数倍。", vocabulary: "充值额度 USD 计价"))
        #expect(result.text.contains("充值额度"))
        #expect(result.containsNumbers)
        #expect(!result.numbersChanged)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [model.lastPathComponent])
    }
}

private actor WaitingCorrectionRunner: CommandRunning {
    var started = false
    func run(executable: URL, arguments: [String]) async throws -> Int32 {
        started = true
        try await Task.sleep(for: .seconds(60))
        return 0
    }
}
