import Foundation
import SpeechFoundation
@testable import SpeechInput
import Testing

struct ClosureRunner: CommandRunning {
    let body: @Sendable (URL, [String]) async throws -> Int32
    func run(executable: URL, arguments: [String]) async throws -> Int32 {
        try await body(executable, arguments)
    }
}

struct TestWorkspace {
    let root: URL
    let model: URL
    let configuration: WhisperConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        model = root.appendingPathComponent("model with spaces.bin")
        try Data("fixture".utf8).write(to: model)
        configuration = WhisperConfiguration(executable: URL(fileURLWithPath: "/usr/bin/true"), model: model)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private let successfulJSON = #"{"model":{"multilingual":true},"params":{"translate":false},"result":{"language":"en"},"transcription":[{"text":" Hello world"}]}"#

private func writeResult(_ json: String, arguments: [String]) throws {
    let index = try #require(arguments.firstIndex(of: "--output-file"))
    try Data(json.utf8).write(to: URL(fileURLWithPath: arguments[index + 1] + ".json"))
}

private actor Signal {
    var signalled = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func send() {
        signalled = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

struct WhisperRecognizerTests {
    @Test func acceleratedDemoRequestsFlashAttentionAndKeepsVoiceBoundaries() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.remove() }
        let runner = ClosureRunner { _, args in
            #expect(!args.contains("--no-gpu"))
            #expect(args.contains("--flash-attn"))
            #expect(args[try #require(args.firstIndex(of: "--vad-speech-pad-ms")) + 1] == "250")
            #expect(args[try #require(args.firstIndex(of: "--vad-min-silence-duration-ms")) + 1] == "500")
            try writeResult(successfulJSON, arguments: args)
            return 0
        }
        let config = WhisperConfiguration(executable: workspace.configuration.executable, model: workspace.model,
            vadModel: workspace.model, flashAttention: true)
        let provider = WhisperRecognizer(configuration: config, runner: runner, temporaryDirectory: workspace.root)
        #expect(try await provider.transcribe(AudioClip(samples: [1])).text == "Hello world")
    }
    @Test func transcribesPCMThroughProviderNeutralInterface() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.remove() }
        let runner = ClosureRunner { _, args in
            let prefix = try #require(args.firstIndex(of: "--output-file").map { args[$0 + 1] })
            let input = try #require(args.firstIndex(of: "--file").map { args[$0 + 1] })
            #expect(try WAVCodec.decode(Data(contentsOf: URL(fileURLWithPath: input))).samples == [1, -1])
            let json = #"{"model":{"multilingual":true},"params":{"translate":false},"result":{"language":"zh"},"transcription":[{"text":" 中文"},{"text":" English "}]}"#
            try Data(json.utf8).write(to: URL(fileURLWithPath: prefix + ".json"))
            return 0
        }
        let recognizer: any SpeechRecognizer = WhisperRecognizer(
            configuration: workspace.configuration, runner: runner, temporaryDirectory: workspace.root
        )
        let result = try await recognizer.transcribe(AudioClip(samples: [1, -1]))
        #expect(result == Transcript(text: "中文 English", language: "zh"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.root.path) == [workspace.model.lastPathComponent])
    }

    @Test func passesLanguageContextAndModelAsArgumentsWithoutTranslationOrVAD() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.remove() }
        let context = "RxSwift $(do-not-run) `literal`"
        let configuration = WhisperConfiguration(executable: workspace.configuration.executable,
            model: workspace.model, threads: 2, useGPU: false)
        let runner = ClosureRunner { executable, args in
            #expect(executable == configuration.executable)
            #expect(args[try #require(args.firstIndex(of: "--model")) + 1] == workspace.model.path)
            #expect(args[try #require(args.firstIndex(of: "--language")) + 1] == "en")
            #expect(args[try #require(args.firstIndex(of: "--prompt")) + 1] == context)
            #expect(args[try #require(args.firstIndex(of: "--threads")) + 1] == "2")
            #expect(args.contains("--no-gpu"))
            #expect(!args.contains("--translate"))
            #expect(!args.contains("--vad"))
            try writeResult(successfulJSON, arguments: args)
            return 0
        }
        let recognizer = WhisperRecognizer(configuration: configuration, runner: runner, temporaryDirectory: workspace.root)
        #expect(try await recognizer.transcribe(AudioClip(samples: [1]), options: .init(language: .english, context: context)).text == "Hello world")
    }

    @Test func supportsSwappingModelConfigurationAndProvider() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.remove() }
        let secondModel = workspace.root.appendingPathComponent("second.bin")
        try Data("fixture".utf8).write(to: secondModel)
        for model in [workspace.model, secondModel] {
            let runner = ClosureRunner { _, args in
                #expect(args[try #require(args.firstIndex(of: "--model")) + 1] == model.path)
                #expect(!args.contains("--prompt"))
                try writeResult(successfulJSON, arguments: args)
                return 0
            }
            let provider: any SpeechRecognizer = WhisperRecognizer(
                configuration: .init(executable: workspace.configuration.executable, model: model),
                runner: runner, temporaryDirectory: workspace.root)
            #expect(try await provider.transcribe(AudioClip(samples: [1])).text == "Hello world")
        }
    }

    @Test func rejectsEmptyAudioBeforeInvokingEngine() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.remove() }
        let provider = WhisperRecognizer(configuration: workspace.configuration)
        await #expect(throws: RecognitionError.emptyAudio) { try await provider.transcribe(AudioClip(samples: [])) }
    }

    @Test func optionalVoiceActivityDetectionIsExplicitAndValidated() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.remove() }
        let runner = ClosureRunner { _, args in
            #expect(args.contains("--vad"))
            #expect(args[try #require(args.firstIndex(of: "--vad-model")) + 1] == workspace.model.path)
            try writeResult(successfulJSON, arguments: args)
            return 0
        }
        let configuration = WhisperConfiguration(executable: workspace.configuration.executable, model: workspace.model,
            vadModel: workspace.model)
        let provider = WhisperRecognizer(configuration: configuration, runner: runner, temporaryDirectory: workspace.root)
        #expect(try await provider.transcribe(AudioClip(samples: [1])).text == "Hello world")
    }

    @Test func validatesConfigurationAndLocalResources() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.remove() }
        let audio = try AudioClip(samples: [1])
        let invalid = [
            WhisperConfiguration(executable: workspace.configuration.executable, model: workspace.model, threads: 0),
            WhisperConfiguration(executable: workspace.configuration.executable, model: workspace.model, threads: 65),
            WhisperConfiguration(executable: workspace.configuration.executable, model: workspace.model, timeout: .zero),
            WhisperConfiguration(executable: URL(string: "https://example.com/engine")!, model: workspace.model),
            WhisperConfiguration(executable: workspace.configuration.executable, model: URL(string: "https://example.com/model")!),
        ]
        for configuration in invalid {
            await #expect(throws: RecognitionError.invalidConfiguration) {
                try await WhisperRecognizer(configuration: configuration).transcribe(audio)
            }
        }
        for context in [String(repeating: "a", count: 4097), "bad\0context"] {
            await #expect(throws: RecognitionError.invalidConfiguration) {
                try await WhisperRecognizer(configuration: workspace.configuration).transcribe(audio, options: .init(context: context))
            }
        }
        await #expect(throws: RecognitionError.engineUnavailable) {
            try await WhisperRecognizer(configuration: .init(executable: workspace.model, model: workspace.model)).transcribe(audio)
        }
        for model in [workspace.root, workspace.root.appendingPathComponent("missing.bin")] {
            await #expect(throws: RecognitionError.modelUnavailable) {
                try await WhisperRecognizer(configuration: .init(executable: workspace.configuration.executable, model: model)).transcribe(audio)
            }
        }
    }

    @Test func propagatesEngineFailureAndCleansTemporaryAudio() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.remove() }
        let runner = ClosureRunner { _, _ in 42 }
        let provider = WhisperRecognizer(configuration: workspace.configuration, runner: runner, temporaryDirectory: workspace.root)
        await #expect(throws: RecognitionError.engineFailed(exitCode: 42)) {
            try await provider.transcribe(AudioClip(samples: [1]))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.root.path) == [workspace.model.lastPathComponent])
    }

    @Test(arguments: ["{}", "invalid", successfulJSON.replacingOccurrences(of: "true", with: "false"),
                     successfulJSON.replacingOccurrences(of: "\"translate\":false", with: "\"translate\":true"),
                     successfulJSON.replacingOccurrences(of: "\"language\":\"en\"", with: "\"language\":\"\"")])
    func rejectsMalformedOrIncompatibleEngineResults(json: String) async throws {
        let workspace = try TestWorkspace()
        defer { workspace.remove() }
        let runner = ClosureRunner { _, args in try writeResult(json, arguments: args); return 0 }
        let provider = WhisperRecognizer(configuration: workspace.configuration, runner: runner, temporaryDirectory: workspace.root)
        await #expect(throws: RecognitionError.invalidResult) { try await provider.transcribe(AudioClip(samples: [1])) }
    }

    @Test func treatsNoSpeechAsEmptyTextAndRejectsMissingOrOversizedOutput() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.remove() }
        for output in ["none", "oversize", "empty"] {
            let runner = ClosureRunner { _, args in
                if output == "oversize" { try writeResult(String(repeating: "x", count: 1_048_577), arguments: args) }
                if output == "empty" {
                    try writeResult(#"{"model":{"multilingual":true},"params":{"translate":false},"result":{"language":"en"},"transcription":[]}"#, arguments: args)
                }
                return 0
            }
            let provider = WhisperRecognizer(configuration: workspace.configuration, runner: runner, temporaryDirectory: workspace.root)
            if output == "empty" { #expect(try await provider.transcribe(AudioClip(samples: [1])).text.isEmpty) }
            else { await #expect(throws: RecognitionError.invalidResult) { try await provider.transcribe(AudioClip(samples: [1])) } }
        }
    }

    @Test func cancellationRejectsConcurrentWorkCleansUpAndAllowsNextUtterance() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.remove() }
        let started = Signal()
        let runner = ClosureRunner { _, args in
            if args.contains("hold") { await started.send(); try await Task.sleep(for: .seconds(60)) }
            try writeResult(successfulJSON, arguments: args)
            return 0
        }
        let provider = WhisperRecognizer(configuration: workspace.configuration, runner: runner, temporaryDirectory: workspace.root)
        let audio = try AudioClip(samples: [1])
        let first = Task { try await provider.transcribe(audio, options: .init(context: "hold")) }
        await started.wait()
        await #expect(throws: RecognitionError.busy) { try await provider.transcribe(audio) }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await provider.transcribe(audio).text == "Hello world")
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.root.path) == [workspace.model.lastPathComponent])
    }

    @Test func preCancelledTaskNeverStartsAndInvalidWorkspaceFailsCleanly() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.remove() }
        let provider = WhisperRecognizer(configuration: workspace.configuration)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.transcribe(AudioClip(samples: [1]))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let badProvider = WhisperRecognizer(configuration: workspace.configuration,
            runner: ClosureRunner { _, _ in 0 }, temporaryDirectory: workspace.model)
        await #expect(throws: RecognitionError.fileAccess) { try await badProvider.transcribe(AudioClip(samples: [1])) }
    }
}
