import Foundation
import SpeechFoundation

public struct QwenVoiceActivityConfiguration: Sendable {
    public let executable: URL
    public let model: URL
    public let workerExecutable: URL?

    public init(executable: URL, model: URL, workerExecutable: URL? = nil) {
        self.executable = executable
        self.model = model
        self.workerExecutable = workerExecutable
    }
}

actor QwenVoiceActivity {
    private let configuration: QwenVoiceActivityConfiguration
    private var worker: JSONLineWorker?
    private var workerIsReady = false

    init(configuration: QwenVoiceActivityConfiguration) { self.configuration = configuration }

    func prepare() async {
        guard !Task.isCancelled, worker == nil, let candidate = residentWorker() else { return }
        do { try await waitUntilReady(candidate) }
        catch { await discard(candidate) }
    }

    func shutdown() async {
        if let worker { await discard(worker) }
    }

    /// Returns nil when the optional detector cannot make a decision.
    func detectsSpeech(_ audio: AudioClip, in directory: URL) async throws -> Bool? {
        let model = configuration.model
        guard model.isFileURL, FileManager.default.isReadableFile(atPath: model.path) else { return nil }
        let input = directory.appendingPathComponent("voice-activity.wav")
        do {
            try WAVCodec.encode(normalizedForDetection(audio)).write(to: input)
            if let worker = residentWorker() {
                return try await detectWithWorker(worker, input: input)
            }
            return try await detectWithCommand(input: input, in: directory)
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    private func residentWorker() -> JSONLineWorker? {
        if let worker { return worker }
        guard let executable = configuration.workerExecutable, executable.isFileURL,
              FileManager.default.isExecutableFile(atPath: executable.path), configuration.model.isFileURL,
              FileManager.default.isReadableFile(atPath: configuration.model.path) else { return nil }
        let candidate = JSONLineWorker(executable: executable, arguments: ["--model", configuration.model.path])
        worker = candidate
        return candidate
    }

    private func detectWithWorker(_ worker: JSONLineWorker, input: URL) async throws -> Bool {
        do {
            try await waitUntilReady(worker)
            let request = try JSONEncoder().encode(["audio": input.path])
            let reply = try await worker.request(request, within: .seconds(3))
            return try JSONDecoder().decode(Detection.self, from: reply).speech
        } catch {
            await discard(worker)
            throw error
        }
    }

    private func waitUntilReady(_ candidate: JSONLineWorker) async throws {
        guard !workerIsReady else { return }
        // Model startup has its own deadline so it does not consume the detection budget.
        try await candidate.prepare(within: .seconds(8))
        if worker === candidate { workerIsReady = true }
    }

    private func discard(_ candidate: JSONLineWorker) async {
        if worker === candidate {
            worker = nil
            workerIsReady = false
        }
        await candidate.shutdown()
    }

    private func detectWithCommand(input: URL, in directory: URL) async throws -> Bool? {
        let executable = configuration.executable
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let output = directory.appendingPathComponent("voice-activity.txt")
        try Data().write(to: output)
        let runner = DeadlineCommandRunner(base: SystemCommandRunner(output: output), timeout: .seconds(3))
        let status = try await runner.run(executable: executable, arguments: [
            "--vad-model", configuration.model.path, "--file", input.path, "--threads", "1", "--no-prints",
            "--vad-threshold", "0.5", "--vad-min-speech-duration-ms", "100"
        ])
        try Task.checkCancellation()
        guard status == 0 else { return nil }
        return try readDecision(at: output)
    }

    private struct Detection: Decodable { let speech: Bool }

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
        guard gain > 1, hasSustainedLevelContrast(audio.samples) else { return audio }
        return try AudioClip(samples: audio.samples.map { Int16((Double($0) * gain).rounded()) })
    }

    private func hasSustainedLevelContrast(_ samples: [Int16]) -> Bool {
        let frameSize = AudioClip.sampleRate / 50  // 20 ms
        let windowSize = 5  // 100 ms
        let frameCount = samples.count / frameSize
        guard frameCount >= windowSize else { return false }
        let powers = (0..<frameCount).map { frame -> Double in
            let start = frame * frameSize
            var sum = 0.0
            var squares = 0.0
            for sample in samples[start..<(start + frameSize)] {
                let value = Double(sample)
                sum += value
                squares += value * value
            }
            let mean = sum / Double(frameSize)
            return squares / Double(frameSize) - mean * mean
        }
        // Estimate the noise floor from quiet frames. A few loud samples should
        // not make a detector amplify the entire recording of a quiet room.
        let noiseFloor = powers.sorted()[frameCount / 5]
        let threshold = 6.25 * noiseFloor  // 2.5× in RMS
        let aboveFloor = powers.map { $0 > threshold }
        var active = 0
        for index in aboveFloor.indices {
            if aboveFloor[index] { active += 1 }
            if index >= windowSize, aboveFloor[index - windowSize] { active -= 1 }
            if index >= windowSize - 1, active >= 3 { return true }
        }
        return false
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
