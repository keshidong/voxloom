import Foundation
import SpeechFoundation

public struct QwenVoiceActivityConfiguration: Sendable {
    public let executable: URL
    public let model: URL

    public init(executable: URL, model: URL) {
        self.executable = executable
        self.model = model
    }
}

struct QwenVoiceActivity {
    let configuration: QwenVoiceActivityConfiguration

    /// Returns nil when the optional detector cannot make a decision.
    func detectsSpeech(_ audio: AudioClip, in directory: URL) async throws -> Bool? {
        let executable = configuration.executable
        let model = configuration.model
        guard executable.isFileURL, model.isFileURL,
              FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.isReadableFile(atPath: model.path)
        else { return nil }

        let input = directory.appendingPathComponent("voice-activity.wav")
        let output = directory.appendingPathComponent("voice-activity.txt")
        do {
            try WAVCodec.encode(normalizedForDetection(audio)).write(to: input)
            try Data().write(to: output)
            let runner = DeadlineCommandRunner(base: SystemCommandRunner(output: output), timeout: .seconds(3))
            let status = try await runner.run(executable: executable, arguments: [
                "--vad-model", model.path, "--file", input.path, "--threads", "1", "--no-prints",
                "--vad-threshold", "0.5", "--vad-min-speech-duration-ms", "100"
            ])
            try Task.checkCancellation()
            guard status == 0 else { return nil }
            return try readDecision(at: output)
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    private func normalizedForDetection(_ audio: AudioClip) throws -> AudioClip {
        let scale = 32_768.0
        var squares = 0.0
        var peak = 0.0
        for sample in audio.samples {
            let value = Double(sample)
            squares += value * value
            peak = max(peak, abs(value))
        }
        guard peak > 0 else { return audio }
        let rms = sqrt(squares / Double(audio.samples.count))
        let gain = min(16, scale * 0.03 / rms, scale * 0.98 / peak)
        guard gain > 1 else { return audio }
        return try AudioClip(samples: audio.samples.map { Int16((Double($0) * gain).rounded()) })
    }

    private func readDecision(at output: URL) throws -> Bool? {
        let file = try FileHandle(forReadingFrom: output)
        defer { try? file.close() }
        let text = String(decoding: try file.read(upToCount: 1024) ?? Data(), as: UTF8.self)
        // This summary is emitted by the pinned whisper.cpp vad-speech-segments tool.
        let prefix = "Detected "
        let suffix = " speech segments:"
        guard let line = text.split(whereSeparator: \.isNewline).first(where: {
            $0.hasPrefix(prefix) && $0.hasSuffix(suffix)
        }), let count = Int(line.dropFirst(prefix.count).dropLast(suffix.count)), count >= 0 else { return nil }
        return count > 0
    }
}
