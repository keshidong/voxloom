import AppKit
import Carbon
import RxSwift
import SpeechFoundation
import SpeechInput
import Testing
@testable import VoxloomDesktop

@MainActor @Suite(.serialized) struct VoxloomApplicationTests {
    @Test func settingsRecordsTheCompleteShortcutAndCanRestoreFn() throws {
        let app = NSApplication.shared
        let settings = SettingsWindow(settings: .init())
        let original = try #require(settings.window)
        let content = try #require(original.contentView)
        let window = ShortcutCaptureTestWindow(contentRect: original.frame, styleMask: .titled,
                                               backing: .buffered, defer: false)
        // Drive the local event monitor without activating the test host.
        original.contentView = nil
        window.contentView = content
        settings.window = window
        defer {
            settings.stopTriggerCapture()
            window.orderOut(nil)
        }
        var selected: [DictationTrigger] = []
        settings.onChange = { selected.append($0.trigger) }
        try #require(findButton(labeled: "更改按住说话键", in: content)).performClick(nil)

        func send(_ type: NSEvent.EventType, key: Int, modifiers: NSEvent.ModifierFlags) throws {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: UInt16(key)))
            app.sendEvent(event)
        }

        try send(.flagsChanged, key: kVK_Command, modifiers: .command)
        try send(.flagsChanged, key: kVK_Shift, modifiers: [.command, .shift])
        #expect(selected.isEmpty)
        try send(.keyDown, key: kVK_Space, modifiers: [.command, .shift])
        #expect(selected.map(\.name) == ["⇧⌘空格"])
        try #require(findButton(labeled: "恢复 Fn", in: content)).performClick(nil)
        #expect(selected.last == .fn)
    }

    @Test func showingTheVoiceBarRestoresItAboveTheDock() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)
        let bounds = screen.visibleFrame
        let app = VoxloomCoordinator(root: FileManager.default.temporaryDirectory, activate: {})
        let panel = app.overlay.panel
        defer { panel.orderOut(nil) }
        panel.setFrameOrigin(NSPoint(x: bounds.midX - panel.frame.width / 2, y: bounds.minY - panel.frame.height))
        try #require(!bounds.contains(panel.frame))

        app.showOverlay()

        #expect(bounds.contains(panel.frame))
        #expect(panel.frame.minY > bounds.minY)
        #expect(panel.isVisible)
    }

    private enum AccessibilityChoice { case enable, later }

    @Test func firstLaunchGuidesAccessibilityBeforeMicrophoneAndDownloadProgress() async throws {
        try await verifyFirstLaunch(.enable)
    }

    @Test func skippingAccessibilityStillAllowsMicrophoneAndDownloadProgress() async throws {
        try await verifyFirstLaunch(.later)
    }

    @Test func anEarlierAcknowledgmentDoesNotBypassMissingAccessibilityOnLaunch() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "onboarding.accessibilityAcknowledged")
        let capture = FlowCapture()
        let clock = HistoricalScheduler(initialClock: Date(timeIntervalSince1970: 0))
        var keys: DictationKeyInput?
        let app = VoxloomCoordinator(root: FileManager.default.temporaryDirectory, defaults: defaults,
            recognizer: { _ in SampleRecognizer() }, capture: { capture }, activate: {},
            permissions: .init(isTrusted: { false }, canPostEvents: { false }, microphoneAuthorization: { .authorized }),
            makeMonitor: { input in
                let simulated = DictationKeyInput(scheduler: clock, canConfirm: input.canConfirm, action: input.action)
                keys = simulated
                return DictationKeyMonitor(input: simulated, isTrusted: { false })
            })
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { app.overlay.panel.orderOut(nil) }
        #expect(!app.overlay.enableAccessibility.isHiddenOrHasHiddenAncestor)
        #expect(!app.overlay.deferAccessibility.isHiddenOrHasHiddenAncestor)
        let key = try #require(keys)
        key.changed(down: true, at: 0)
        clock.advanceTo(clock.clock.addingTimeInterval(0.2))
        #expect(app.flow.canStart)
        #expect(capture.receive == nil)
        key.changed(down: false, at: 0.3)
        app.overlay.deferAccessibility.performClick(nil)
        key.changed(down: true, at: 1)
        clock.advanceTo(clock.clock.addingTimeInterval(0.2))
        #expect(!app.flow.canStart)
        await app.stop()
    }

    private func verifyFirstLaunch(_ choice: AccessibilityChoice) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = """
        {"qwen":[{"path":"weights","url":"https://example.com/required",
        "sha256":"2689367b205c16ce32ed4200942b8b8b1e262dfc70d9bc9fbc77c49699a4f1df","bytes":2}],
        "correction":[{"path":"correction","url":"https://example.com/optional",
        "sha256":"2689367b205c16ce32ed4200942b8b8b1e262dfc70d9bc9fbc77c49699a4f1df","bytes":2}]}
        """
        try Data(manifest.utf8).write(to: directory.appending(path: "model-downloads.json"))
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = AsyncStream<Void>.makeStream()
        let started = AsyncStream<Void>.makeStream()
        let optionalGate = AsyncStream<Void>.makeStream()
        let optionalStart = OptionalModelStart()
        var microphone = MicrophoneCapture.Authorization.notDetermined
        var microphoneRequests = 0
        var accessibilityGranted = false
        var accessibilityRequests = 0
        let cache = directory.appending(path: "models")
        let downloads = try #require(LocalModels(root: directory, downloadDirectory: cache).downloads)
        let capture = FlowCapture()
        let engine = PrewarmTestRecognizer()
        let app = VoxloomCoordinator(root: directory, defaults: defaults, recognizer: { _ in engine },
            capture: { capture }, activate: {}, permissions: .init(isTrusted: { accessibilityGranted },
                canPostEvents: { accessibilityGranted }, requestAccessibility: { accessibilityRequests += 1 },
                microphoneAuthorization: { microphone }, requestMicrophone: {
                    microphoneRequests += 1
                    microphone = .authorized
                    return true
                }),
            downloadDirectory: cache, downloadModel: { url, progress in
                if url.lastPathComponent == "required" {
                    progress(1, 2)
                    started.continuation.yield(())
                    var permit = gate.stream.makeAsyncIterator()
                    _ = await permit.next()
                } else {
                    await optionalStart.record(asrReady: downloads.isInstalled("qwen"))
                    var permit = optionalGate.stream.makeAsyncIterator()
                    _ = await permit.next()
                }
                let file = directory.appending(path: url.lastPathComponent)
                try Data("ok".utf8).write(to: file)
                return file
            }, makeMonitor: { DictationKeyMonitor(input: $0, isTrusted: { false }) })
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            gate.continuation.finish()
            started.continuation.finish()
            optionalGate.continuation.finish()
            app.settingsWindow.window?.orderOut(nil)
            app.overlay.panel.orderOut(nil)
        }
        #expect(app.overlay.panel.isVisible)
        #expect(app.settingsWindow.window?.isVisible == false)
        var transfer = started.stream.makeAsyncIterator()
        _ = await transfer.next()
        #expect(await optionalStart.asrReady == nil)
        #expect(microphoneRequests == 0)
        #expect(!app.overlay.enableAccessibility.isHiddenOrHasHiddenAncestor)
        #expect(app.overlay.enableMicrophone.isHiddenOrHasHiddenAncestor)
        #expect(app.overlay.downloadProgress.isHiddenOrHasHiddenAncestor)
        switch choice {
        case .enable:
            app.overlay.enableAccessibility.performClick(nil)
            #expect(accessibilityRequests == 1)
            #expect(app.overlay.enableMicrophone.isHiddenOrHasHiddenAncestor)
            accessibilityGranted = true
            app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        case .later:
            let content = try #require(app.overlay.panel.contentView)
            let later = try #require(findButton(labeled: "稍后", in: content))
            later.performClick(nil)
            #expect(accessibilityRequests == 0)
            app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        }
        #expect(!app.overlay.enableMicrophone.isHiddenOrHasHiddenAncestor)
        #expect(app.overlay.downloadProgress.isHiddenOrHasHiddenAncestor)
        app.flow.handle(.start)
        #expect(capture.receive == nil)
        #expect(await engine.prepares == 0)
        #expect(app.flow.notice?.contains("转写模型尚未就绪") == true)

        app.overlay.enableMicrophone.performClick(nil)
        let progressDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while app.overlay.downloadProgress.doubleValue != 50 && ContinuousClock.now < progressDeadline {
            await Task.yield()
        }
        #expect(microphoneRequests == 1)
        #expect(app.overlay.enableMicrophone.isHiddenOrHasHiddenAncestor)
        #expect(!app.overlay.downloadProgress.isHiddenOrHasHiddenAncestor)
        #expect(app.overlay.downloadProgress.doubleValue == 50)
        #expect(app.overlay.status.stringValue.contains("50%"))

        gate.continuation.yield(())
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await engine.prepares == 0 && ContinuousClock.now < deadline { await Task.yield() }
        #expect(await engine.prepares == 1)
        #expect(await optionalStart.asrReady == nil)
        #expect(app.overlay.downloadProgress.isHiddenOrHasHiddenAncestor)
        app.flow.handle(.start)
        while capture.receive == nil && ContinuousClock.now < deadline { await Task.yield() }
        #expect(capture.receive != nil)
        #expect(!downloads.isInstalled("correction"))
        capture.receive?([3000, -3000])
        while app.flow.state?.live.samples.count != 2 && ContinuousClock.now < deadline { await Task.yield() }
        app.flow.handle(.stop)
        while !app.flow.canStart && ContinuousClock.now < deadline { await Task.yield() }
        #expect(app.flow.state?.text == "第一段")
        #expect(!app.flow.settings.correctsText)
        #expect(!downloads.isInstalled("correction"))
        #expect(await optionalStart.asrReady == nil)
        await app.stop()
    }

    @Test func launchingPreparesTheSelectedEngineWithoutStartingCapture() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let capture = FlowCapture()
        let engine = PrewarmTestRecognizer()
        var factoryCalls = 0
        let app = VoxloomCoordinator(root: FileManager.default.temporaryDirectory, defaults: defaults,
            recognizer: { _ in factoryCalls += 1; return engine }, capture: { capture }, activate: {},
            permissions: .init(isTrusted: { false }, canPostEvents: { false }, microphoneAuthorization: { .authorized }))
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { app.overlay.panel.orderOut(nil) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await engine.prepares == 0 && ContinuousClock.now < deadline { await Task.yield() }
        #expect(await engine.prepares == 1)
        #expect(factoryCalls == 1)
        #expect(capture.receive == nil)
        #expect(app.flow.canStart)

        app.flow.handle(.start)
        let captureDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while capture.receive == nil && ContinuousClock.now < captureDeadline { await Task.yield() }
        #expect(capture.receive != nil)
        #expect(factoryCalls == 1)
        await app.stop()
    }

    @Test func settingsShowsABilingualSentenceToReadDuringEnrollment() throws {
        _ = NSApplication.shared
        let settings = SettingsWindow(settings: DictationSettings())
        let content = try #require(settings.window?.contentView)
        content.layoutSubtreeIfNeeded()

        func textFields(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { subview in
                if let field = subview as? NSTextField { return [field] }
                return textFields(in: subview)
            }
        }

        let example = try #require(textFields(in: content).first {
            $0.stringValue == "今天我想试试语音输入。Can you hear me clearly?"
        })
        #expect(!example.isHiddenOrHasHiddenAncestor)
        #expect(!example.bounds.isEmpty)
        #expect(content.bounds.contains(example.convert(example.bounds, to: content)))
    }

    @Test func settingsPlaysAndStopsSavedVoiceSamples() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceSampleStore(directory: root.appendingPathComponent("samples"))
        let clip = try AudioClip(samples: Array(repeating: 350, count: VoiceEnrollment.minimumSamples))
        try store.write(clip, for: .normal)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = TestVoiceSamplePlayer()
        let app = VoxloomCoordinator(root: root, defaults: defaults, activate: {},
            voiceSampleDirectory: store.directory, voiceSamplePlayer: player)
        app.connectViews()
        defer { app.overlay.panel.orderOut(nil) }
        let window = try #require(app.settingsWindow.window)
        let content = try #require(window.contentView)
        let normal = try #require(findButton(labeled: "试听正常样本", in: content))
        let loud = try #require(findButton(labeled: "试听大声样本", in: content))
        #expect(normal.isEnabled)
        #expect(!loud.isEnabled)

        normal.performClick(nil)
        #expect(player.audio == clip)
        #expect(normal.title == "停止")
        normal.performClick(nil)
        #expect(player.audio == nil)
        #expect(normal.title == "试听")

        normal.performClick(nil)
        player.finish()
        #expect(normal.title == "试听")
        normal.performClick(nil)
        window.close()
        #expect(player.audio == nil)
        await app.stop()
    }

    @Test func isolationSwitchPersistsAndRequiresAnEnrolledVoiceWhenEnabled() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = root.appendingPathComponent("voice-isolation-runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = runtime.appendingPathComponent("voice-isolation")
        try Data().write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = VoxloomCoordinator(root: root, defaults: defaults, activate: {},
            voiceSampleDirectory: root.appendingPathComponent("samples"))
        app.connectViews()
        defer { app.overlay.panel.orderOut(nil) }

        let toggle = app.settingsWindow.voiceIsolation
        #expect(toggle.state == .off)
        #expect(!toggle.isHiddenOrHasHiddenAncestor)
        toggle.performClick(nil)
        #expect(DictationSettings(defaults: defaults).usesVoiceIsolation)
        app.flow.handle(.start)
        #expect(app.flow.notice == "先在设置里录一段你的声音")
        toggle.performClick(nil)
        #expect(!DictationSettings(defaults: defaults).usesVoiceIsolation)
        await app.stop()
    }

    @Test func heldDictationPreviewsIsolatedAudioAndInsertsOnlyTheBatchResult() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("voice-isolation-runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let worker = runtime.appendingPathComponent("voice-isolation")
        try """
        #!/bin/sh
        printf '%s\\n' '{"ready":true}'
        while IFS= read -r request; do
            output=$(printf '%s' "$request" | /usr/bin/plutil -extract output raw -o - -- -) || exit 1
            if printf '%s' "$request" | /usr/bin/plutil -extract previewSession raw -o - -- - >/dev/null 2>&1; then
                /bin/cp "$(dirname "$0")/preview.wav" "$output" || exit 2
            else
                /bin/cp "$(dirname "$0")/final.wav" "$output" || exit 3
            fi
            printf '%s\\n' '{"ok":true}'
        done
        """.write(to: worker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        let raw = Array(repeating: Int16(1000), count: AudioClip.sampleRate)
        try WAVCodec.encode(AudioClip(samples: [111])).write(to: runtime.appendingPathComponent("preview.wav"))
        try WAVCodec.encode(AudioClip(samples: Array(repeating: 222, count: raw.count)))
            .write(to: runtime.appendingPathComponent("final.wav"))
        let store = VoiceSampleStore(directory: root.appendingPathComponent("samples"))
        try store.write(AudioClip(samples: raw + raw + raw), for: .normal)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = DictationSettings()
        settings.usesVoiceIsolation = true
        settings.save(to: defaults)
        let capture = FlowCapture()
        var pasted: [String] = []
        let app = VoxloomCoordinator(root: root, defaults: defaults, recognizer: { _ in IsolationTestRecognizer() },
            capture: { capture }, insertion: .init(foregroundTarget: { 101 }, canPost: { true },
                paste: { text, _ in pasted.append(text); return true }, captureFocus: { _ in { true } }),
            activate: {}, voiceSampleDirectory: store.directory)
        app.connectViews()
        defer { app.overlay.panel.orderOut(nil) }
        func waitFor(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            while !condition() && ContinuousClock.now < deadline { await Task.yield() }
            try #require(condition())
        }

        app.flow.handle(.start)
        try await waitFor { capture.receive != nil }
        capture.receive?(raw)
        try await waitFor { app.flow.state?.live.text == "预览" }
        #expect(app.flow.state?.live.phase == .recording)
        #expect(pasted.isEmpty)
        app.flow.handle(.stop)
        try await waitFor { !pasted.isEmpty }
        #expect(pasted == ["整段定稿"])
        await app.stop()
    }

    enum EditShortcutOutcome: CaseIterable { case finishEditing, cancel }

    @Test(arguments: EditShortcutOutcome.allCases)
    func anEditRequestCanBeCompletedOrCancelledFromTheKeyboard(outcome: EditShortcutOutcome) async throws {
        _ = NSApplication.shared
        let domain = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let capture = FlowCapture()
        let clock = HistoricalScheduler(initialClock: Date(timeIntervalSince1970: 0))
        var tapped: ((NSEvent) -> Bool)?
        var pasted: [String] = []
        let app = VoxloomCoordinator(root: FileManager.default.temporaryDirectory, defaults: defaults, pasteboard: board,
            recognizer: { _ in SampleRecognizer(text: "口述文字") }, capture: { capture },
            insertion: .init(foregroundTarget: { 101 }, canPost: { true },
                paste: { text, _ in pasted.append(text); return true }, captureFocus: { _ in { true } }),
            activate: {}, permissions: .init(isTrusted: { true }, canPostEvents: { true },
                microphoneAuthorization: { .authorized }), keyScheduler: clock,
            makeMonitor: { input in
                DictationKeyMonitor(input: input, isTrusted: { true }, filterGlobal: { handler, _ in
                    tapped = handler
                    return { tapped = nil }
                })
            })
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { app.overlay.panel.orderOut(nil) }
        let deliver = try #require(tapped)
        func event(_ type: NSEvent.EventType, key: Int, flags: NSEvent.ModifierFlags = [],
                   characters: String = "") throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: app.overlay.panel.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(key)))
        }

        #expect(!deliver(try event(.flagsChanged, key: kVK_Function, flags: .function)))
        clock.advanceTo(clock.clock.addingTimeInterval(0.2))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while capture.receive == nil && ContinuousClock.now < deadline { await Task.yield() }
        try #require(capture.receive != nil)
        #expect(deliver(try event(.keyDown, key: kVK_ANSI_E, flags: .function)))
        #expect(app.overlay.status.stringValue == "松开 Fn 后编辑")
        #expect(app.overlay.editor.isHiddenOrHasHiddenAncestor)
        capture.receive?([3000, -3000])
        while app.flow.state?.live.samples.count != 2 && ContinuousClock.now < deadline { await Task.yield() }
        try #require(app.flow.state?.live.samples.count == 2)
        if outcome == .cancel {
            #expect(deliver(try event(.keyDown, key: kVK_Escape, flags: .function)))
            #expect(deliver(try event(.keyUp, key: kVK_Escape, flags: .function)))
        }
        #expect(!deliver(try event(.flagsChanged, key: kVK_Function)))
        #expect(deliver(try event(.keyUp, key: kVK_ANSI_E)))
        while !app.flow.canStart && ContinuousClock.now < deadline { await Task.yield() }
        try #require(app.flow.canStart)
        #expect(pasted.isEmpty)
        if outcome == .cancel {
            #expect(app.overlay.editor.isHiddenOrHasHiddenAncestor)
            #expect(app.overlay.editor.string.isEmpty)
            #expect(app.overlay.status.stringValue == "本轮已取消，松开 Fn 后可重录")
            await app.stop()
            return
        }
        #expect(!app.overlay.editor.isHiddenOrHasHiddenAncestor)
        #expect(app.overlay.editor.window?.firstResponder === app.overlay.editor)
        #expect(app.overlay.editor.string == "口述文字")

        let editor = app.overlay.editor
        editor.insertText("已修改", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.keyDown(with: try event(.keyDown, key: kVK_Return, characters: "\r"))
        #expect(pasted == ["已修改"])
        #expect(editor.isHiddenOrHasHiddenAncestor)
        await app.stop()
    }

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
            activate: {}, permissions: .init(isTrusted: { true }, canPostEvents: { true },
                microphoneAuthorization: { .authorized }), makeMonitor: { key in
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

    @Test func correctionModelDownloadsOnlyWhenCorrectionIsEnabled() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = """
        {"qwen":[{"path":"weights","url":"https://example.com/required",
        "sha256":"2689367b205c16ce32ed4200942b8b8b1e262dfc70d9bc9fbc77c49699a4f1df","bytes":2}],
        "correction":[{"path":"Qwen3-4B-Instruct-2507-Q4_K_M.gguf","url":"https://example.com/optional",
        "sha256":"2689367b205c16ce32ed4200942b8b8b1e262dfc70d9bc9fbc77c49699a4f1df","bytes":2}]}
        """
        try Data(manifest.utf8).write(to: root.appending(path: "model-downloads.json"))
        let domain = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let directory = root.appending(path: "models")
        let models = LocalModels(root: root, downloadDirectory: directory)
        let downloads = try #require(models.downloads)
        let requiredGate = AsyncStream<Void>.makeStream()
        let optionalGate = AsyncStream<Void>.makeStream()
        let transfer = OptionalModelStart()
        let capture = FlowCapture()
        let recognizer = PrewarmTestRecognizer()
        let app = VoxloomCoordinator(root: root, defaults: defaults, recognizer: { _ in recognizer },
            capture: { capture }, insertion: .init(foregroundTarget: { nil }, canPost: { false }, paste: { _, _ in false }),
            activate: {},
            permissions: .init(isTrusted: { true }, canPostEvents: { true }, microphoneAuthorization: { .authorized }),
            downloadDirectory: directory, downloadModel: { url, progress in
                if url.lastPathComponent == "required" {
                    await transfer.recordRequiredStart()
                    for await _ in requiredGate.stream { break }
                } else {
                    await transfer.record(asrReady: downloads.isInstalled("qwen"))
                    progress(1, 2)
                    for await _ in optionalGate.stream { break }
                }
                let file = root.appending(path: url.lastPathComponent)
                try Data("ok".utf8).write(to: file)
                return file
            })
        app.connectViews()
        defer {
            requiredGate.continuation.finish()
            optionalGate.continuation.finish()
            app.overlay.panel.orderOut(nil)
        }
        let content = try #require(app.settingsWindow.window?.contentView)
        #expect(!containsLabel("Qwen3-4B Instruct 等待下载", in: content))
        let startupDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await !transfer.requiredStarted && ContinuousClock.now < startupDeadline { await Task.yield() }
        try #require(await transfer.requiredStarted)
        #expect(await transfer.asrReady == nil)
        requiredGate.continuation.finish()

        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await recognizer.prepares == 0 && ContinuousClock.now < readyDeadline { await Task.yield() }
        try #require(await recognizer.prepares > 0)
        #expect(await transfer.asrReady == nil)
        #expect(!containsLabel("Qwen3-4B Instruct 下载中，请稍候", in: content))
        #expect(!containsLabel("Qwen3-4B Instruct 下载中 50%", in: content))

        let correction = app.settingsWindow.correction
        correction.selectItem(at: 0)
        let correctionAction = try #require(correction.action)
        correction.sendAction(correctionAction, to: correction.target)

        let optionalDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !containsLabel("Qwen3-4B Instruct 下载中 50%", in: content) && ContinuousClock.now < optionalDeadline {
            await Task.yield()
        }
        #expect(containsLabel("Qwen3-4B Instruct 下载中 50%", in: content))
        #expect(await transfer.asrReady == true)
        #expect(!downloads.isInstalled("correction"))
        app.flow.handle(.start)
        let recordDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while capture.receive == nil && ContinuousClock.now < recordDeadline { await Task.yield() }
        try #require(capture.receive != nil)
        capture.receive?([3000, -3000])
        while app.flow.state?.live.samples.count != 2 && ContinuousClock.now < recordDeadline { await Task.yield() }
        app.flow.handle(.stop)
        while !app.flow.canStart && ContinuousClock.now < recordDeadline { await Task.yield() }
        #expect(app.flow.state?.text == "第一段")
        #expect(!downloads.isInstalled("correction"))

        optionalGate.continuation.finish()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !containsLabel("Qwen3-4B Instruct 已就绪", in: content) && ContinuousClock.now < deadline { await Task.yield() }

        let saved = DictationSettings(defaults: defaults)
        #expect(saved.correctsText)
        #expect(downloads.isInstalled("correction"))
        #expect(containsLabel("Qwen3-4B Instruct 已就绪", in: content))
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
            requestAccessibility: { accessibilityRequests += 1 }, requestPostEvents: { postingRequests += 1 },
            microphoneAuthorization: { .authorized })
        let app = VoxloomCoordinator(root: FileManager.default.temporaryDirectory, defaults: defaults, activate: {},
            permissions: permissions,
            makeMonitor: { DictationKeyMonitor(input: $0, isTrusted: permissions.isTrusted, observeGlobal: { _ in {} }) },
            replyToQuit: { quit = $0 })
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(app.overlay.panel.isVisible)
        #expect(app.overlay.status.stringValue == "全局快捷键")
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
}

