import Foundation
import SpeechFoundation
@testable import SpeechInput
import Testing

private let audibleTestSamples = (0..<(AudioClip.sampleRate / 10)).map { index in
    Int16(128 * sin(Double(index) * 2 * .pi * 220 / Double(AudioClip.sampleRate)))
}
private let publicSpeechFixtures = ProcessInfo.processInfo.environment["VOXLOOM_QWEN_SPEECH_FIXTURES"]

private final class ASRBoundary: JSONWorkerRunning, @unchecked Sendable {
    let lock = NSLock()
    var calls = 0
    var preparations = 0
    func prepare() async throws { lock.withLock { preparations += 1 } }
    func request(_ data: Data) async throws -> Data {
        let request = try JSONSerialization.jsonObject(with: data) as! [String: String]
        #expect(request["context"] == "图书卡 预付费 USD")
        #expect(request["language"] == "zh")
        let audio = try Data(contentsOf: URL(fileURLWithPath: request["audio"]!))
        #expect(try WAVCodec.decode(audio).samples == audibleTestSamples)
        lock.withLock { calls += 1 }
        return Data(#"{"text":"图书卡额度采用预付费模式","language":"zh"}"#.utf8)
    }
    func close() {}
}

struct QwenASRRecognizerTests {
    @Test func shuttingDownCancelsVoiceActivityBeforeItCanStartRecognition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = ASRBoundary()
        let provider = try recognizerWithDetector(in: root, script: """
        #!/bin/sh
        touch "$0.started"
        exec /bin/sleep 30
        """, worker: worker)

        let transcription = Task {
            try await provider.transcribe(AudioClip(samples: audibleTestSamples),
                options: .init(language: .chinese, context: "图书卡 预付费 USD"))
        }
        defer { transcription.cancel() }
        let marker = root.appendingPathComponent("vad.started")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: marker.path) {
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }

