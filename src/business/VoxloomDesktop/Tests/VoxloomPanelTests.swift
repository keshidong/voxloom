import AppKit
import Carbon
import SpeechFoundation
import SpeechInput
import Testing
@testable import VoxloomDesktop

@MainActor struct VoxloomPanelTests {
    @Test func theNativeEditorReportsTheActualInsertionRangeForRepeatedText() async throws {
        _ = NSApplication.shared
        let overlay = VoxloomOverlay()
        let capture = FlowCapture()
        let flow = VoxloomFlow(settings: .init(), capture: { capture },
            recognizer: { _ in WaitingRecognizer(finalization: AsyncStream { $0.finish() }) }, corrector: { _ in nil },
            insertion: .init(foregroundTarget: { nil }, canPost: { false }, paste: { _, _ in false }))
        flow.handle(.start)
        try await reaches { capture.receive != nil }
        flow.edit("甲公圆。", basedOn: "")
        overlay.render(flow, availability: .init())
        var reported: NSRange?
        overlay.onEdit = { text, visible, range in
            reported = range
            flow.edit(text, basedOn: visible, replacedRange: range)
        }

        let insertion = NSRange(location: 0, length: 0)
        try #require(overlay.editor.shouldChangeText(in: insertion, replacementString: "甲公圆。"))
        overlay.editor.textStorage?.replaceCharacters(in: insertion, with: "甲公圆。")
        overlay.editor.didChangeText()
        #expect(flow.state?.text == "甲公圆。甲公圆。")
        #expect(reported == insertion)
        overlay.render(flow, availability: .init())
        overlay.editor.setSelectedRange(NSRange(location: 4, length: 1))
        flow.edit("第一段甲公圆。甲公圆。", basedOn: "甲公圆。甲公圆。", replacedRange: insertion)
        overlay.render(flow, availability: .init())
        #expect(overlay.editor.selectedRange() == NSRange(location: 7, length: 1))
        await flow.shutdown()
    }

