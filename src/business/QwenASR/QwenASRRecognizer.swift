import Foundation
import SpeechFoundation

public struct QwenASRConfiguration: Sendable {
    public let executable: URL
    public let model: URL
    public let timeout: Duration
    public init(executable: URL, model: URL, timeout: Duration = .seconds(90)) {
        self.executable = executable; self.model = model; self.timeout = timeout
    }
}

public actor QwenASRRecognizer: SpeechRecognizer {
    let configuration: QwenASRConfiguration
    let factory: @Sendable () -> any JSONWorkerRunning
    let temporaryDirectory: URL
    private var worker: (any JSONWorkerRunning)?
    private var busy = false
    public init(configuration: QwenASRConfiguration) {
        self.configuration = configuration
        factory = { JSONLineWorker(executable: configuration.executable, arguments: ["--model", configuration.model.path]) }
        temporaryDirectory = FileManager.default.temporaryDirectory
    }
    init(configuration: QwenASRConfiguration, temporaryDirectory: URL, factory: @escaping @Sendable () -> any JSONWorkerRunning) {
        self.configuration = configuration; self.temporaryDirectory = temporaryDirectory; self.factory = factory
    }
    deinit { worker?.close() }
    public func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
        try Task.checkCancellation()
        guard !busy else { throw RecognitionError.busy }
        guard !audio.samples.isEmpty else { throw RecognitionError.emptyAudio }
        // Digital silence has no linguistic content. Do not ask a generative
        // decoder to invent a transcript for it; quiet speech is preserved.
        if audio.samples.allSatisfy({ $0 == 0 }) { return Transcript(text: "") }
        guard configuration.executable.isFileURL, configuration.model.isFileURL, configuration.timeout > .zero,
              options.context.utf8.count <= 4096 else { throw RecognitionError.invalidConfiguration }
        guard FileManager.default.isExecutableFile(atPath: configuration.executable.path) else { throw RecognitionError.engineUnavailable }
        guard FileManager.default.isReadableFile(atPath: configuration.model.appendingPathComponent("model.safetensors").path)
        else { throw RecognitionError.modelUnavailable }
        busy = true
        defer { busy = false }
        let job = temporaryDirectory.appendingPathComponent("qwen-asr-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw RecognitionError.fileAccess }
        defer { try? FileManager.default.removeItem(at: job) }
        let input = job.appendingPathComponent("input.wav")
        do {
            try WAVCodec.encode(audio).write(to: input)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        } catch { throw RecognitionError.fileAccess }
        if worker == nil { worker = factory() }
        let worker = worker!
        let payload = try JSONEncoder().encode(Request(audio: input.path, language: options.language.rawValue, context: options.context))
        let timeout = configuration.timeout
        do {
            let response = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await worker.request(payload) }
                group.addTask { try await Task.sleep(for: timeout); throw RecognitionError.timedOut }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            try Task.checkCancellation()
            guard let transcript = try? JSONDecoder().decode(Transcript.self, from: response), transcript.text.utf8.count <= 16_384
            else { throw RecognitionError.invalidResult }
            return transcript
        } catch {
            await worker.shutdown()
            self.worker = nil
            throw error
        }
    }
    public func shutdown() async { await worker?.shutdown(); worker = nil }
    private struct Request: Encodable { let audio: String; let language: String; let context: String }
}
