import Testing
@testable import SpeechInput

struct MandarinContextTermsTests {
    @Test func findsAContextTermWhenTheDraftSeparatesItsCharactersAndMishearsAnInitial() {
        let result = MandarinContextTerms.annotate("选选制都正确。", context: "录音 选字 正确")
        #expect(result.matches == ["选制": ["选字"]])
        #expect(result.transcript == "选〔选字／选制〕都正确。")
    }

    @Test func rejoinsAdjacentChineseCharactersFromTheWindowContext() {
        let result = MandarinContextTerms.annotate("选选制都正确。", context: "录音 选 字 都 正确")
        #expect(result.matches == ["选制": ["选字"]])
        #expect(result.transcript == "选〔选字／选制〕都正确。")
    }

    @Test func keepsNumbersOutOfTheNearSoundCandidates() {
        let result = MandarinContextTerms.annotate("还有四十条。", context: "事实 说明")
        #expect(result.matches.isEmpty)
        #expect(result.transcript == "还有四十条。")
    }

    @Test func leavesDifferentSequencesUnmarkedWhenTwoInitialsDiffer() {
        let result = MandarinContextTerms.annotate("我正在思索。", context: "诗说 说明")
        #expect(result.matches.isEmpty)
        #expect(result.transcript == "我正在思索。")
    }
}
