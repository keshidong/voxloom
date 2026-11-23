import Foundation
import SpeechFoundation
import SpeechInput

struct CorrectionRun {
    private struct Clip: Decodable {
        let id: String
        let group: AccuracyGroup
        let reference: String
        let transcript: String?
        let failure: String?
    }

    private struct Dataset: Decodable {
        let clips: [Clip]

        func validated() throws -> [Clip] {
            guard !clips.isEmpty, Set(clips.map(\.id)).count == clips.count,
                  clips.allSatisfy({ clip in
                      !clip.id.isEmpty && clip.transcript != nil && clip.failure == nil &&
                          ASRAccuracy.score(reference: clip.reference, hypothesis: "", group: clip.group).referenceUnits > 0
                  }) else { throw EvaluationError.invalidManifest }
            return clips
        }
    }

    enum Status: String, Codable {
        case completed, emptyASR, unavailableASR, failed
    }

    struct Observation: Codable {
        let id: String
        let group: AccuracyGroup
        let status: Status
        let original: String?
        let corrected: String?
        let score: CorrectionAccuracyScore?
        let seconds: Double?
        let numbersChanged: Bool?
        let failure: String?
    }

    struct Report: Codable {
        let formatVersion: Int
        let asrReport: String?
        let asrModel: ASRModel?
        let datasetManifest: String?
        let model: String
        let mode: String
        let expectedClips: Int
        let comparisonDeadlineSeconds: Double
        var complete = false
        var observations: [Observation] = []
        var summaries: [Summary] = []
    }

    struct Summary: Codable {
        let group: AccuracyGroup
        let completed: Int
        let emptyASR: Int
        let unavailableASR: Int
        let failed: Int
        let improved: Int
        let unchanged: Int
        let worse: Int
        let numbersChanged: Int
        let withinDeadline: Int
        let beyondDeadline: Int
        let referenceUnits: Int
        let beforeEdits: Int
        let afterEdits: Int
        let beforeErrorRate: Double?
        let afterErrorRate: Double?
        let medianSeconds: Double?

        init(group: AccuracyGroup, observations: [Observation], deadline: Double) {
            self.group = group
            let inference = observations.filter { $0.status == .completed }
            completed = inference.count
            emptyASR = observations.filter { $0.status == .emptyASR }.count
            unavailableASR = observations.filter { $0.status == .unavailableASR }.count
            failed = observations.filter { $0.status == .failed }.count
            let scores = observations.compactMap(\.score)
            improved = scores.filter { $0.comparison == .improved }.count
            unchanged = scores.filter { $0.comparison == .unchanged }.count
            worse = scores.filter { $0.comparison == .worse }.count
            numbersChanged = inference.filter { $0.numbersChanged == true }.count
            let times = inference.compactMap(\.seconds)
            withinDeadline = times.filter { $0 <= deadline }.count
            beyondDeadline = times.count - withinDeadline
            referenceUnits = scores.reduce(0) { $0 + $1.before.referenceUnits }
            beforeEdits = scores.reduce(0) { $0 + $1.before.edits }
            afterEdits = scores.reduce(0) { $0 + $1.after.edits }
            beforeErrorRate = referenceUnits == 0 ? nil : Double(beforeEdits) / Double(referenceUnits)
            afterErrorRate = referenceUnits == 0 ? nil : Double(afterEdits) / Double(referenceUnits)
            medianSeconds = median(times)
        }
    }

    let resources: URL

    func evaluate(asrReportAt path: URL, output: URL) async throws -> Int {
        let asr = try JSONDecoder().decode(ASRRun.Report.self, from: Data(contentsOf: path))
        let frozen = asr.observations.filter { $0.model == .qwen }
        guard asr.formatVersion == 1, asr.expectedClips > 0, frozen.count == asr.expectedClips,
              Set(frozen.map(\.id)).count == frozen.count else { throw EvaluationError.incompleteASRInput }
        let clips = frozen.map {
            Clip(id: $0.id, group: $0.group, reference: $0.reference, transcript: $0.transcript, failure: $0.failure)
        }
        return try await evaluate(clips, asrReport: path, output: output)
    }

    func evaluate(datasetAt path: URL, output: URL) async throws -> Int {
        let clips = try JSONDecoder().decode(Dataset.self, from: Data(contentsOf: path)).validated()
        return try await evaluate(clips, datasetManifest: path, output: output)
    }

    private func evaluate(_ frozen: [Clip], asrReport: URL? = nil, datasetManifest: URL? = nil,
                          output: URL) async throws -> Int {
        let filename = "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
        var report = Report(formatVersion: 1, asrReport: asrReport?.path, asrModel: asrReport.map { _ in .qwen },
                            datasetManifest: datasetManifest?.path, model: filename,
                            mode: "interactive", expectedClips: frozen.count, comparisonDeadlineSeconds: 3)
        try saveReport(report, at: output)
        let corrector = QwenTextCorrector(configuration: .init(
            executable: resources.appendingPathComponent("llama-completion"),
            model: resources.appendingPathComponent(filename),
            useGPU: true,
            mode: .interactive
        ))
        for (index, clip) in frozen.enumerated() {
            report.observations.append(try await observe(clip, corrector: corrector))
            try saveReport(report, at: output)
            if (index + 1).isMultiple(of: 5) || index + 1 == frozen.count {
                print("Correction \(index + 1)/\(frozen.count)")
            }
        }
        report.complete = true
        report.summaries = [AccuracyGroup.zh, .en, .mixed].compactMap { group in
            let rows = report.observations.filter { $0.group == group }
            return rows.isEmpty ? nil : Summary(group: group, observations: rows, deadline: report.comparisonDeadlineSeconds)
        }
        try saveReport(report, at: output)
        return report.observations.filter { $0.failure != nil }.count
    }

    private func observe(_ clip: Clip, corrector: any TextCorrecting) async throws -> Observation {
        guard let original = clip.transcript else {
            return Observation(id: clip.id, group: clip.group, status: .unavailableASR,
                               original: nil, corrected: nil, score: nil, seconds: nil,
                               numbersChanged: nil, failure: clip.failure ?? "missingTranscript")
        }
        if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let score = CorrectionAccuracy.score(reference: clip.reference, original: original,
                                                 corrected: original, group: clip.group)
            return Observation(id: clip.id, group: clip.group, status: .emptyASR,
                               original: original, corrected: original, score: score, seconds: nil,
                               numbersChanged: false, failure: nil)
        }
        let start = ContinuousClock.now
        do {
            let correction = try await corrector.correct(CorrectionRequest(text: original))
            let seconds = elapsedSeconds(since: start)
            let score = CorrectionAccuracy.score(reference: clip.reference, original: original,
                                                 corrected: correction.text, group: clip.group)
            return Observation(id: clip.id, group: clip.group, status: .completed,
                               original: original, corrected: correction.text, score: score, seconds: seconds,
                               numbersChanged: correction.numbersChanged, failure: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Observation(id: clip.id, group: clip.group, status: .failed,
                               original: original, corrected: nil, score: nil, seconds: elapsedSeconds(since: start),
                               numbersChanged: nil, failure: failureName(error))
        }
    }
}
