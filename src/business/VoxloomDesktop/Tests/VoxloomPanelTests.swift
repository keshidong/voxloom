import AppKit
import Carbon
import QuartzCore
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

    @Test func theBarFloatsAcrossSpacesAndOnlyTheDraftCanTakeKeyboardFocus() throws {
        _ = NSApplication.shared
        let overlay = VoxloomOverlay()
        let panel = overlay.panel
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.becomesKeyOnlyIfNeeded)
        #expect(!panel.hidesOnDeactivate)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        let editorWindow = try #require(overlay.editor.window)
        #expect(editorWindow.canBecomeKey)
        #expect(!editorWindow.canBecomeMain)
    }

    @Test func showingTheVoiceBarOnTheFocusedDisplayMovesItOnlyWhenNeeded() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let bounds = screen.visibleFrame
        let focusedArea = NSRect(x: bounds.midX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        let panel = VoxloomPanel()
        defer { panel.orderOut(nil) }
        panel.setFrameOrigin(NSPoint(x: bounds.minX + 16, y: bounds.minY + 22))

        panel.showOnActiveDisplay(in: focusedArea)
        #expect(focusedArea.contains(panel.frame))
        #expect(panel.frame.midX == focusedArea.midX)

        let dragged = NSPoint(x: focusedArea.minX + 8, y: focusedArea.minY + 68)
        panel.setFrameOrigin(dragged)
        panel.showOnActiveDisplay(in: focusedArea)
        #expect(panel.frame.origin == dragged)
    }

    @Test func theVoiceBarRevealsAndCollapsesTheDraftOnDemand() throws {
        _ = NSApplication.shared
        let overlay = VoxloomOverlay()
        overlay.panel.orderFrontRegardless()
        defer { overlay.panel.orderOut(nil) }
        let collapsed = overlay.panel.frame
        let barWindowNumber = overlay.panel.windowNumber
        #expect(collapsed.height <= 64)
        #expect(overlay.editor.isHiddenOrHasHiddenAncestor)

        let content = try #require(overlay.panel.contentView)
        let draft = try #require(findButton(in: content, labeled: "展开草稿"))
        let settings = try #require(findButton(in: content, labeled: "设置"))
        content.layoutSubtreeIfNeeded()
        let settingsFrame = overlay.panel.convertToScreen(settings.convert(settings.bounds, to: nil))
        #expect(draft.title == "展开")
        draft.performClick(nil)
        content.layoutSubtreeIfNeeded()
        let editorWindow = try #require(overlay.editor.window)
        #expect(editorWindow.isVisible)
        #expect(editorWindow.frame.minY == collapsed.maxY)
        #expect(editorWindow.frame.width == collapsed.width)
        #expect(overlay.panel.frame == collapsed)
        #expect(overlay.panel.windowNumber == barWindowNumber)
        #expect(overlay.panel.convertToScreen(settings.convert(settings.bounds, to: nil)) == settingsFrame)
        #expect(!overlay.editor.isHiddenOrHasHiddenAncestor)
        #expect(findButton(in: content, labeled: "试用示例") == nil)
        let editorContent = try #require(editorWindow.contentView)
        #expect(findButton(in: editorContent, labeled: "试用示例") == nil)
        #expect(!overlay.panel.hasShadow)
        #expect(!editorWindow.hasShadow)
        let barJoin = try pixel(in: content, x: 3, y: content.bounds.maxY - 3)
        let draftJoin = try pixel(in: editorContent, x: 3, y: 2)
        #expect(barJoin.alphaComponent > 0.99)
        #expect(draftJoin.alphaComponent > 0.99)
        let background = try pixel(in: content, x: 100, y: content.bounds.maxY - 5)
        #expect(try pixel(in: content, x: 100, y: content.bounds.maxY - 1) == background)
        #expect(try pixel(in: editorContent, x: 100, y: 0) == background)

        let collapse = try #require(findButton(in: content, labeled: "收起草稿"))
        #expect(collapse.title == "收起")
        collapse.performClick(nil)
        #expect(draft.title == "展开")
        #expect(overlay.panel.frame == collapsed)
        #expect(overlay.panel.windowNumber == barWindowNumber)
        #expect(overlay.panel.isVisible)
        #expect(overlay.panel.hasShadow)
        #expect(!editorWindow.isVisible)
        #expect(overlay.editor.isHiddenOrHasHiddenAncestor)
    }

    @Test func showingALongDraftDoesNotMoveTheVoiceBarInwardFromTheScreenEdge() async throws {
        _ = NSApplication.shared
        let overlay = VoxloomOverlay()
        let content = try #require(overlay.panel.contentView)
        let bounds = try #require(overlay.panel.screen?.visibleFrame)
        overlay.panel.setFrameOrigin(NSPoint(x: bounds.minX + 4, y: bounds.minY + 22))
        let restingFrame = overlay.panel.frame
        overlay.panel.orderFrontRegardless()
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
        let textContent = try #require(overlay.editor.window?.contentView)
        textContent.layoutSubtreeIfNeeded()
        let field = try #require(livePreview(in: textContent))
        #expect(field.frame.width <= restingFrame.width)

        try #require(findButton(in: content, labeled: "展开草稿")).performClick(nil)
        content.layoutSubtreeIfNeeded()
        let editorWindow = try #require(overlay.editor.window)
        #expect(bounds.contains(editorWindow.frame))
        #expect(overlay.panel.frame == restingFrame)
        #expect(overlay.editor.string == longText)
        try #require(findButton(in: content, labeled: "收起草稿")).performClick(nil)
        content.layoutSubtreeIfNeeded()
        #expect(overlay.panel.frame.minX == restingFrame.minX)
        #expect(overlay.panel.frame.width == restingFrame.width)
        await flow.shutdown()
    }

    @Test func theFocusedDraftCopiesItsSelectionAndPastesThroughNativeKeyEvents() throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let overlay = VoxloomOverlay(pasteboard: board)
        let editor = overlay.editor
        editor.isEditable = true
        editor.string = "示例草稿"
        editor.setSelectedRange(NSRange(location: 2, length: 2))
        overlay.showDraftEditor()
        defer { overlay.panel.orderOut(nil) }
        let window = try #require(editor.window)
        try #require(window.firstResponder === editor)
        var editedText: String?
        overlay.onEdit = { text, _, _ in editedText = text }

        func command(_ character: String, key: Int) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: UInt16(key)))
        }
        let copy = try command("c", key: kVK_ANSI_C)
        #expect(window.performKeyEquivalent(with: copy))
        #expect(board.string(forType: .string) == "草稿")

        board.clearContents()
        try #require(board.setString("新词", forType: .string))
        let paste = try command("v", key: kVK_ANSI_V)
        window.sendEvent(paste)
        #expect(editor.string == "示例新词")
        #expect(editedText == "示例新词")
        #expect(board.string(forType: .string) == "新词")

        editor.isEditable = false
        window.sendEvent(paste)
        #expect(editor.string == "示例新词")

        try #require(window.makeFirstResponder(nil))
        #expect(!window.performKeyEquivalent(with: copy))
        #expect(board.string(forType: .string) == "新词")
    }

    @Test func enterSubmitsTheDraftAndShiftEnterKeepsEditing() throws {
        _ = NSApplication.shared
        let overlay = VoxloomOverlay()
        overlay.show()
        defer { overlay.panel.orderOut(nil) }
        let content = try #require(overlay.panel.contentView)
        try #require(findButton(in: content, labeled: "展开草稿")).performClick(nil)
        let editor = overlay.editor
        editor.isEditable = true
        editor.string = "第一行"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        let editorWindow = try #require(editor.window)
        editorWindow.makeFirstResponder(editor)
        let submission = DraftSubmission()
        overlay.insert.target = submission
        overlay.insert.action = #selector(DraftSubmission.submit)

        func pressReturn(_ modifiers: NSEvent.ModifierFlags = [], key: Int = kVK_Return) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: editorWindow.windowNumber, context: nil,
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
        let textWindow = try #require(overlay.editor.window)
        let textContent = try #require(textWindow.contentView)
        overlay.show()
        defer { overlay.panel.orderOut(nil) }

        flow.handle(.start)
        try await reaches { flow.state?.live.phase == .recording }
        overlay.render(flow, availability: .init(canInsert: canPost))
        #expect(overlay.status.stringValue.hasPrefix("正在录音"))
        #expect(findVisible(NSLevelIndicator.self, in: content) != nil)
        #expect(findVisible(NSImageView.self, in: content) == nil)
        #expect(livePreview(in: textContent) == nil)
        let emptyBar = overlay.panel.frame
        flow.edit("已经说出的第一句", basedOn: "")
        overlay.render(flow, availability: .init(canInsert: canPost))
        #expect(livePreview(in: textContent)?.stringValue == "已经说出的第一句")
        #expect(textWindow.isVisible)
        #expect(textWindow.frame.minY == emptyBar.maxY)
        #expect(overlay.panel.frame == emptyBar)
        flow.edit("文字继续更新", basedOn: "已经说出的第一句")
        overlay.render(flow, availability: .init(canInsert: canPost))
        #expect(livePreview(in: textContent)?.stringValue == "文字继续更新")
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
        #expect(livePreview(in: textContent)?.stringValue == flow.state?.text)
        try #require(findButton(in: content, labeled: "展开草稿")).performClick(nil)
        #expect(livePreview(in: textContent) == nil)
        try #require(findButton(in: content, labeled: "收起草稿")).performClick(nil)
        #expect(livePreview(in: textContent)?.stringValue == flow.state?.text)
        canPost = true
        flow.handle(.confirm)
        overlay.render(flow, availability: .init(canInsert: canPost))
        #expect(livePreview(in: textContent) == nil)
        #expect(!textWindow.isVisible)
        #expect(overlay.panel.frame == emptyBar)
        let sentIcon = try #require(findVisible(NSImageView.self, in: content))
        #expect(sentIcon.image != nil)
        #expect(findVisible(VoiceWaveformView.self, in: content) == nil)
        flow.clearOrCancel()
        overlay.render(flow, availability: .init(canInsert: canPost))
        #expect(livePreview(in: textContent) == nil)
        #expect(overlay.panel.frame == emptyBar)
        #expect(sentIcon.isHiddenOrHasHiddenAncestor)
        #expect(findVisible(VoiceWaveformView.self, in: content) != nil)
        await flow.shutdown()
    }

    @Test func theVoiceBarWaveformFollowsSpeechAndReturnsToRest() async throws {
        _ = NSApplication.shared
        let overlay = VoxloomOverlay()
        let capture = FlowCapture()
        let flow = VoxloomFlow(settings: .init(), capture: { capture },
            recognizer: { _ in WaitingRecognizer(finalization: AsyncStream { $0.finish() }) }, corrector: { _ in nil },
            insertion: .init(foregroundTarget: { nil }, canPost: { false }, paste: { _, _ in false }))
        let content = try #require(overlay.panel.contentView)
        overlay.render(flow, availability: .init())
        overlay.panel.orderFront(nil)
        defer { overlay.panel.orderOut(nil) }
        content.layoutSubtreeIfNeeded()
        let waveform = try #require(findVisible(NSView.self, in: content, matching: {
            $0.accessibilityIdentifier() == "dictation-waveform"
        }))
        let glyph = try #require(waveform.layer as? CAShapeLayer)
        let idle = try #require(glyph.path)
        let size = waveform.frame.size
        #expect(size.width > 0 && size.height > 0)

        flow.handle(.start)
        try await reaches { capture.receive != nil }
        overlay.render(flow, availability: .init())
        let silence = try #require(glyph.path)
        capture.receive?([800, -800])
        try await reaches { flow.state?.live.samples.count == 2 }
        overlay.render(flow, availability: .init())
        let soft = try #require(glyph.path)
        capture.receive?([9000, -9000])
        try await reaches { flow.state?.live.samples.count == 4 }
        overlay.render(flow, availability: .init())
        let loud = try #require(glyph.path)
        #expect(silence.boundingBoxOfPath.height < soft.boundingBoxOfPath.height)
        #expect(soft.boundingBoxOfPath.height < loud.boundingBoxOfPath.height)
        #expect((glyph.animationKeys()?.isEmpty == false) == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        #expect(waveform.frame.size == size)

        capture.receive?([0, 0])
        try await reaches { flow.state?.live.samples.count == 6 }
        overlay.render(flow, availability: .init())
        #expect(glyph.path == silence)

        flow.handle(.stop)
        try await reaches { flow.state?.live.phase != .recording }
        overlay.render(flow, availability: .init())
        #expect(glyph.path == idle)
        await flow.shutdown()
    }

    private func reaches(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() && ContinuousClock.now < end { await Task.yield() }
        try #require(predicate())
    }

    private func pixel(in view: NSView, x: CGFloat, y: CGFloat) throws -> NSColor {
        let area = NSRect(x: x, y: y, width: 1, height: 1)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: area))
        view.cacheDisplay(in: area, to: bitmap)
        return try #require(bitmap.colorAt(x: 0, y: 0))
    }

    private func findVisible<View: NSView>(_ type: View.Type, in view: NSView,
                                           matching predicate: @escaping (View) -> Bool = { _ in true }) -> View? {
        if let match = view as? View, !match.isHiddenOrHasHiddenAncestor, predicate(match) { return match }
        return view.subviews.lazy.compactMap { findVisible(type, in: $0, matching: predicate) }.first
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
