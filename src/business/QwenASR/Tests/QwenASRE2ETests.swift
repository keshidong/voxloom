import Foundation
import SpeechFoundation
import SpeechInput
import Testing

private let root = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { path, _ in path.deletingLastPathComponent() }
private let bundleResources = ProcessInfo.processInfo.environment["VOICE_INPUT_DEMO_RESOURCES"].map { URL(fileURLWithPath: $0) }
private let asrExecutable = bundleResources?.appendingPathComponent("qwen-asr-runtime/qwen-asr") ?? root.appendingPathComponent(".runtime/qwen-asr-runtime/qwen-asr")
private let asrModel = bundleResources?.appendingPathComponent("Qwen3-ASR-1.7B-4bit") ?? root.appendingPathComponent("models/Qwen3-ASR-1.7B-4bit")
private let llmExecutable = bundleResources?.appendingPathComponent("llama-completion") ?? root.appendingPathComponent(".runtime/llama-build/bin/llama-completion")
private let llmModel = bundleResources?.appendingPathComponent("Qwen3-4B-Instruct-2507-Q4_K_M.gguf") ?? root.appendingPathComponent("models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")
private let chineseAudio = bundleResources?.appendingPathComponent("chinese.wav") ?? root.appendingPathComponent(".runtime/asr_zh.wav")
private let englishAudio = bundleResources?.appendingPathComponent("english.wav") ?? root.appendingPathComponent(".runtime/whisper.cpp-1.8.2/samples/jfk.wav")
private let corpusPath = ProcessInfo.processInfo.environment["VOXLOOM_CORRECTION_CORPUS"]
private let noiseFixtures = ProcessInfo.processInfo.environment["VOXLOOM_QWEN_NOISE_FIXTURES"]
private let shortAcknowledgement = ProcessInfo.processInfo.environment["VOXLOOM_QWEN_SHORT_ACK_WAV"]
private let voiceActivity = QwenVoiceActivityConfiguration(
    executable: bundleResources?.appendingPathComponent("vad-speech-segments")
        ?? root.appendingPathComponent(".runtime/whisper-build/bin/vad-speech-segments"),
    model: bundleResources?.appendingPathComponent("ggml-silero-v5.1.2.bin")
        ?? root.appendingPathComponent("models/ggml-silero-v5.1.2.bin"),
    workerExecutable: bundleResources?.appendingPathComponent("voxloom-vad")
        ?? root.appendingPathComponent(".runtime/whisper-build/bin/voxloom-vad"))
private let hasVoiceActivity = FileManager.default.isExecutableFile(atPath: voiceActivity.executable.path)
    && FileManager.default.isReadableFile(atPath: voiceActivity.model.path)

