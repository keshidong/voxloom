import ApplicationServices
import Foundation
import Testing
@testable import VoxloomDesktop

struct SystemTextInputTests {
    @Test func allowsOnlyTerminalsFocusedTextAreaToUseReadOnlyContext() {
        #expect(SystemTextInput.contextMode(bundleIdentifier: "com.apple.Terminal", role: kAXTextAreaRole,
                                            isWritable: false) == .terminal)
        #expect(SystemTextInput.contextMode(bundleIdentifier: "com.apple.Terminal", role: kAXTextFieldRole,
                                            isWritable: false) == nil)
        #expect(SystemTextInput.contextMode(bundleIdentifier: "example.Other", role: kAXTextAreaRole,
                                            isWritable: false) == nil)
        #expect(SystemTextInput.contextMode(bundleIdentifier: "example.Other", role: kAXTextFieldRole,
                                            isWritable: true) == .editableField)
    }

    @Test func terminalUsesTheEndOfTheVisibleRangeWhenItReportsNoCaret() {
        var requested: NSRange?
        let result = SystemTextInput.terminalExcerpt(at: nil, visible: NSRange(location: 9_000, length: 500),
            length: 10_000, readRange: { requested = $0; return "Voxloom terminal sample" })
        #expect(requested == NSRange(location: 9_000, length: 500))
        #expect(result == "Voxloom terminal sample")
    }

    @Test func terminalKeepsTheRangeNearTheCaretInsideTheVisibleText() {
        var requested: NSRange?
        let result = SystemTextInput.terminalExcerpt(at: NSRange(location: 9_030, length: 0),
            visible: NSRange(location: 9_000, length: 60), length: 10_000,
            readRange: { requested = $0; return "Voxloom terminal sample" })
        #expect(requested == NSRange(location: 9_000, length: 60))
        #expect(result == "Voxloom terminal sample")
    }

    @Test func terminalFallsBackToABoundedTailWithOnlyTheCharacterCount() {
        var requested: NSRange?
        let result = SystemTextInput.terminalExcerpt(at: nil, visible: nil, length: 10_000,
            readRange: { requested = $0; return "Voxloom terminal sample" })
        #expect(requested == NSRange(location: 5_904, length: 4_096))
        #expect(result == "Voxloom terminal sample")
    }

    @Test func terminalSkipsTheReadWhenThereIsNoValidRange() {
        let result = SystemTextInput.terminalExcerpt(at: nil, visible: nil, length: nil,
            readRange: { _ in
                Issue.record("A terminal without a usable range must not be queried for text")
                return nil
            })
        #expect(result.isEmpty)
    }

    @Test func terminalCollectsTextAboveAndBelowTheInputLineDespiteWidePadding() {
        let padding = String(repeating: " ", count: 300)
        let screen = [
            "正在比较 Qwen3ASR", "\(padding)│", "› Type a request",
            "\(padding)│", "本轮讨论 HotwordBias"
        ].map { $0 + padding }.joined(separator: "\n") as NSString
        let caret = screen.range(of: "›").location + 2
        let result = SystemTextInput.terminalExcerpt(at: NSRange(location: caret, length: 0),
            visible: NSRange(location: 0, length: screen.length), length: screen.length,
            readRange: { screen.substring(with: $0) })

        #expect(result == "正在比较 Qwen3ASR\n本轮讨论 HotwordBias")
    }

    @Test func terminalWithoutACaretCollectsMultipleNonemptyRows() {
        let padding = String(repeating: " ", count: 300)
        let screen = ["Qwen3ASR uses context", "Whisper uses a prompt", "│"].map { $0 + padding }
            .joined(separator: "\n") as NSString
        let result = SystemTextInput.terminalExcerpt(at: nil,
            visible: NSRange(location: 0, length: screen.length), length: screen.length,
            readRange: { screen.substring(with: $0) })

        #expect(result == "Qwen3ASR uses context\nWhisper uses a prompt")
    }

    @Test func terminalKeepsBothSidesWithinTheFinalContextLimit() {
        let upper = "上文 Qwen3ASR " + String(repeating: "模型", count: 150)
        let lower = "下文 Whisper " + String(repeating: "识别", count: 150)
        let screen = [upper, "› Type a request", lower].joined(separator: "\n") as NSString
        let result = SystemTextInput.terminalExcerpt(at: NSRange(location: screen.range(of: "›").location + 2, length: 0),
            visible: NSRange(location: 0, length: screen.length), length: screen.length,
            readRange: { screen.substring(with: $0) })

        #expect(result.contains("上文 Qwen3ASR"))
        #expect(result.contains("下文 Whisper"))
        #expect(!result.contains("Type a request"))
        #expect(result.utf16.count <= 240)
    }

    @Test func aRebuiltComposerRequiresTheSameIdentifierDocumentAndRole() {
        let document = AXUIElementCreateApplication(101)
        let otherDocument = AXUIElementCreateApplication(102)
        let anchor = SystemTextInput.FieldIdentity(identifier: "composer", scope: document, role: kAXTextAreaRole)
        let same = SystemTextInput.FieldIdentity(identifier: "composer", scope: document, role: kAXTextAreaRole)
        let otherTab = SystemTextInput.FieldIdentity(identifier: "composer", scope: otherDocument, role: kAXTextAreaRole)
        let search = SystemTextInput.FieldIdentity(identifier: "search", scope: document, role: kAXTextAreaRole)
        let differentRole = SystemTextInput.FieldIdentity(identifier: "composer", scope: document, role: kAXTextFieldRole)
        #expect(anchor.matches(same))
        #expect(!anchor.matches(otherTab))
        #expect(!anchor.matches(search))
        #expect(!anchor.matches(differentRole))
        #expect(!anchor.matches(nil))
    }
    @Test func readsOnlyABoundedRangeNearTheCaretInALongInput() {
        var requested: NSRange?
        let result = SystemTextInput.excerpt(at: NSRange(location: 5_000, length: 0), length: 10_000,
            readRange: { requested = $0; return "附近文字" },
            readShortValue: { Issue.record("A long field must not be fetched in full"); return nil })
        #expect(requested == NSRange(location: 4_840, length: 240))
        #expect(result == "附近文字")
    }
}
