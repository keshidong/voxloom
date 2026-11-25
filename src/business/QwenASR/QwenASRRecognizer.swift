import Foundation
import SpeechFoundation

public struct QwenASRConfiguration: Sendable {
    public let executable: URL
    public let model: URL
    public let timeout: Duration
    public let voiceActivity: QwenVoiceActivityConfiguration?
    public init(executable: URL, model: URL, timeout: Duration = .seconds(90),
                voiceActivity: QwenVoiceActivityConfiguration? = nil) {
        self.executable = executable
        self.model = model
        self.timeout = timeout
        self.voiceActivity = voiceActivity
    }
}

public actor QwenASRRecognizer: SpeechRecognizer {
    let configuration: QwenASRConfiguration
    let factory: @Sendable () -> any JSONWorkerRunning
    let temporaryDirectory: URL
    private var worker: (any JSONWorkerRunning)?
    private var preparation: Task<Void, Never>?
    private var voiceActivityTask: Task<Bool?, any Error>?
    private var generation = 0
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

    public func prepare() async {
        if let preparation { await preparation.value; return }
        guard !Task.isCancelled, !busy, worker == nil,
              (try? validateResources()) != nil else { return }
        let candidate = factory()
        let preparation = Task { [self] in
            do {
                try await candidate.prepare(within: min(configuration.timeout, .seconds(30)))
                try Task.checkCancellation()
                worker = candidate
            } catch {
                await candidate.shutdown()
            }
            self.preparation = nil
        }
        self.preparation = preparation
        await preparation.value
    }

    public func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
        try Task.checkCancellation()
        guard !busy else { throw RecognitionError.busy }
        guard !audio.samples.isEmpty else { throw RecognitionError.emptyAudio }
        guard Self.containsSustainedAudio(audio.samples) else { return Transcript(text: "") }
        guard options.context.utf8.count <= 4096 else { throw RecognitionError.invalidConfiguration }
        try validateResources()
        busy = true
        defer { busy = false }
        let generation = self.generation
        let job = temporaryDirectory.appendingPathComponent("qwen-asr-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw RecognitionError.fileAccess }
        defer { try? FileManager.default.removeItem(at: job) }
        let speech = try await detectSpeech(audio, in: job)
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        if speech == false {
            return Transcript(text: "")
        }
        await preparation?.value
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
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

    private func detectSpeech(_ audio: AudioClip, in job: URL) async throws -> Bool? {
        guard let configuration = configuration.voiceActivity else { return nil }
        let detection = Task { try await QwenVoiceActivity(configuration: configuration).detectsSpeech(audio, in: job) }
        voiceActivityTask = detection
        defer { voiceActivityTask = nil }
        return try await withTaskCancellationHandler {
            try await detection.value
        } onCancel: {
            detection.cancel()
        }
    }

    public func shutdown() async {
        generation += 1
        let detection = voiceActivityTask
        detection?.cancel()
        preparation?.cancel()
        _ = try? await detection?.value
        await preparation?.value
        await worker?.shutdown()
        worker = nil
    }

    private static func containsSustainedAudio(_ samples: [Int16]) -> Bool {
        let frameSize = AudioClip.sampleRate / 50  // 20 ms
        let minimumRMS = 32_768.0 * 0.001  // −60 dBFS, below the live recording threshold
        let minimumPower = minimumRMS * minimumRMS
        let framesPerWindow = 10  // Compare the energy of 200 ms windows.
        let frameCount = samples.count / frameSize
        let checkBackground = frameCount >= 5 * framesPerWindow
        let maximumBackgroundRMS = 32_768.0 * 0.025
        let maximumBackgroundPower = maximumBackgroundRMS * maximumBackgroundRMS
        let maximumBackgroundContrast = 2.25  // 1.5× in RMS
        var activeFrames = 0
        var hasSustainedAudio = false
        var windowPower = 0.0
        var windowFrames = 0
        var lowestPower = Double.infinity
        var highestPower = 0.0
        for frame in 0..<frameCount {
            let start = frame * frameSize
            var sum = 0.0
            var sumOfSquares = 0.0
            for sample in samples[start..<(start + frameSize)] {
                let value = Double(sample)
                sum += value
                sumOfSquares += value * value
            }
            // Subtract the DC component so a constant input offset cannot activate recognition.
            let mean = sum / Double(frameSize)
            let power = sumOfSquares / Double(frameSize) - mean * mean
            activeFrames = power >= minimumPower ? activeFrames + 1 : 0
            hasSustainedAudio = hasSustainedAudio || activeFrames >= 3
            if hasSustainedAudio && !checkBackground { return true }

            windowPower += power
            windowFrames += 1
            if windowFrames == framesPerWindow || frame == frameCount - 1 {
                let averagePower = windowPower / Double(windowFrames)
                lowestPower = min(lowestPower, averagePower)
                highestPower = max(highestPower, averagePower)
                windowPower = 0
                windowFrames = 0
            }
            // Quiet audio with a steady envelope can be a fan or mains hum.
            if hasSustainedAudio,
               highestPower > maximumBackgroundPower || highestPower > lowestPower * maximumBackgroundContrast {
                return true
            }
        }
        return false
    }

    private func validateResources() throws {
        guard configuration.executable.isFileURL, configuration.model.isFileURL, configuration.timeout > .zero
        else { throw RecognitionError.invalidConfiguration }
        guard FileManager.default.isExecutableFile(atPath: configuration.executable.path)
        else { throw RecognitionError.engineUnavailable }
        guard FileManager.default.isReadableFile(atPath: configuration.model.appendingPathComponent("model.safetensors").path)
        else { throw RecognitionError.modelUnavailable }
    }
    private struct Request: Encodable { let audio: String; let language: String; let context: String }
}
