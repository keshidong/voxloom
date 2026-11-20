import Foundation
import SpeechFoundation

public struct QwenConfiguration: Sendable {
    public let executable: URL
    public let model: URL
    public let useGPU: Bool
    public let timeout: Duration
    public init(executable: URL, model: URL, useGPU: Bool = true, timeout: Duration = .seconds(45)) {
        self.executable = executable; self.model = model; self.useGPU = useGPU; self.timeout = timeout
    }
}

public actor QwenTextCorrector: TextCorrecting {
    let configuration: QwenConfiguration
    let runner: (any CommandRunning)?
    let temporaryDirectory: URL
    private var busy = false
    public init(configuration: QwenConfiguration) {
        self.configuration = configuration
        runner = nil
        temporaryDirectory = FileManager.default.temporaryDirectory
    }
    init(configuration: QwenConfiguration, runner: any CommandRunning, temporaryDirectory: URL) {
        self.configuration = configuration; self.runner = runner; self.temporaryDirectory = temporaryDirectory
    }
    public func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        try Task.checkCancellation()
        guard !busy else { throw CorrectionError.busy }
        let prompt = try CorrectionPrompt.build(request)
        guard configuration.executable.isFileURL, configuration.model.isFileURL, configuration.timeout > .zero
        else { throw CorrectionError.invalidConfiguration }
        guard FileManager.default.isExecutableFile(atPath: configuration.executable.path) else { throw CorrectionError.engineUnavailable }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: configuration.model.path, isDirectory: &directory),
              !directory.boolValue, FileManager.default.isReadableFile(atPath: configuration.model.path)
        else { throw CorrectionError.modelUnavailable }
        busy = true
        defer { busy = false }
        let job = temporaryDirectory.appendingPathComponent("correction-" + UUID().uuidString)
        let input = job.appendingPathComponent("prompt.txt")
        let output = job.appendingPathComponent("result.json")
        do {
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch { throw CorrectionError.fileAccess }
        defer { try? FileManager.default.removeItem(at: job) }
        do {
            try Data(prompt.utf8).write(to: input)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
            guard FileManager.default.createFile(atPath: output.path, contents: Data(), attributes: [.posixPermissions: 0o600])
            else { throw CorrectionError.fileAccess }
        } catch { throw CorrectionError.fileAccess }
        let schema = #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}"#
        let arguments = ["--model", configuration.model.path, "--file", input.path, "--ctx-size", "2048",
                         "--predict", "384", "--threads", "4", "--gpu-layers", configuration.useGPU ? "99" : "0",
                         "--batch-size", "128", "--ubatch-size", "128", "--temp", "0", "--seed", "0",
                         "--json-schema", schema, "--no-display-prompt", "--no-conversation", "--no-warmup", "--no-perf"]
        let status: Int32
        do {
            status = try await DeadlineCommandRunner(base: runner ?? SystemCommandRunner(output: output), timeout: configuration.timeout)
                .run(executable: configuration.executable, arguments: arguments)
        } catch let error as RecognitionError {
            switch error {
            case .timedOut: throw CorrectionError.timedOut
            case .fileAccess: throw CorrectionError.fileAccess
            default: throw CorrectionError.engineUnavailable
            }
        }
        try Task.checkCancellation()
        guard status == 0 else { throw CorrectionError.engineFailed(status) }
        let result: Data
        do {
            let file = try FileHandle(forReadingFrom: output)
            defer { try? file.close() }
            result = try file.read(upToCount: 16_385) ?? Data()
        } catch { throw CorrectionError.invalidResult }
        return try CorrectionPrompt.decode(result, original: request.text)
    }
}
