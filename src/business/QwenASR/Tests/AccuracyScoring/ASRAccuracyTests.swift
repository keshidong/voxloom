import Testing

struct ASRAccuracyTests {
    @Test func mandarinUsesCharacterEditsAfterOrthographicNormalization() {
        let score = ASRAccuracy.score(reference: "請打印３份，導出 ＰＤＦ。",
                                      hypothesis: "请打硬3份导出 pdf", group: .zh)
        #expect(score == AccuracyScore(referenceUnits: 10, edits: 1))
    }

    @Test func englishUsesWordsAndPreservesContractionsAndDecimalValues() {
        let score = ASRAccuracy.score(reference: "ＦＩＬＬ 3.5 liters, don't spill.",
                                      hypothesis: "Fill 35 litres, don’t spill now", group: .en)
        #expect(score == AccuracyScore(referenceUnits: 5, edits: 3))
    }

    @Test func mixedSpeechCountsHanCharactersAndEnglishWordsEvenWithoutSpacesBetweenScripts() {
        let score = ASRAccuracy.score(reference: "請 merge 兩個PR 3.5。",
                                      hypothesis: "请 merge 两个 MR 3.5 now", group: .mixed)
        #expect(score == AccuracyScore(referenceUnits: 6, edits: 2))
    }
}
