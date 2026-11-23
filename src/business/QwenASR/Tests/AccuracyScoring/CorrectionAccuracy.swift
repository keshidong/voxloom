enum CorrectionComparison: String, Codable, Sendable { case improved, unchanged, worse }

struct CorrectionAccuracyScore: Codable, Equatable, Sendable {
    let before: AccuracyScore
    let after: AccuracyScore
    let comparison: CorrectionComparison
}

enum CorrectionAccuracy {
    /// Scores the fixed ASR input and the correction against one reference with one tokenizer.
    static func score(reference: String, original: String, corrected: String,
                      group: AccuracyGroup) -> CorrectionAccuracyScore {
        let before = ASRAccuracy.score(reference: reference, hypothesis: original, group: group)
        let after = ASRAccuracy.score(reference: reference, hypothesis: corrected, group: group)
        let comparison: CorrectionComparison
        if after.edits < before.edits {
            comparison = .improved
        } else if after.edits > before.edits {
            comparison = .worse
        } else {
            comparison = .unchanged
        }
        return CorrectionAccuracyScore(before: before, after: after, comparison: comparison)
    }
}