    @Test func overlayFloatsAcrossSpacesAndCanFocusItsEditor() {
        _ = NSApplication.shared
        let panel = VoxloomPanel()
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.becomesKeyOnlyIfNeeded)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }

    @Test func theVoiceBarRevealsAndCollapsesTheDraftOnDemand() throws {
        _ = NSApplication.shared
        let overlay = VoxloomOverlay()
        let collapsed = overlay.panel.frame
        #expect(collapsed.height <= 64)
        #expect(overlay.editor.isHiddenOrHasHiddenAncestor)

        let content = try #require(overlay.panel.contentView)
        let draft = try #require(findButton(in: content, labeled: "草稿"))
        draft.performClick(nil)
        #expect(overlay.panel.frame.height >= 200)
        #expect(overlay.panel.frame.minY == collapsed.minY)
        #expect(overlay.panel.frame.midX == collapsed.midX)
        #expect(!overlay.editor.isHiddenOrHasHiddenAncestor)

        try #require(findButton(in: content, labeled: "收起草稿")).performClick(nil)
        #expect(overlay.panel.frame == collapsed)
        #expect(overlay.editor.isHiddenOrHasHiddenAncestor)
    }

    @Test func showingALongDraftDoesNotMoveTheVoiceBarInwardFromTheScreenEdge() async throws {
        _ = NSApplication.shared
        let overlay = VoxloomOverlay()
        let content = try #require(overlay.panel.contentView)
        let bounds = try #require(overlay.panel.screen?.visibleFrame)
        overlay.panel.setFrameOrigin(NSPoint(x: bounds.minX + 4, y: bounds.minY + 22))
        let restingFrame = overlay.panel.frame
        let flow = VoxloomFlow(settings: .init(), capture: { FlowCapture() },
            recognizer: { _ in WaitingRecognizer(finalization: AsyncStream { $0.finish() }) }, corrector: { _ in nil },
            insertion: .init(foregroundTarget: { nil }, canPost: { false }, paste: { _, _ in false }))
        defer { overlay.panel.orderOut(nil) }

        flow.handle(.start)
        try await reaches { flow.state?.live.phase == .recording }
        let longText = String(repeating: "这里是持续转写的中文。Long unbroken words and notes. ", count: 200)
        flow.edit(longText, basedOn: "")
        overlay.render(flow, availability: .init(globalShortcut: true, canInsert: true))
        content.layoutSubtreeIfNeeded()
        #expect(overlay.panel.frame.minX == restingFrame.minX)
        #expect(overlay.panel.frame.width == restingFrame.width)
        let field = try #require(livePreview(in: content))
        #expect(field.frame.width <= restingFrame.width)

        try #require(findButton(in: content, labeled: "草稿")).performClick(nil)
        content.layoutSubtreeIfNeeded()
        #expect(bounds.contains(overlay.panel.frame))
        #expect(overlay.editor.string == longText)
        try #require(findButton(in: content, labeled: "收起草稿")).performClick(nil)
        content.layoutSubtreeIfNeeded()
        #expect(overlay.panel.frame.minX == restingFrame.minX)
        #expect(overlay.panel.frame.width == restingFrame.width)
        await flow.shutdown()
    }

    @Test func enterSubmitsTheDraftAndShiftEnterKeepsEditing() throws {
        _ = NSApplication.shared
        let overlay = VoxloomOverlay()
        let content = try #require(overlay.panel.contentView)
        try #require(findButton(in: content, labeled: "草稿")).performClick(nil)
        let editor = overlay.editor
        editor.isEditable = true
        editor.string = "第一行"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        overlay.panel.makeFirstResponder(editor)
        let submission = DraftSubmission()
        overlay.insert.target = submission
        overlay.insert.action = #selector(DraftSubmission.submit)

        func pressReturn(_ modifiers: NSEvent.ModifierFlags = [], key: Int = kVK_Return) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: overlay.panel.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: UInt16(key)))
            editor.keyDown(with: event)
        }

        try pressReturn(.shift)
        #expect(editor.string == "第一行\n")
        #expect(submission.count == 0)
        try pressReturn()
        #expect(editor.string == "第一行\n")
        #expect(submission.count == 1)
        try pressReturn(.numericPad, key: kVK_ANSI_KeypadEnter)
        #expect(submission.count == 2)

        editor.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(editor.hasMarkedText())
        try pressReturn()
        #expect(submission.count == 2)
    }

    @Test func theVoiceBarShowsAudioLevelAndFinalizationWithoutOpeningTheDraft() async throws {
        _ = NSApplication.shared
        let overlay = VoxloomOverlay()
        let capture = FlowCapture()
        let finalization = AsyncStream<Void>.makeStream()
        defer { finalization.continuation.finish() }
        var canPost = false
        let flow = VoxloomFlow(settings: .init(), capture: { capture },
            recognizer: { _ in WaitingRecognizer(finalization: finalization.stream) },
            corrector: { _ in nil }, insertion: .init(foregroundTarget: { 101 }, canPost: { canPost }, paste: { _, _ in true }))
        let content = try #require(overlay.panel.contentView)

        flow.handle(.start)
        try await reaches { flow.state?.live.phase == .recording }
        overlay.render(flow, availability: .init(canInsert: canPost))
        #expect(overlay.status.stringValue.hasPrefix("正在录音"))
        #expect(findVisible(NSLevelIndicator.self, in: content) != nil)
        #expect(livePreview(in: content) == nil)
        let emptyBar = overlay.panel.frame
        flow.edit("已经说出的第一句", basedOn: "")
        overlay.render(flow, availability: .init(canInsert: canPost))
        #expect(livePreview(in: content)?.stringValue == "已经说出的第一句")
        #expect(overlay.panel.frame.height > emptyBar.height)
        #expect(overlay.panel.frame.minY == emptyBar.minY)
        flow.edit("文字继续更新", basedOn: "已经说出的第一句")
        overlay.render(flow, availability: .init(canInsert: canPost))
        #expect(livePreview(in: content)?.stringValue == "文字继续更新")
        capture.receive?([3000, -3000])
        try await reaches { flow.state?.live.samples.count == 2 }

        flow.handle(.stop)
        try await reaches { flow.state?.live.phase == .finishing }
        overlay.render(flow, availability: .init(canInsert: canPost))
        #expect(overlay.status.stringValue == "正在整理最后一段")
        #expect(findVisible(NSProgressIndicator.self, in: content) != nil)
        #expect(findVisible(NSLevelIndicator.self, in: content) == nil)
        #expect(overlay.editor.isHiddenOrHasHiddenAncestor)

        finalization.continuation.finish()
        try await reaches { flow.state?.live.phase == .idle && flow.canInsert }
        overlay.render(flow, availability: .init(canInsert: canPost))
        #expect(overlay.status.stringValue == InsertionError.permission.localizedDescription)
        #expect(findVisible(NSProgressIndicator.self, in: content) == nil)
        #expect(overlay.editor.isHiddenOrHasHiddenAncestor)
        #expect(livePreview(in: content)?.stringValue == flow.state?.text)
        try #require(findButton(in: content, labeled: "草稿")).performClick(nil)
        #expect(livePreview(in: content) == nil)
        try #require(findButton(in: content, labeled: "收起草稿")).performClick(nil)
        #expect(livePreview(in: content)?.stringValue == flow.state?.text)
        canPost = true
        flow.handle(.confirm)
        overlay.render(flow, availability: .init(canInsert: canPost))
        #expect(livePreview(in: content) == nil)
        #expect(overlay.panel.frame == emptyBar)
        flow.clearOrCancel()
        overlay.render(flow, availability: .init(canInsert: canPost))
        #expect(livePreview(in: content) == nil)
        #expect(overlay.panel.frame == emptyBar)
        await flow.shutdown()
    }

    private func reaches(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() && ContinuousClock.now < end { await Task.yield() }
        try #require(predicate())
    }

    private func findVisible<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
        if let match = view as? View, !match.isHiddenOrHasHiddenAncestor { return match }
        return view.subviews.lazy.compactMap { findVisible(type, in: $0) }.first
    }

    private func findButton(in view: NSView, labeled label: String) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityLabel() == label { return button }
        return view.subviews.lazy.compactMap { findButton(in: $0, labeled: label) }.first
    }

    private func livePreview(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.accessibilityLabel() == "实时草稿",
           !field.isHiddenOrHasHiddenAncestor { return field }
        return view.subviews.lazy.compactMap { livePreview(in: $0) }.first
    }
}

@MainActor private final class DraftSubmission: NSObject {
    private(set) var count = 0

    @objc func submit() { count += 1 }
}

private struct WaitingRecognizer: SpeechRecognizer {
    let finalization: AsyncStream<Void>

    func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
        for await _ in finalization { break }
        return .init(text: "测试草稿")
    }
}
