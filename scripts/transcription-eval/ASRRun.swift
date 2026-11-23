import Foundation
import SpeechFoundation
import SpeechInput

enum ASRModel: String, CaseIterable, Codable {
    case qwen = "qwen3-asr-1.7b-4bit"
    case whisper = "whisper-large-v3-turbo-q5_0"

    func recognizer(resources: URL) -> any SpeechRecognizer {
        switch self {
        case .qwen:
            QwenASRRecognizer(configuration: .init(
                executable: resources.appendingPathComponent("qwen-asr-runtime/qwen-asr"),
                model: resources.appendingPathComponent("Qwen3-ASR-1.7B-4bit")
            ))
        case .whisper:
            WhisperRecognizer(configuration: .init(
                executable: resources.appendingPathComponent("whisper-cli"),
                model: resources.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin"),
                useGPU: true,
                vadModel: resources.appendingPathComponent("ggml-silero-v5.1.2.bin"),
                flashAttention: true
            ))
        }
    }
}

struct ASRRun {
    struct Manifest: Decodable {
        struct Clip: Decodable {
            let id: String
            let audio: String
            let group: AccuracyGroup
            let reference: String
        }

        let clips: [Clip]

        func validated() throws -> Self {
            guard !clips.isEmpty, Set(clips.map(\.id)).count == clips.count, clips.allSatisfy({ clip in
                !clip.id.isEmpty && !clip.audio.isEmpty &&
                    ASRAccuracy.score(reference: clip.reference, hypothesis: "", group: clip.group).referenceUnits > 0
            }) else { throw EvaluationError.invalidManifest }
            return self
        }
    }

    struct Observation: Codable {
        let id: String
        let group: AccuracyGroup
        let model: ASRModel
        let reference: String
        let transcript: String?
        let score: AccuracyScore?
        let seconds: Double?
        let audioSeconds: Double?
        let failure: String?
    }

    struct Report: Codable {
        let formatVersion: Int
        let manifest: String
        let recognitionLanguage: String
        let expectedClips: Int
        let models: [ASRModel]
        var complete = false
        var observations: [Observation] = []
        var summaries: [Summary] = []
    }

    struct Summary: Codable {
        let model: ASRModel
        let group: AccuracyGroup
        let successful: Int
        let failed: Int
        let empty: Int
        let referenceUnits: Int
        let edits: Int
        let errorRate: Double?
        let medianSeconds: Double?

        init(model: ASRModel, group: AccuracyGroup, observations: [Observation]) {
            self.model = model
            self.group = group
            let scores = observations.compactMap(\.score)
            successful = scores.count
            failed = observations.count - successful
            empty = observations.compactMap(\.transcript).filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            referenceUnits = scores.reduce(0) { $0 + $1.referenceUnits }
            edits = scores.reduce(0) { $0 + $1.edits }
            errorRate = referenceUnits == 0 ? nil : Double(edits) / Double(referenceUnits)
            medianSeconds = median(observations.compactMap { $0.failure == nil ? $0.seconds : nil })
        }
    }

    let resources: URL

    func evaluate(manifestAt path: URL, output: URL) async throws -> Int {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: path)).validated()
        let directory = path.deletingLastPathComponent()
        var report = Report(formatVersion: 1, manifest: path.path, recognitionLanguage: "auto",
                            expectedClips: manifest.clips.count, models: ASRModel.allCases)
        try saveReport(report, at: output)
        for model in report.models {
            let recognizer = model.recognizer(resources: resources)
            do {
                for (index, clip) in manifest.clips.enumerated() {
                    report.observations.append(try await observe(clip, directory: directory, model: model, recognizer: recognizer))
                    try saveReport(report, at: output)
                    if (index + 1).isMultiple(of: 5) || index + 1 == manifest.clips.count {
                        print("ASR \(model.rawValue) \(index + 1)/\(manifest.clips.count)")
                    }
                }
            } catch {
                await recognizer.shutdown()
                throw error
            }
            await recognizer.shutdown()
        }
        report.complete = true
        report.summaries = report.models.flatMap { model in
            [AccuracyGroup.zh, .en, .mixed].compactMap { group in
                let rows = report.observations.filter { $0.model == model && $0.group == group }
                return rows.isEmpty ? nil : Summary(model: model, group: group, observations: rows)
            }
        }
        try saveReport(report, at: output)
        return report.observations.filter { $0.failure != nil }.count
    }

    private func observe(_ clip: Manifest.Clip, directory: URL, model: ASRModel,
                         recognizer: any SpeechRecognizer) async throws -> Observation {
        var start: ContinuousClock.Instant?
        var length: Double?
        do {
            let file = URL(fileURLWithPath: clip.audio, relativeTo: directory)
            let audio = try WAVCodec.decode(Data(contentsOf: file))
            length = Double(audio.samples.count) / Double(AudioClip.sampleRate)
            let now = ContinuousClock.now
            start = now
            let result = try await recognizer.transcribe(audio, options: .init(language: .automatic))
            let seconds = elapsedSeconds(since: now)
            let score = ASRAccuracy.score(reference: clip.reference, hypothesis: result.text, group: clip.group)
            return Observation(id: clip.id, group: clip.group, model: model, reference: clip.reference,
                               transcript: result.text, score: score, seconds: seconds, audioSeconds: length, failure: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Observation(id: clip.id, group: clip.group, model: model, reference: clip.reference,
                               transcript: nil, score: nil, seconds: start.map { elapsedSeconds(since: $0) },
                               audioSeconds: length, failure: failureName(error))
        }
    }
}

func median(_ values: [Double]) -> Double? {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return nil }
    let midpoint = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[midpoint - 1] + sorted[midpoint]) / 2 : sorted[midpoint]
}
