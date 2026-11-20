import Foundation
import SpeechFoundation
import SpeechInput
import Dispatch
import Darwin

@main struct VoiceInputCLI {
    static let usage = """
    voice-input transcribe <16k-mono-PCM16.wav> --model <local-model.bin>
      [--engine <whisper-cli>] [--language auto|zh|en] [--context <vocabulary>]
      [--threads 1...64] [--timeout 1...600] [--cpu] [--json]
    """

    @MainActor static func main() async {
        let operation = Task { try await execute() }
        let signals = [SIGINT, SIGTERM].map { code -> any DispatchSourceSignal in
            _ = signal(code, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: code, queue: .global())
            source.setEventHandler { @Sendable in operation.cancel() }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        do {
            let output = try await operation.value
            try FileHandle.standardOutput.write(contentsOf: Data((output + "\n").utf8))
        } catch is CancellationError {
            FileHandle.standardError.write(Data("Cancelled\n".utf8))
            exit(130)
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            exit(2)
        }
    }

    private static func execute() async throws -> String {
        guard let command = try CLIInvocation.parse(Array(CommandLine.arguments.dropFirst())) else { return usage }
        let audio = try readWAV(at: URL(fileURLWithPath: command.audioPath))
        let configuration = WhisperConfiguration(executable: URL(fileURLWithPath: command.executablePath),
            model: URL(fileURLWithPath: command.modelPath), threads: command.threads,
            useGPU: command.useGPU, timeout: .seconds(command.timeoutSeconds))
        let recognizer = WhisperRecognizer(configuration: configuration)
        let transcript = try await recognizer.transcribe(audio, options: .init(language: command.language, context: command.context))
        return command.json ? String(decoding: try JSONEncoder().encode(transcript), as: UTF8.self) : transcript.text
    }

    private static func readWAV(at url: URL) throws -> AudioClip {
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: WAVCodec.maximumFileSize + 1) ?? Data()
            return try WAVCodec.decode(data)
        } catch let error as AudioError { throw error }
        catch { throw RecognitionError.fileAccess }
    }
}
