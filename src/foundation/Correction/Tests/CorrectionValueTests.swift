import Foundation
import SpeechFoundation
import Testing

struct CorrectionValueTests {
    @Test func deliveryHintsDoNotBiasDictationFromAnUnrelatedTopic() throws {
        let unrelated = try CorrectionPrompt.build(.init(text: "请检查模块接口", vocabulary: "RxSwift"))
        #expect(!unrelated.contains("特别注意配送物品场景"))
        let delivery = try CorrectionPrompt.build(.init(text: "这个包裹需要配送"))
        #expect(delivery.contains("特别注意配送物品场景"))
    }
    @Test func contextualModelEditsPreferTheCompletePhraseOverItsContainedWord() throws {
        let data = Data(#"{"edits":[{"from":"充直","to":"充值"},{"from":"充直额图","to":"充值额度"}]}"#.utf8)
        let result = try CorrectionPrompt.decodeWithReview(data, original: "充直额图，单次充直20。", preferEnclosingEdits: true)
        #expect(result.candidate.text == "充值额度，单次充值20。")
    }
    @Test func aReviewIgnoresAlreadyAppliedEditsAndAppliesOnlyRemainingLiteralMatches() throws {
        let data = Data(#"{"edits":[{"from":"第一箱把我搬上楼","to":"第一箱把纸箱搬上楼"},{"from":"把我搬上楼","to":"把纸箱搬上楼"}]}"#.utf8)
        let original = "第一箱把纸箱搬上楼，第二箱把我搬上楼。"
        #expect(throws: CorrectionError.invalidResult) { try CorrectionPrompt.decode(data, original: original) }
        let reviewed = try CorrectionPrompt.decodeWithReview(data, original: original, allowMissingSources: true)
        #expect(reviewed.candidate.text == "第一箱把纸箱搬上楼，第二箱把纸箱搬上楼。")
    }
    @Test func verifiedEditsFixEveryMatchingPhraseWithoutCascadingOrOverlapping() throws {
        let result = try CorrectionPrompt.decode(Data(#"{"analysis":"动作对象不一致","edits":[{"from":"搬我上楼","to":"搬纸箱上楼"}]}"#.utf8),
            original: "我请师傅搬我上楼，随后他说还得搬我上楼。")
        #expect(result.text == "我请师傅搬纸箱上楼，随后他说还得搬纸箱上楼。")
        let repeated = try CorrectionPrompt.decode(Data(#"{"edits":[{"from":"搬我上楼","to":"搬纸箱上楼"},{"from":"搬我上楼","to":"搬纸箱上楼"}]}"#.utf8), original: "搬我上楼，再搬我上楼。")
        #expect(repeated.text == "搬纸箱上楼，再搬纸箱上楼。")
        let parallel = try CorrectionPrompt.decode(Data(#"{"edits":[{"from":"甲","to":"乙"},{"from":"乙","to":"丙"}]}"#.utf8), original: "甲乙")
        #expect(parallel.text == "乙丙")
        #expect(try CorrectionPrompt.decode(Data(#"{"edits":[]}"#.utf8), original: "没有问题的原文").text == "没有问题的原文")
        for invalid in [#"{"edits":[{"from":"不存在","to":"替换"}]}"#,
                        #"{"edits":[{"from":"我","to":"货"}]}"#,
                        #"{"edits":[{"from":"甲乙","to":"x"},{"from":"乙丙","to":"y"}]}"#,
                        #"{"edits":[{"from":"","to":"x"}]}"#,
                        #"{"edits":[{"from":"甲","to":"x"},{"from":"甲","to":"y"}]}"#] {
            #expect(throws: CorrectionError.invalidResult) { try CorrectionPrompt.decode(Data(invalid.utf8), original: "甲乙丙我我") }
        }
    }
    @Test func failuresExplainTheRecoveryActionInUserLanguage() {
        let cases: [(CorrectionError, String)] = [(.invalidInput, "文字"), (.invalidConfiguration, "配置"),
            (.busy, "上一轮"), (.engineUnavailable, "引擎"), (.modelUnavailable, "模型"),
            (.fileAccess, "文件"), (.invalidResult, "完整"), (.timedOut, "超时"), (.engineFailed(7), "7")]
        for (error, hint) in cases { #expect(error.localizedDescription.contains(hint)) }
    }
    @Test func generationBudgetPreservesRoomForTheWholeTranscriptAndSemanticChecks() throws {
        for text in ["请帮我检查这份清单。", String(repeating: "这是需要完整校对的内容。", count: 70)] {
            let request = CorrectionRequest(text: text)
            let plan = try CorrectionPrompt.plan(request)
            #expect(try plan.prompt == CorrectionPrompt.build(request))
            #expect(plan.outputTokens >= 768)
            #expect(plan.outputTokens > text.utf8.count)
            #expect(plan.contextTokens > plan.outputTokens)
            #expect(plan.contextTokens <= 8192)
        }
        let prompt = try CorrectionPrompt.build(.init(text: "明天开会", vocabulary: "项目"))
        #expect(prompt.contains(#"{"text":"明天开会","vocabulary":"项目"}"#))
        #expect(try CorrectionPrompt.build(.init(text: "明天开会", vocabulary: "项目")) == prompt)
    }
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
