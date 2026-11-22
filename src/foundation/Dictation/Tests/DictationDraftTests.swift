import Foundation
import SpeechFoundation
import Testing

struct DictationDraftTests {
    @Test func selectionMovesPastSeparateEditsUsingUTF16Offsets() {
        let selection = NSRange(location: 5, length: 1)
        let updated = DraftSelection.rebase(selection, from: "😀甲中乙末", to: "😀甲组中乙班末")
        #expect(updated == NSRange(location: 7, length: 1))
    }

    @Test func correctionFollowsItsOriginalOccurrencePastAnIdenticalInsertion() {
        var draft = DictationDraft()
        draft.recognize("甲公圆，乙公圆。")
        let snapshot = draft.correctionSnapshot
        draft.edit("甲公圆，甲公圆，乙公圆。", basedOn: draft.text, replacedRange: NSRange(location: 0, length: 0))
        draft.correct(.init(text: "甲公园，乙公圆。", original: snapshot.text), basedOn: snapshot)
        #expect(draft.text == "甲公圆，甲公园，乙公圆。")
    }

    @Test func aDeletedAndRetypedOccurrenceTakesPrecedenceEvenWithTheSameText() {
        var draft = DictationDraft()
        draft.recognize("公圆，公圆。")
        let snapshot = draft.correctionSnapshot
        draft.edit("公圆。", basedOn: draft.text, replacedRange: NSRange(location: 0, length: 3))
        draft.edit("公圆，公圆。", basedOn: draft.text, replacedRange: NSRange(location: 0, length: 0))
        draft.correct(.init(text: "公园，公园。", original: snapshot.text), basedOn: snapshot)
        #expect(draft.text == "公圆，公园。")
    }

    @Test func onlyTheEditableCurrentSectionIsSentToCorrection() {
        var draft = DictationDraft(existingText: "之前的文本。")
        draft.recognize("去公圆。")
        draft.edit("之前的文字已经确认。\n下午去公圆。", basedOn: draft.text)
        let snapshot = draft.correctionSnapshot
        #expect(snapshot.text == "下午去公圆。")
        draft.correct(.init(text: "下午去公园。", original: snapshot.text), basedOn: snapshot)
        #expect(draft.text == "之前的文字已经确认。\n下午去公园。")
    }

    @Test func aStructuredCorrectionKeepsItsSpecifiedRangeWhenTheResultCouldHaveMultipleDiffs() throws {
        var draft = DictationDraft()
        draft.recognize("abcabc")
        let snapshot = draft.correctionSnapshot
        draft.edit("abcabXc", basedOn: draft.text, replacedRange: NSRange(location: 5, length: 0))
        let response = Data(#"{"edits":[{"from":"abca","to":"a"}]}"#.utf8)
        let candidate = try CorrectionPrompt.decode(response, original: snapshot.text)
        #expect(candidate.text == "abc")
        draft.correct(candidate, basedOn: snapshot)
        #expect(draft.text == "abXc")
    }

    @Test func aNewRecordingAppendsToTheExistingTextAndKeepsManualEdits() {
        var draft = DictationDraft(existingText: "第一段已经校对。")
        #expect(draft.text == "第一段已经校对。")
        draft.recognize("下午去公圆。")
        #expect(draft.text == "第一段已经校对。\n下午去公圆。")
        draft.edit("第一段手动改过。\n下午去公圆。", basedOn: draft.text)
        let original = "下午去公圆，顺便买书。"
        draft.recognize(original)
        draft.correct(.init(text: "下午去公园，顺便买书。", original: original))
        #expect(draft.text == "第一段手动改过。\n下午去公园，顺便买书。")

        var endingWithNewline = DictationDraft(existingText: "已换行的草稿\n")
        endingWithNewline.recognize("第二段。")
        #expect(endingWithNewline.text == "已换行的草稿\n第二段。")
    }

    @Test func laterRecognitionKeepsKeyboardEditsAndAddsNewSpeech() {
        var draft = DictationDraft()
        draft.recognize("今天去公圆")
        draft.edit("今天去图书馆", basedOn: draft.text)
        draft.recognize("今天去公园，顺便买书")
        #expect(draft.text == "今天去图书馆，顺便买书")
    }

    @Test func inFlightCorrectionKeepsTypingAndNewSpeechWhileFixingUntouchedWords() {
        var draft = DictationDraft()
        let original = "资廖送去公圆。"
        draft.recognize(original)
        let snapshot = draft.correctionSnapshot
        draft.edit("资廖送去图书馆。", basedOn: draft.text)
        draft.recognize("资廖送去公圆。下午送达。")
        draft.correct(.init(text: "资料送去公园。", original: original), basedOn: snapshot)
        #expect(draft.text == "资料送去图书馆。下午送达。")
    }
}