@MainActor struct VoxloomDraftApplicationTests {
    @Test func aRecordingCanBeEditedCopiedAndClearedInTheOverlay() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        let capture = FlowCapture()
        let app = VoxloomCoordinator(root: root, defaults: defaults, pasteboard: board,
                                     recognizer: { _ in SampleRecognizer() }, capture: { capture }, activate: {},
                                     permissions: .init(isTrusted: { false }, microphoneAuthorization: { .authorized }))
        app.connectViews()
        app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        app.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification))
        #expect(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        let rootView = try #require(app.overlay.panel.contentView)
        try #require(findButton(labeled: "稍后", in: rootView)).performClick(nil)
        try #require(findButton(labeled: "展开草稿", in: rootView)).performClick(nil)
        func recordDraft() async throws {
            app.flow.handle(.start)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while capture.receive == nil && ContinuousClock.now < deadline { await Task.yield() }
            let receive = try #require(capture.receive)
            receive([3000, -3000])
            while app.flow.state?.live.samples.count != 2 && ContinuousClock.now < deadline { await Task.yield() }
            try #require(app.flow.state?.live.samples.count == 2)
            app.flow.handle(.interrupted)
            while !app.flow.canInsert && ContinuousClock.now < deadline { await Task.yield() }
            try #require(app.flow.canInsert)
        }

        try await recordDraft()
        #expect(app.overlay.editor.string == "示例草稿")
        #expect(app.overlay.editor.isEditable)
        try #require(findButton(labeled: "收起草稿", in: rootView)).performClick(nil)
        #expect(app.overlay.status.stringValue == "草稿已就绪")
        #expect(app.overlay.editor.isHiddenOrHasHiddenAncestor)
        try #require(findButton(labeled: "展开草稿", in: rootView)).performClick(nil)
        #expect(app.overlay.editor.string == "示例草稿")
        let editorWindow = try #require(app.overlay.editor.window)
        #expect(editorWindow.firstResponder === app.overlay.editor)
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: editorWindow.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: UInt16(kVK_Return)))
        app.overlay.editor.keyDown(with: enter)
        #expect(app.overlay.status.stringValue == "请为 Voxloom 启用辅助功能，草稿已保留。")
        #expect(app.flow.state?.text == "示例草稿")
        app.overlay.editor.string = "编辑后的草稿"
        app.overlay.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(app.flow.state?.text == "编辑后的草稿")
        #expect(app.flow.canStart)
        app.overlay.copy.performClick(nil)
        #expect(board.string(forType: .string) == "编辑后的草稿")
        func escapeEvent(_ modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: editorWindow.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: repeated,
                keyCode: UInt16(kVK_Escape)))
        }
        let fnEscape = try escapeEvent(.function)
        let repeatedEscape = try escapeEvent(repeated: true)
        #expect(!app.overlay.editor.handleDraftShortcut(fnEscape))
        #expect(!app.overlay.editor.handleDraftShortcut(repeatedEscape))
        #expect(app.flow.state?.text == "编辑后的草稿")
        app.overlay.editor.keyDown(with: try escapeEvent())
        #expect(app.overlay.editor.string.isEmpty)
        #expect(app.flow.state?.text == "")
        #expect(editorWindow.isVisible)
        try await recordDraft()
        #expect(app.overlay.editor.string == "示例草稿")
        app.overlay.clear.performClick(nil)
        #expect(app.overlay.editor.string.isEmpty)
        let hide = try #require(findButton(labeled: "隐藏悬浮窗口", in: rootView))
        hide.performClick(nil)
        #expect(!app.overlay.panel.isVisible)
        #expect(!editorWindow.isVisible)
        #expect(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        #expect(app.overlay.panel.isVisible)
        #expect(editorWindow.isVisible)
        await app.stop()
        app.overlay.panel.orderOut(nil)
    }

}

