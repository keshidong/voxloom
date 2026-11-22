import AppKit
import Carbon
import RxSwift
import SpeechFoundation
import SpeechInput
import Testing
@testable import VoxloomDesktop

@MainActor @Suite(.serialized) struct VoxloomApplicationTests {
    @Test(arguments: [1, 200])
    func releasingFnInsertsTheTranscriptionThroughTheDesktopCoordinator(repetitions: Int) async throws {
        _ = NSApplication.shared
        let domain = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var settings = DictationSettings()
        settings.correctsText = false
        settings.save(to: defaults)
        let capture = FlowCapture()
        let clock = HistoricalScheduler(initialClock: Date(timeIntervalSince1970: 0))
        var input: DictationKeyInput?
        let editor = NSTextView()
        editor.string = "请替换旧词。"
        editor.setSelectedRange(NSRange(location: 3, length: 2))
        let transcript = String(repeating: "示例草稿", count: repetitions)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("用户剪贴板", forType: .string)
        let systemPaste = SystemPaste(board: board) { event, _ in
            if event.type == .keyDown { #expect(editor.readSelection(from: board, type: .string)) }
        }
        let insertion = CaretInsertion(foregroundTarget: { 101 }, canPost: { true },
            paste: systemPaste.paste, captureFocus: { _ in { true } })
        let app = VoxloomCoordinator(root: FileManager.default.temporaryDirectory, defaults: defaults,
            recognizer: { _ in SampleRecognizer(text: transcript) }, capture: { capture }, insertion: insertion,
            activate: {}, permissions: .init(isTrusted: { true }, canPostEvents: { true }), makeMonitor: { key in
                let simulated = DictationKeyInput(scheduler: clock, canConfirm: key.canConfirm, action: key.action)
                input = simulated
                return DictationKeyMonitor(input: simulated, isTrusted: { false })
            })
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { app.overlay.panel.orderOut(nil) }
        let key = try #require(input)
        key.changed(down: true, at: 0)
        clock.advanceTo(clock.clock.addingTimeInterval(0.2))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while capture.receive == nil && ContinuousClock.now < deadline { await Task.yield() }
        try #require(capture.receive != nil)
        capture.receive?([3000, -3000])
        while app.flow.state?.live.samples.count != 2 && ContinuousClock.now < deadline { await Task.yield() }
        try #require(app.flow.state?.live.samples.count == 2)
        #expect(editor.string == "请替换旧词。")
        key.changed(down: false, at: 0.3)
        while !app.flow.didSendInsertion && ContinuousClock.now < deadline { await Task.yield() }
        let fullyInserted = editor.string == "请替换\(transcript)。"
        #expect(fullyInserted)
        #expect(app.overlay.status.stringValue == "已发送插入请求")
        #expect(app.flow.canStart)
        systemPaste.restoreClipboard()
        #expect(board.string(forType: .string) == "用户剪贴板")
        await app.stop()
    }

    @Test func openingTheAppShowsModelSettingsAndOneAccessibilityAction() async throws {
        _ = NSApplication.shared
        let domain = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var accessibilityRequests = 0
        var postingRequests = 0
        var trusted = false
        var postingAllowed = false
        var quit = false
        let permissions = DictationPermissions(isTrusted: { trusted }, canPostEvents: { postingAllowed },
            requestAccessibility: { accessibilityRequests += 1 }, requestPostEvents: { postingRequests += 1 })
        let app = VoxloomCoordinator(root: FileManager.default.temporaryDirectory, defaults: defaults, activate: {},
            permissions: permissions,
            makeMonitor: { DictationKeyMonitor(input: $0, isTrusted: permissions.isTrusted, observeGlobal: { _ in {} }) },
            replyToQuit: { quit = $0 })
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(app.overlay.panel.isVisible)
        #expect(app.overlay.status.stringValue == "按住 Fn 说话")
        #expect(app.overlay.editor.isHiddenOrHasHiddenAncestor)
        let overlayContent = try #require(app.overlay.panel.contentView)
        let enableAccessibility = try #require(findButton(labeled: "启用辅助功能", in: overlayContent))
        #expect(!enableAccessibility.isHiddenOrHasHiddenAncestor)
        enableAccessibility.performClick(nil)
        #expect(accessibilityRequests == 1)
        #expect(postingRequests == 0)
        let workspace = NSWorkspace.shared.notificationCenter
        app.overlay.settings.performClick(nil)
        #expect(app.settingsWindow.window?.isVisible == true)
        let settingsContent = try #require(app.settingsWindow.window?.contentView)
        #expect(findButton(labeled: "启用全局快捷键", in: settingsContent) == nil)
        #expect(findButton(labeled: "允许跨应用插入", in: settingsContent) == nil)
        app.settingsWindow.recognition.selectItem(at: 2)
        let action = try #require(app.settingsWindow.recognition.action)
        app.settingsWindow.recognition.sendAction(action, to: app.settingsWindow.recognition.target)
        #expect(DictationSettings(defaults: defaults).model == .whisperBase)
        app.settingsWindow.vocabulary.stringValue = "Voxloom"
        app.settingsWindow.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(DictationSettings(defaults: defaults).vocabulary == "Voxloom")
        #expect(app.settingsWindow.inputContext.state == .on)
        app.settingsWindow.inputContext.performClick(nil)
        #expect(!DictationSettings(defaults: defaults).usesInputContext)
        let settingsAction = try #require(findButton(labeled: "启用辅助功能", in: settingsContent))
        settingsAction.performClick(nil)
        #expect(accessibilityRequests == 2)
        #expect(postingRequests == 0)
        trusted = true
        postingAllowed = true
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared)
        #expect(enableAccessibility.isHiddenOrHasHiddenAncestor)
        #expect(!settingsAction.isEnabled)
        #expect(app.overlay.status.stringValue == "按住 Fn 说话，松开插入")
        #expect(app.applicationShouldTerminate(NSApp) == .terminateLater)
        let end = ContinuousClock.now.advanced(by: .seconds(1))
        while !quit && ContinuousClock.now < end { await Task.yield() }
        #expect(quit)
        app.settingsWindow.window?.orderOut(nil)
        app.overlay.panel.orderOut(nil)
    }

