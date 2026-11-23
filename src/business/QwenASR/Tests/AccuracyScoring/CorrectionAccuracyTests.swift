import Testing

struct CorrectionAccuracyTests {
    @Test func correctionMeasuresBothTextsAgainstTheSameReference() {
        let reference = "请 merge 两个 PR。"
        let original = "请 merge 两个 MR。"

        let improved = CorrectionAccuracy.score(reference: reference, original: original,
                                                corrected: "請 merge 兩個 ＰＲ！", group: .mixed)
        #expect(improved.before == AccuracyScore(referenceUnits: 5, edits: 1))
        #expect(improved.after == AccuracyScore(referenceUnits: 5, edits: 0))
        #expect(improved.comparison == .improved)

        let unchanged = CorrectionAccuracy.score(reference: reference, original: original,
                                                 corrected: "请 merge 两个 MR", group: .mixed)
        #expect(unchanged.before == unchanged.after)
        #expect(unchanged.comparison == .unchanged)

        let worse = CorrectionAccuracy.score(reference: reference, original: original,
                                             corrected: "merge 两个 MR", group: .mixed)
        #expect(worse.before == AccuracyScore(referenceUnits: 5, edits: 1))
        #expect(worse.after == AccuracyScore(referenceUnits: 5, edits: 2))
        #expect(worse.comparison == .worse)
    }
}