@MainActor private final class ShortcutCaptureTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor private func findButton(labeled label: String, in view: NSView) -> NSButton? {
    if let button = view as? NSButton, button.accessibilityLabel() == label || button.title == label { return button }
    return view.subviews.lazy.compactMap { findButton(labeled: label, in: $0) }.first
}

@MainActor private func containsLabel(_ value: String, in view: NSView) -> Bool {
    guard !view.isHidden else { return false }
    if let label = view as? NSTextField, label.stringValue == value { return true }
    return view.subviews.contains { containsLabel(value, in: $0) }
}

private struct SampleRecognizer: SpeechRecognizer {
    var text = "示例草稿"

    func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
        .init(text: text)
    }
}

private struct IsolationTestRecognizer: SpeechRecognizer {
    func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
        .init(text: audio.samples.first == 111 ? "预览" : "整段定稿")
    }
}

private actor PrewarmTestRecognizer: SpeechRecognizer {
    private(set) var prepares = 0
    func prepare() async { prepares += 1 }
    func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
        .init(text: "第一段")
    }
}

private actor OptionalModelStart {
    private(set) var requiredStarted = false
    private(set) var asrReady: Bool?
    func recordRequiredStart() { requiredStarted = true }
    func record(asrReady: Bool) { self.asrReady = asrReady }
}
