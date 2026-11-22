import Foundation
import Testing
@testable import VoxloomDesktop

@MainActor struct CaretInsertionTests {
    @Test func sendsPasteToTheForegroundAppAndRefusesAStaleTarget() throws {
        var foreground: Int32? = 101
        var allowed = true
        var delivered: [(String, Int32)] = []
        let insertion = CaretInsertion(foregroundTarget: { foreground }, canPost: { allowed },
            paste: { delivered.append(($0, $1)); return true })
        let target = try insertion.destination()
        try insertion.insert("语音草稿", at: target)
        #expect(delivered.map(\.0) == ["语音草稿"])
        #expect(delivered.map(\.1) == [101])

        foreground = 102
        #expect(throws: InsertionError.targetChanged) { try insertion.insert("保留这段内容", at: target) }
        allowed = false
        #expect(throws: InsertionError.permission) { try insertion.destination() }
        #expect(throws: InsertionError.permission) { try insertion.insert("权限已撤销", at: target) }
        allowed = true
        foreground = nil
        #expect(throws: InsertionError.noTarget) { try insertion.destination() }
        #expect(delivered.count == 1)
    }

    @Test func pasteFailureHasAnActionableMessageAndLeavesTheCallerInControl() {
        let insertion = CaretInsertion(foregroundTarget: { 7 }, canPost: { true }, paste: { _, _ in false })
        #expect(throws: InsertionError.unavailable) { try insertion.insert("继续编辑", at: insertion.destination()) }
        for error in [InsertionError.noTarget, .noFocusedInput, .permission, .targetChanged, .unavailable] {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test func automaticInsertionDoesNotPasteIntoADifferentFieldInTheSameApp() throws {
        var focus: String? = "第一处光标"
        var pasted: [String] = []
        let insertion = CaretInsertion(foregroundTarget: { 101 }, canPost: { true },
            paste: { text, _ in pasted.append(text); return true }, captureFocus: { _ in
                guard let snapshot = focus else { return nil }
                return { focus == snapshot }
            })
        let target = try insertion.destination(requireFocusedInput: true)
        focus = "第二处光标"
        #expect(throws: InsertionError.targetChanged) { try insertion.insert("保留这段", at: target) }
        #expect(pasted.isEmpty)
        focus = nil
        #expect(throws: InsertionError.noFocusedInput) { try insertion.destination(requireFocusedInput: true) }
        try insertion.insert("手动重试", at: insertion.destination())
        #expect(pasted == ["手动重试"])
    }

    @Test func sendingAMessageCanResetTheCaretInTheSameFieldBeforeTheNextPaste() throws {
        var selection: NSRange? = NSRange(location: 12, length: 0)
        var pasted: [String] = []
        let insertion = CaretInsertion(foregroundTarget: { 101 }, canPost: { true },
            paste: { text, _ in pasted.append(text); return true }, captureFocus: { _ in
                let original = selection
                return { SystemTextInput.acceptsSelection(selection, original: original) }
            })
        let target = try insertion.destination(requireFocusedInput: true)
        selection = NSRange(location: 0, length: 0)
        try insertion.insert("接着输入第二句", at: target)
        selection = NSRange(location: 0, length: 3)
        #expect(throws: InsertionError.targetChanged) { try insertion.insert("保留草稿", at: target) }
        #expect(pasted == ["接着输入第二句"])
    }
}
