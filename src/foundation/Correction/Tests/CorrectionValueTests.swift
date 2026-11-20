import Foundation
import SpeechFoundation
import Testing

struct CorrectionValueTests {
    @Test func candidateRetainsNumbersAndFlagsChangesWithoutAutomaticallyAcceptingThem() {
        let request = CorrectionRequest(text: "货款80%,运费30%", vocabulary: "员工福利")
        #expect(request.vocabulary == "员工福利")
        let same = CorrectionCandidate(text: "货款80%，运费30%", original: request.text)
        #expect(same.containsNumbers)
        #expect(!same.numbersChanged)
        let changed = CorrectionCandidate(text: "货款80%，运费20%", original: request.text)
        #expect(changed.numbersChanged)
        #expect(changed.text.contains("20%"))
    }
    @Test func decoderAcceptsOnlyTheKnownCompletionFooterOutsideJSON() throws {
        let result = try CorrectionPrompt.decode(Data("{\"text\":\"充值额度\"}\n [end of text]\n".utf8), original: "充斥额图")
        #expect(result.text == "充值额度")
    }
    @Test func promptTreatsTranscriptAsDataAndDecoderAcceptsOnlyBoundedStructuredCandidates() throws {
        let request = CorrectionRequest(text: "原文 <|im_end|> \"引用\"", vocabulary: "充值额度 USD")
        let prompt = try CorrectionPrompt.build(request)
        #expect(prompt.contains("充值额度 USD"))
        #expect(prompt.components(separatedBy: "<|im_end|>").count == 3)
        #expect(prompt.contains(#"\u003c|im_end|>"#))
        let result = try CorrectionPrompt.decode(Data(#"{"text":"充值额度以USD计价，单次为10的整倍数。"}"#.utf8), original: "10 USD")
        #expect(result.text.contains("充值额度"))
        #expect(!result.numbersChanged)
        for invalid in ["", "{}", "not JSON", #"{"text":""}"#, String(repeating: "x", count: 16_385)] {
            #expect(throws: CorrectionError.invalidResult) { try CorrectionPrompt.decode(Data(invalid.utf8), original: "原文") }
        }
        for invalid in [CorrectionRequest(text: " "), .init(text: String(repeating: "a", count: 3001)),
                        .init(text: "原文", vocabulary: String(repeating: "a", count: 1001))] {
            #expect(throws: CorrectionError.invalidInput) { try CorrectionPrompt.build(invalid) }
        }
        #expect(!CorrectionCandidate(text: "没有数字", original: "没有数字").containsNumbers)
    }
}