@Suite(.serialized) struct QwenASRE2ETests {
    @Test(.enabled(if: noiseFixtures != nil, "Run scripts/prepare-qwen-noise-fixtures.py first"),
          arguments: ["public-noise-48dBFS", "public-noise-38dBFS"])
    func realBackgroundNoiseDoesNotRegainFalseTranscripts(level: String) async throws {
        try #require(hasVoiceActivity)
        let fixtures = URL(fileURLWithPath: try #require(noiseFixtures)).appendingPathComponent(level)
        let files = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(files.count == 31)
        try #require(files.filter { $0.lastPathComponent.hasPrefix("AirConditioner_") }.count == 10)
        let recognizer = QwenASRRecognizer(configuration: .init(executable: asrExecutable, model: asrModel,
                                                               voiceActivity: voiceActivity))
        var falseTranscripts = 0
        var airConditionerFalseTranscripts = 0
        do {
            for file in files {
                let audio = try WAVCodec.decode(Data(contentsOf: file))
                try #require(audio.samples.count == 2 * AudioClip.sampleRate)
                let result = try await recognizer.transcribe(audio, options: .init(language: .chinese))
                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                falseTranscripts += 1
                if file.lastPathComponent.hasPrefix("AirConditioner_") { airConditionerFalseTranscripts += 1 }
            }
        } catch {
            await recognizer.shutdown()
            throw error
        }
        await recognizer.shutdown()
        #expect(falseTranscripts == 0)
        #expect(airConditionerFalseTranscripts == 0)
        print("\(level): false transcripts \(falseTranscripts)/31, air conditioners \(airConditionerFalseTranscripts)/10")
    }

    @Test(.enabled(if: shortAcknowledgement != nil, "Set VOXLOOM_QWEN_SHORT_ACK_WAV to the short Mandarin fixture"))
    func realQwenKeepsASpokenShortAcknowledgement() async throws {
        try #require(hasVoiceActivity)
        let fixture = URL(fileURLWithPath: try #require(shortAcknowledgement))
        let audio = try WAVCodec.decode(Data(contentsOf: fixture))
        try #require(audio.duration < 1)
        let recognizer = QwenASRRecognizer(configuration: .init(executable: asrExecutable, model: asrModel,
                                                               voiceActivity: voiceActivity))
        do {
            let result = try await recognizer.transcribe(audio, options: .init(language: .chinese))
            #expect(result.text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)) == "嗯")
        } catch {
            await recognizer.shutdown()
            throw error
        }
        await recognizer.shutdown()
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: asrExecutable.path)
                      && FileManager.default.fileExists(atPath: asrModel.appendingPathComponent("model.safetensors").path)))
    func keywordContextKeepsTheTranscriptGroundedAndSilenceEmpty() async throws {
        let recognizer = QwenASRRecognizer(configuration: .init(executable: asrExecutable, model: asrModel))
        let hints = RecognitionOptions(language: .chinese, context: "交易 停滞")
        let noHints = RecognitionOptions(language: .chinese)
        do {
            let audio = try WAVCodec.decode(Data(contentsOf: chineseAudio))
            let baseline = try await recognizer.transcribe(audio, options: noHints)
            let contextual = try await recognizer.transcribe(audio, options: hints)
            #expect(baseline.text.contains("交易几乎停滞"))
            #expect(contextual.text.contains("交易几乎停滞"))
            let quiet = try AudioClip(samples: Array(repeating: 0, count: AudioClip.sampleRate))
            let silence = try await recognizer.transcribe(quiet, options: hints)
            #expect(silence.text.isEmpty)
            await recognizer.shutdown()
        } catch { await recognizer.shutdown(); throw error }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: asrModel.appendingPathComponent("model.safetensors").path)),
          arguments: [false, true])
    func residentASRAndLLMProduceSeparateTextsInTheRealOfflinePipeline(withManualHints: Bool) async throws {
        let asr: any SpeechRecognizer = QwenASRRecognizer(configuration: .init(
            executable: asrExecutable, model: asrModel))
        let corrector: any TextCorrecting = QwenTextCorrector(configuration: .init(
            executable: llmExecutable, model: llmModel))
        do {
            let audio = try WAVCodec.decode(Data(contentsOf: chineseAudio))
            let hints = withManualHints ? "市场 交易" : ""
            let reference = withManualHints ? "此前讨论过市场交易情况。档案编号 ZEN-731。" : ""
            let original = try await asr.transcribe(audio, options: .init(language: .chinese, context: hints))
            let candidate = try await corrector.correct(.init(text: original.text, surroundingText: reference))
            #expect(original.text.contains("交易"))
            #expect(candidate.original == original.text)
            #expect(candidate.text.contains("交易"))
            #expect(!candidate.text.contains("ZEN-731"))
            await asr.shutdown()
        } catch { await asr.shutdown(); throw error }
    }
    @Test(.enabled(if: FileManager.default.fileExists(atPath: asrModel.appendingPathComponent("model.safetensors").path)))
    func realResidentModelTranscribesChineseEnglishAndSilenceViaPublicInterface() async throws {
        let recognizer: any SpeechRecognizer = QwenASRRecognizer(configuration: .init(
            executable: asrExecutable, model: asrModel, voiceActivity: hasVoiceActivity ? voiceActivity : nil))
        do {
            let chinese = try WAVCodec.decode(Data(contentsOf: chineseAudio))
            let result = try await recognizer.transcribe(chinese, options: .init(language: .chinese, context: "交易 停滞"))
            #expect(result.text.contains("甚至出现交易几乎停滞的情况"))
            let quietChinese = try AudioClip(samples: chinese.samples.map { $0 / 8 })
            let quietResult = try await recognizer.transcribe(quietChinese, options: .init(language: .chinese))
            #expect(quietResult.text.contains("交易几乎停滞"))
            let english = try WAVCodec.decode(Data(contentsOf: englishAudio))
            let en = try await recognizer.transcribe(english, options: .init(language: .english))
            #expect(en.text.lowercased().contains("ask not what your country can do for you"))
            let silence = try await recognizer.transcribe(AudioClip(samples: Array(repeating: 0, count: 16_000)), options: .init(language: .chinese))
            #expect(silence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            await recognizer.shutdown()
        } catch {
            await recognizer.shutdown()
            throw error
        }
    }
}

struct QwenCorrectionCorpusE2ETests {
    @Test(.enabled(if: corpusPath != nil, "Set VOXLOOM_CORRECTION_CORPUS to a local manifest"))
    func evaluatesASRAndCorrectionAgainstPairedReferences() async throws {
        let manifest = URL(fileURLWithPath: try #require(corpusPath))
        let corpus = try CorrectionCorpus(data: Data(contentsOf: manifest))
        let asr = QwenASRRecognizer(configuration: .init(executable: asrExecutable, model: asrModel))
        let corrector = QwenTextCorrector(configuration: .init(executable: llmExecutable, model: llmModel))
        var referenceCharacters = 0
        var rawEdits = 0
        var correctedEdits = 0
        var empty = 0
        var regressions = 0
        var numberChanges = 0
        do {
            for (index, clip) in corpus.clips.enumerated() {
                let wav = manifest.deletingLastPathComponent().appendingPathComponent(clip.audio)
                let audio = try clip.decodeAudio(Data(contentsOf: wav, options: .mappedIfSafe))
                let language = RecognitionLanguage(rawValue: clip.language ?? "auto") ?? .automatic
                let original = try await asr.transcribe(audio, options: .init(language: language)).text
                let isEmpty = original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let before = CorrectionCorpus.score(original, reference: clip.reference)
                let candidate: CorrectionCandidate
                if isEmpty {
                    empty += 1
                    candidate = CorrectionCandidate(text: original, original: original)
                } else {
                    candidate = try await corrector.correct(.init(text: original, vocabulary: clip.vocabulary ?? ""))
                }
                let retainsOriginal = original == candidate.original
                #expect(retainsOriginal)
                let after = CorrectionCorpus.score(candidate.text, reference: clip.reference)
                referenceCharacters += before.referenceCharacters
                rawEdits += before.edits
                correctedEdits += after.edits
                if after.edits > before.edits { regressions += 1 }
                if candidate.numbersChanged { numberChanges += 1 }
                print("corpus window \(index + 1): reference=\(before.referenceCharacters), ASR=\(before.edits), corrected=\(after.edits)")
            }
        } catch {
            await asr.shutdown()
            throw error
        }
        await asr.shutdown()
        print("corpus windows=\(corpus.clips.count), reference=\(referenceCharacters), ASR=\(rawEdits), "
              + "corrected=\(correctedEdits), regressions=\(regressions), numberChanges=\(numberChanges), emptyASR=\(empty)")
    }
}
