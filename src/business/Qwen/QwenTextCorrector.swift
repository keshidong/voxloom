import Foundation
import SpeechFoundation

public struct QwenConfiguration: Sendable {
    /// Reviewed mode can make a second pass. Interactive mode returns the first verified edits.
    public enum Mode: Sendable, Equatable { case reviewed, interactive }

    public let executable: URL
    public let model: URL
    public let useGPU: Bool
    public let timeout: Duration
    public let mode: Mode
    public init(executable: URL, model: URL, useGPU: Bool = true, timeout: Duration = .seconds(45),
                mode: Mode = .reviewed) {
        self.executable = executable; self.model = model; self.useGPU = useGPU; self.timeout = timeout
        self.mode = mode
    }
}

public actor QwenTextCorrector: TextCorrecting {
    let configuration: QwenConfiguration
    let runner: (any CommandRunning)?
    let temporaryDirectory: URL
    let now: @Sendable () -> ContinuousClock.Instant
    private var busy = false
    public init(configuration: QwenConfiguration) {
        self.configuration = configuration
        runner = nil
        temporaryDirectory = FileManager.default.temporaryDirectory
        now = { .now }
    }
    init(configuration: QwenConfiguration, runner: any CommandRunning, temporaryDirectory: URL, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.configuration = configuration; self.runner = runner; self.temporaryDirectory = temporaryDirectory; self.now = now
    }
    public func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        try Task.checkCancellation()
        guard !busy else { throw CorrectionError.busy }
        let includesAnalysis = configuration.mode == .reviewed
        let passes = includesAnalysis ? 2 : 1
        let initialPlan = try CorrectionPrompt.plan(request, includesAnalysis: includesAnalysis)
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
        do {
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch { throw CorrectionError.fileAccess }
        defer { try? FileManager.default.removeItem(at: job) }
        let deadline = now().advanced(by: configuration.timeout)
        var current = request
        for pass in 0..<passes {
            try Task.checkCancellation()
            let remaining = now().duration(to: deadline)
            if remaining <= .zero {
                if pass > 0 { return CorrectionCandidate(text: current.text, original: request.text) }
                throw CorrectionError.timedOut
            }
            let result: (candidate: CorrectionCandidate, hasEdits: Bool)
            do {
                let plan = pass == 0 ? initialPlan : try CorrectionPrompt.plan(current)
                result = try await generate(current, plan: plan, job: job, timeout: remaining)
            }
            catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                if pass > 0 { return CorrectionCandidate(text: current.text, original: request.text) }
                throw error
            }
            if pass == passes - 1 || !result.hasEdits || result.candidate.text.utf8.count > 3000 {
                if pass == 0 { return result.candidate }
                return CorrectionCandidate(text: result.candidate.text, original: request.text)
            }
            current = CorrectionRequest(text: result.candidate.text, vocabulary: request.vocabulary,
                                        surroundingText: request.surroundingText)
        }
        throw CorrectionError.invalidResult
    }

    private func generate(_ request: CorrectionRequest, plan: CorrectionPrompt.GenerationPlan, job: URL,
                          timeout: Duration) async throws -> (candidate: CorrectionCandidate, hasEdits: Bool) {
        try Task.checkCancellation()
        let input = job.appendingPathComponent("prompt.txt")
        let output = job.appendingPathComponent("result.json")
        do {
            try Data(plan.prompt.utf8).write(to: input)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
            guard FileManager.default.createFile(atPath: output.path, contents: Data(), attributes: [.posixPermissions: 0o600])
            else { throw CorrectionError.fileAccess }
        } catch { throw CorrectionError.fileAccess }
        let edits = #""edits":{"type":"array","maxItems":16,"items":{"type":"object","properties":{"from":{"type":"string","minLength":2},"to":{"type":"string"}},"required":["from","to"],"additionalProperties":false}}"#
        let analysis = configuration.mode == .reviewed ? #""analysis":{"type":"string","maxLength":80},"# : ""
        let required = configuration.mode == .reviewed ? #""analysis","edits""# : #""edits""#
        let schema = #"{"type":"object","properties":{\#(analysis)\#(edits)},"required":[\#(required)],"additionalProperties":false}"#
        // This completion engine checks EOG after every logical batch, including
        // prompt batches. Consume the whole prompt before that check. Physical
        // microbatches remain small to bound compute workspace.
        let arguments = ["--model", configuration.model.path, "--file", input.path, "--ctx-size", String(plan.contextTokens),
                         "--predict", String(plan.outputTokens), "--threads", "4", "--gpu-layers", configuration.useGPU ? "99" : "0",
                         "--batch-size", String(plan.contextTokens), "--ubatch-size", "128", "--temp", "0", "--seed", "0",
                         "--json-schema", schema, "--no-display-prompt", "--no-conversation", "--no-warmup", "--no-perf"]
        let status: Int32
        do {
            status = try await DeadlineCommandRunner(base: runner ?? SystemCommandRunner(output: output), timeout: timeout)
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
        // Model-proposed source text is never guessed or fuzzy-matched. Ignore
        // suggestions absent from the current text; only literal edits apply.
        return try CorrectionPrompt.decodeWithReview(result, original: request.text, allowMissingSources: true, preferEnclosingEdits: true)
    }
}
