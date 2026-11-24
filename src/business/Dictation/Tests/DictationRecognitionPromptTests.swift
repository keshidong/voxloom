import Testing
@testable import SpeechInput

struct DictationRecognitionPromptTests {
    @Test func keepsRecentTechnicalTermsWhenMessagesContainLotsOfOrdinaryWords() {
        let newest = "NightlyCompiler is ready and the team should see when the next release ships after lunch before we meet with the other team later today"
        let terms = DictationRecognitionPrompt.terms(
            draft: "让我们检查 Voxloom。", recentMessages: ["PreviousIndexer", newest]
        )
        #expect(terms.contains("Voxloom"))
        #expect(terms.contains("NightlyCompiler"))
        #expect(terms.firstIndex(of: "NightlyCompiler").map { $0 < 8 } == true)
        #expect(terms.count <= 16)
    }
}