    @Test func sampleUsesTheEditableOverlayAndCanBeCopiedOrCleared() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try WAVCodec.encode(AudioClip(samples: [3000, -3000])).write(to: root.appendingPathComponent("chinese.wav"))
        let domain = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var initial = DictationSettings()
        initial.correctsText = false
        initial.save(to: defaults)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        let app = VoxloomCoordinator(root: root, defaults: defaults, pasteboard: board,
                                     recognizer: { _ in SampleRecognizer() }, activate: {}, permissions: .init(isTrusted: { false }))
        app.connectViews()
        app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        app.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification))
        #expect(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        let rootView = try #require(app.overlay.panel.contentView)
        try #require(findButton(labeled: "草稿", in: rootView)).performClick(nil)
        app.overlay.sample.performClick(nil)
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !app.overlay.copy.isEnabled && ContinuousClock.now < end { await Task.yield() }
        #expect(app.flow.usesSample)
        #expect(app.overlay.editor.string == "示例草稿")
        #expect(app.overlay.editor.isEditable)
        try #require(findButton(labeled: "收起草稿", in: rootView)).performClick(nil)
        #expect(app.overlay.status.stringValue == "草稿已就绪")
        #expect(app.overlay.editor.isHiddenOrHasHiddenAncestor)
        try #require(findButton(labeled: "草稿", in: rootView)).performClick(nil)
        #expect(app.overlay.editor.string == "示例草稿")
        #expect(app.overlay.panel.firstResponder === app.overlay.editor)
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: app.overlay.panel.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: UInt16(kVK_Return)))
        app.overlay.editor.keyDown(with: enter)
        #expect(app.overlay.status.stringValue == "请为 Voxloom 启用辅助功能，草稿已保留。")
        #expect(app.flow.state?.text == "示例草稿")
        app.overlay.editor.string = "编辑后的草稿"
        app.overlay.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(app.flow.state?.text == "编辑后的草稿")
        #expect(app.flow.canStart)
        #expect(!app.overlay.sample.isEnabled)
        app.overlay.copy.performClick(nil)
        #expect(board.string(forType: .string) == "编辑后的草稿")
        app.overlay.clear.performClick(nil)
        #expect(app.overlay.editor.string.isEmpty)
        try FileManager.default.removeItem(at: root.appendingPathComponent("chinese.wav"))
        app.overlay.sample.performClick(nil)
        #expect(app.overlay.status.stringValue == "示例音频不可用")
        let hide = try #require(findButton(labeled: "隐藏悬浮窗口", in: rootView))
        hide.performClick(nil)
        #expect(!app.overlay.panel.isVisible)
        #expect(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        #expect(app.overlay.panel.isVisible)
        await app.stop()
        app.overlay.panel.orderOut(nil)
    }

    private func findButton(labeled label: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityLabel() == label || button.title == label { return button }
        return view.subviews.lazy.compactMap { self.findButton(labeled: label, in: $0) }.first
    }
}

private struct SampleRecognizer: SpeechRecognizer {
    var text = "示例草稿"

    func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
        .init(text: text)
    }
}
