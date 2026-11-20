import Foundation
import SpeechFoundation

public struct WhisperConfiguration: Sendable {
    public let executable: URL
    public let model: URL
    public let threads: Int
    public let useGPU: Bool
    public let timeout: Duration
    public let vadModel: URL?
    public let flashAttention: Bool

    public init(executable: URL, model: URL, threads: Int = 4,
                useGPU: Bool = true, timeout: Duration = .seconds(120), vadModel: URL? = nil,
                flashAttention: Bool = false) {
        self.executable = executable
        self.model = model
        self.threads = threads
        self.useGPU = useGPU
        self.timeout = timeout
        self.vadModel = vadModel
        self.flashAttention = flashAttention
    }
}

/// First provider: an offline whisper.cpp CLI process per utterance.
public actor WhisperRecognizer: SpeechRecognizer {
    let configuration: WhisperConfiguration
    let runner: any CommandRunning
    let temporaryDirectory: URL
    private var isTranscribing = false

    public init(configuration: WhisperConfiguration) {
        self.configuration = configuration
        runner = SystemCommandRunner()
        temporaryDirectory = FileManager.default.temporaryDirectory
    }

    init(configuration: WhisperConfiguration, runner: any CommandRunning, temporaryDirectory: URL) {
        self.configuration = configuration
        self.runner = runner
        self.temporaryDirectory = temporaryDirectory
    }

    public func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
        try Task.checkCancellation()
        guard !isTranscribing else { throw RecognitionError.busy }
        guard !audio.samples.isEmpty else { throw RecognitionError.emptyAudio }
        guard configuration.executable.isFileURL, configuration.model.isFileURL,
              (1...64).contains(configuration.threads), configuration.timeout > .zero,
              options.context.utf8.count <= 4096, !options.context.contains("\0")
        else { throw RecognitionError.invalidConfiguration }
        guard FileManager.default.isExecutableFile(atPath: configuration.executable.path)
        else { throw RecognitionError.engineUnavailable }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: configuration.model.path, isDirectory: &directory),
              !directory.boolValue, FileManager.default.isReadableFile(atPath: configuration.model.path)
        else { throw RecognitionError.modelUnavailable }
        if let vad = configuration.vadModel {
            guard vad.isFileURL, FileManager.default.fileExists(atPath: vad.path, isDirectory: &directory),
                  !directory.boolValue, FileManager.default.isReadableFile(atPath: vad.path)
            else { throw RecognitionError.modelUnavailable }
        }

        isTranscribing = true
        defer { isTranscribing = false }
        let job = temporaryDirectory.appendingPathComponent("speech-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw RecognitionError.fileAccess }
        defer { try? FileManager.default.removeItem(at: job) }

        let input = job.appendingPathComponent("input.wav")
        let prefix = job.appendingPathComponent("result")
        do {
            try WAVCodec.encode(audio).write(to: input)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        } catch { throw RecognitionError.fileAccess }
        var arguments = ["--model", configuration.model.path, "--file", input.path,
                         "--language", options.language.rawValue, "--threads", String(configuration.threads),
                         "--output-json", "--output-file", prefix.path, "--no-prints"]
        if !configuration.useGPU { arguments.append("--no-gpu") }
        if configuration.useGPU && configuration.flashAttention { arguments.append("--flash-attn") }
        if let vad = configuration.vadModel {
            arguments += ["--vad", "--vad-model", vad.path, "--vad-speech-pad-ms", "250",
                          "--vad-min-silence-duration-ms", "500"]
        }
        if !options.context.isEmpty { arguments += ["--prompt", options.context] }
        let status = try await DeadlineCommandRunner(base: runner, timeout: configuration.timeout)
            .run(executable: configuration.executable, arguments: arguments)
        try Task.checkCancellation()
        guard status == 0 else { throw RecognitionError.engineFailed(exitCode: status) }
        return try readTranscript(at: prefix.appendingPathExtension("json"))
    }

    private func readTranscript(at url: URL) throws -> Transcript {
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576
            else { throw RecognitionError.invalidResult }
            data = try Data(contentsOf: url)
        } catch let error as RecognitionError { throw error }
        catch { throw RecognitionError.invalidResult }
        guard let output = try? JSONDecoder().decode(WhisperOutput.self, from: data),
              output.model.multilingual, !output.params.translate, !output.result.language.isEmpty
        else { throw RecognitionError.invalidResult }
        return Transcript(text: output.transcription.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
                          language: output.result.language)
    }
}

private struct WhisperOutput: Decodable {
    struct Model: Decodable { let multilingual: Bool }
    struct Parameters: Decodable { let translate: Bool }
    struct Result: Decodable { let language: String }
    struct Segment: Decodable { let text: String }
    let model: Model
    let params: Parameters
    let result: Result
    let transcription: [Segment]
}