        await provider.shutdown()
        await #expect(throws: CancellationError.self) { try await transcription.value }
        #expect(worker.calls == 0)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("qwen-asr-") })
    }

    @Test(arguments: [
        "printf '%s\\n' 'Detected 1 speech segments:'",
        "printf '%s\\n' 'unexpected output'",
        "printf '%s\\n' 'Detected 0 speech segments:'; exit 2"
    ])
    func voiceActivityLeavesTheOriginalAudioIntactForRecognition(output: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = ASRBoundary()
        let provider = try recognizerWithDetector(in: root, script: """
        #!/bin/sh
        /bin/cp "$4" "$0.wav"
        \(output)
        """, worker: worker)

        let result = try await provider.transcribe(AudioClip(samples: audibleTestSamples),
            options: .init(language: .chinese, context: "图书卡 预付费 USD"))
        #expect(result.text == "图书卡额度采用预付费模式")
        #expect(worker.calls == 1)
        let normalized = try WAVCodec.decode(Data(contentsOf: root.appendingPathComponent("vad.wav")))
        #expect(normalized.samples.count == audibleTestSamples.count)
        let power = normalized.samples.reduce(0.0) { sum, sample in
            let level = Double(sample) / 32768
            return sum + level * level
        }
        let rms = sqrt(power / Double(normalized.samples.count))
        #expect(abs(rms - 0.03) < 0.00002)
        await provider.shutdown()
    }

    private func recognizerWithDetector(in root: URL, script: String, worker: ASRBoundary) throws -> QwenASRRecognizer {
        let model = root.appendingPathComponent("model.safetensors")
        try Data().write(to: model)
        let detector = root.appendingPathComponent("vad")
        try Data(script.utf8).write(to: detector)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: detector.path)
        return QwenASRRecognizer(configuration: .init(executable: URL(fileURLWithPath: "/usr/bin/true"), model: root,
            voiceActivity: .init(executable: detector, model: model)), temporaryDirectory: root, factory: { worker })
    }

    @Test func backgroundPreparationReusesTheWorkerWithoutSubmittingAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("model.safetensors"))
        let boundary = ASRBoundary()
        let provider = QwenASRRecognizer(configuration: .init(executable: URL(fileURLWithPath: "/usr/bin/true"),
                                                               model: root), temporaryDirectory: root,
            factory: { boundary })
        await provider.prepare()
        await provider.prepare()
        #expect(boundary.preparations == 1)
        #expect(boundary.calls == 0)
        let result = try await provider.transcribe(AudioClip(samples: audibleTestSamples),
            options: .init(language: .chinese, context: "图书卡 预付费 USD"))
        #expect(result.text == "图书卡额度采用预付费模式")
        #expect(boundary.calls == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["model.safetensors"])
        await provider.shutdown()
    }

    @Test func configurationMissingResourcesInvalidResultAndFileErrorsRemainDistinct() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data().write(to: model.appendingPathComponent("model.safetensors"))
        let exe = URL(fileURLWithPath: "/usr/bin/true")
        let audio = try AudioClip(samples: audibleTestSamples)
        for (config, expected) in [
            (QwenASRConfiguration(executable: exe, model: model, timeout: .zero), RecognitionError.invalidConfiguration),
            (.init(executable: URL(fileURLWithPath: "/missing"), model: model), .engineUnavailable),
            (.init(executable: exe, model: root), .modelUnavailable)] {
            let provider = QwenASRRecognizer(configuration: config)
            await #expect(throws: expected) { try await provider.transcribe(audio, options: .init()) }
        }
        let provider = QwenASRRecognizer(configuration: .init(executable: exe, model: model), temporaryDirectory: root,
            factory: { InvalidASRBoundary() })
        await #expect(throws: RecognitionError.emptyAudio) { try await provider.transcribe(AudioClip(samples: []), options: .init()) }
        await #expect(throws: RecognitionError.invalidConfiguration) {
            try await provider.transcribe(audio, options: .init(context: String(repeating: "x", count: 4097)))
        }
        await #expect(throws: RecognitionError.invalidResult) { try await provider.transcribe(audio, options: .init()) }
        await provider.shutdown()
        let noDirectory = QwenASRRecognizer(configuration: .init(executable: exe, model: model),
            temporaryDirectory: model.appendingPathComponent("model.safetensors"), factory: { InvalidASRBoundary() })
        await #expect(throws: RecognitionError.fileAccess) { try await noDirectory.transcribe(audio, options: .init()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["model"])
    }
    @Test func digitalSilenceReturnsNoInventedWords() async throws {
        let provider = QwenASRRecognizer(configuration: .init(executable: URL(fileURLWithPath: "/missing"), model: URL(fileURLWithPath: "/missing-model")))
        let result = try await provider.transcribe(AudioClip(samples: Array(repeating: 0, count: 16_000)), options: .init())
        #expect(result.text.isEmpty)
    }

    @Test(arguments: [false, true])
    func lowLevelNoiseAndBriefClicksReturnNoTranscript(withClick: Bool) async throws {
        var samples = (0..<AudioClip.sampleRate).map { Int16($0 * 73 % 61 - 30) }
        if withClick {
            for index in 6960..<7040 { samples[index] = index.isMultiple(of: 2) ? 12_000 : -12_000 }
        }
        let provider = QwenASRRecognizer(configuration: .init(executable: URL(fileURLWithPath: "/missing"),
                                                               model: URL(fileURLWithPath: "/missing-model")))
        let result = try await provider.transcribe(AudioClip(samples: samples),
            options: .init(language: .chinese, context: "图书卡 预付费 USD"))
        #expect(result.text.isEmpty)
    }

    enum BackgroundNoise: CaseIterable { case hum, fan, wideband }

    @Test(arguments: BackgroundNoise.allCases)
    func steadyBackgroundAboveTheVolumeGateReturnsNoTranscript(noise: BackgroundNoise) async throws {
        var random: UInt32 = 4122
        var filtered = 0.0
        let audio = try AudioClip(samples: (0..<(2 * AudioClip.sampleRate)).map { index in
            random = random &* 1_664_525 &+ 1_013_904_223
            let value = Double(random) / Double(UInt32.max) * 2 - 1
            filtered = 0.97 * filtered + 0.03 * value
            switch noise {
            case .hum: return Int16(200 * sin(Double(index) * 2 * .pi * 60 / Double(AudioClip.sampleRate)))
            case .fan: return Int16(2_000 * filtered)
            case .wideband: return Int16(250 * value)
            }
        })
        let provider = QwenASRRecognizer(configuration: .init(executable: URL(fileURLWithPath: "/missing"),
                                                               model: URL(fileURLWithPath: "/missing-model")))
        let result = try await provider.transcribe(audio, options: .init(language: .chinese))
        #expect(result.text.isEmpty)
    }

    @Test(.enabled(if: publicSpeechFixtures != nil, "Set VOXLOOM_QWEN_SPEECH_FIXTURES to the public evaluation corpus"))
    func backgroundGateKeepsTheFullPublicSpeechCorpus() async throws {
        let root = URL(fileURLWithPath: try #require(publicSpeechFixtures))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
        try #require(files.count == 1965)
        let provider = QwenASRRecognizer(configuration: .init(executable: URL(fileURLWithPath: "/missing"), model: root))
        var legacyPassCounts: [Int: Int] = [:]
        for file in files {
            let original = try WAVCodec.decode(Data(contentsOf: file))
            for divisor: Int16 in [1, 8] {
                let clip = divisor == 1 ? original : try AudioClip(samples: original.samples.map { $0 / divisor })
                guard legacyGateWouldPass(clip.samples) else { continue }
                legacyPassCounts[Int(divisor), default: 0] += 1
                do {
                    _ = try await provider.transcribe(clip, options: .init())
                    Issue.record("New speech rejection for \(file.lastPathComponent) at gain 1/\(divisor)")
                } catch RecognitionError.engineUnavailable {
                    // The gate allowed the sample to reach the deliberately absent worker.
                }
            }
        }
        #expect(legacyPassCounts == [1: 1950, 8: 1531])
    }

    // The pre-change Qwen gate is fixed here for a per-recording A/B comparison.
    private func legacyGateWouldPass(_ samples: [Int16]) -> Bool {
        let frameSize = AudioClip.sampleRate / 50
        let minimumRMS = 32768.0 * 0.001
        var consecutive = 0
        for start in stride(from: 0, through: samples.count - frameSize, by: frameSize) {
            let frame = samples[start..<(start + frameSize)]
            let sum = frame.reduce(0.0) { $0 + Double($1) }
            let sumOfSquares = frame.reduce(0.0) { $0 + Double($1) * Double($1) }
            let mean = sum / Double(frameSize)
            let power = sumOfSquares / Double(frameSize) - mean * mean
            consecutive = power >= minimumRMS * minimumRMS ? consecutive + 1 : 0
            if consecutive == 3 { return true }
        }
        return false
    }

    @Test func commonInterfacePassesLanguageAndContextToAResidentWorker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data().write(to: model.appendingPathComponent("model.safetensors"))
        let boundary = ASRBoundary()
        let provider: any SpeechRecognizer = QwenASRRecognizer(configuration: .init(executable: URL(fileURLWithPath: "/usr/bin/true"), model: model),
            temporaryDirectory: root, factory: { boundary })
        for _ in 0..<2 {
            let result = try await provider.transcribe(AudioClip(samples: audibleTestSamples), options: .init(language: .chinese, context: "图书卡 预付费 USD"))
            #expect(result.text == "图书卡额度采用预付费模式")
        }
        #expect(boundary.calls == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["model"])
    }
}

private struct InvalidASRBoundary: JSONWorkerRunning {
    func request(_ data: Data) async throws -> Data { Data(#"{"error":"inference_failed"}"#.utf8) }
    func close() {}
}
