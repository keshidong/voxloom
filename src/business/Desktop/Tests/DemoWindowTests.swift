import AppKit
import Foundation
import SpeechInput
import SpeechFoundation
import Testing
import VoiceDemoUI
import RxSwift

@MainActor final class DemoCaptureFixture: AudioCapturing {
    var sink: (@Sendable ([Int16]) -> Void)?
    func requestAccess() async throws {}
    func start(samples: @escaping @Sendable ([Int16]) -> Void, ended: @escaping @Sendable (String?) -> Void) throws { sink = samples }
    func stop() {}
}
actor DemoRecognizerFixture: SpeechRecognizer {
    var received: RecognitionOptions?
    let text: String
    init(text: String = "界面转写测试") { self.text = text }
    func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
        received = options
        return .init(text: text)
    }
}

private struct ReviewCorrectorFixture: TextCorrecting {
    func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        .init(text: "余额为20%", original: request.text)
    }
}

@MainActor struct DemoWindowTests {
    @Test func fnStartsRecordingAndTwoNewPressesConfirmTheKeyboardEditedDraft() async throws {
        _ = NSApplication.shared
        let capture = DemoCaptureFixture()
        let controller = DemoWindowController(resources: .init(root: FileManager.default.temporaryDirectory),
            captureFactory: { capture }, recognizerFactory: { _, _ in DemoRecognizerFixture() }, correctorFactory: { _ in nil })
        let window = try #require(controller.window)
        try sendFn(to: window, at: 1)
        try await waitUntil { capture.sink != nil }
        capture.sink?([1000, -1000])
        try await waitUntil { controller.session?.state.samples.count == 2 }
        controller.corrected.insertText("键盘补充。", replacementRange: NSRange(location: 0, length: 0))
        try sendFn(to: window, at: 2)
        #expect(controller.session?.state.phase == .recording)
        try sendFn(to: window, at: 2.2)
        try await waitUntil { controller.status.stringValue == "草稿已确认" }
        #expect(controller.corrected.string == "键盘补充。界面转写测试")
        #expect(!controller.corrected.isEditable)
        await controller.shutdown()
    }

    private func sendFn(to window: NSWindow, at timestamp: Double) throws {
        for (offset, flags): (Double, NSEvent.ModifierFlags) in [(0, .function), (0.05, [])] {
            let event = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                timestamp: timestamp + offset, windowNumber: window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 63))
            window.sendEvent(event)
        }
    }

    @Test func correctionAppearsWhileMicrophoneIsStillRecording() async throws {
        _ = NSApplication.shared
        let capture = DemoCaptureFixture()
        let scheduler = HistoricalScheduler(initialClock: Date(timeIntervalSince1970: 0))
        let controller = DemoWindowController(resources: .init(root: FileManager.default.temporaryDirectory),
            captureFactory: { capture }, recognizerFactory: { _, _ in DemoRecognizerFixture(text: "余额为30%") },
            correctorFactory: { _ in ReviewCorrectorFixture() }, correctionScheduler: scheduler)
        controller.startButton.performClick(nil)
        try await waitUntil { controller.session?.state.phase == .recording }
        capture.sink?(Array(repeating: 1000, count: 16_000))
        try await waitUntil { controller.session?.state.text == "余额为30%" }
        scheduler.advanceTo(scheduler.clock.addingTimeInterval(0.81))
        try await waitUntil { controller.corrected.string == "余额为20%" }
        #expect(controller.session?.state.phase == .recording)
        #expect(controller.transcript.string == "余额为30%")
        controller.cancelButton.performClick(nil)
        try await waitUntil { controller.session?.state.phase == .idle }
        for _ in 0..<100 { await Task.yield() }
        #expect(controller.corrected.string.isEmpty)
        controller.qwen.performClick(nil)
        try await waitUntil { controller.corrected.string.isEmpty }
        await controller.shutdown()
    }
    @Test func finalCorrectionNeverReplacesOriginalAndNumbersAreMarkedForReview() async throws {
        _ = NSApplication.shared
        let capture = DemoCaptureFixture()
        let board = NSPasteboard(name: .init("voice-correction-test-" + UUID().uuidString))
        let controller = DemoWindowController(resources: .init(root: FileManager.default.temporaryDirectory),
            captureFactory: { capture }, recognizerFactory: { _, _ in DemoRecognizerFixture(text: "余额为30%") },
            pasteboard: board, correctorFactory: { _ in ReviewCorrectorFixture() })
        controller.startButton.performClick(nil)
        try await waitUntil { controller.session?.state.phase == .recording }
        capture.sink?([1000, -1000])
        try await waitUntil { controller.session?.state.samples.count == 2 }
        controller.startButton.performClick(nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while controller.corrected.string != "余额为20%" && ContinuousClock.now < deadline { await Task.yield() }
        #expect(controller.transcript.string == "余额为30%")
        #expect(controller.corrected.string == "余额为20%")
        #expect(controller.correctionStatus.stringValue.contains("数字"))
        controller.copyCandidateButton.performClick(nil)
        #expect(board.string(forType: .string) == "余额为20%")
        await controller.shutdown()
    }
    @Test func turboChineseAccelerationAndVocabularyArePassedToRecognitionAndRecordingCanBeReused() async throws {
        _ = NSApplication.shared
        let capture = DemoCaptureFixture()
        let recognizer = DemoRecognizerFixture()
        let controller = DemoWindowController(resources: .init(root: FileManager.default.temporaryDirectory),
            captureFactory: { capture }, recognizerFactory: { _, _ in recognizer })
        #expect(controller.model.indexOfSelectedItem == 3)
        #expect(controller.language.indexOfSelectedItem == 1)
        #expect(controller.gpu.state == .on)
        controller.keywords.stringValue = "RxSwift Qwen"
        controller.startButton.performClick(nil)
        try await waitUntil { controller.session?.state.phase == .recording }
        capture.sink?([1000, -1000])
        try await waitUntil { controller.session?.state.samples.count == 2 }
        controller.startButton.performClick(nil)
        try await waitUntil { controller.session?.state.phase == .idle }
        #expect(await recognizer.received?.context == "RxSwift Qwen")
        #expect(await recognizer.received?.language == .chinese)
        #expect(controller.retryButton.isEnabled)
        controller.keywords.stringValue = "新术语"
        controller.retryButton.performClick(nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await recognizer.received?.context != "新术语" && ContinuousClock.now < deadline { await Task.yield() }
        #expect(await recognizer.received?.context == "新术语")
        #expect(controller.session?.state.samples.count == 2)
        await controller.shutdown()
    }
    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() { try #require(ContinuousClock.now < deadline); await Task.yield() }
    }

    @Test func defaultDesktopLaunchCreatesReadyWindowAndQuitsAfterCleanup() async throws {
        _ = NSApplication.shared
        var terminated = false
        let delegate = DemoApplicationDelegate(reply: { terminated = $0 })
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        let controller = try #require(delegate.controller)
        #expect(controller.window?.isVisible == true)
        #expect(controller.status.stringValue == "准备就绪")
        #expect(controller.startButton.isEnabled)
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
        try await waitUntil { terminated }
        controller.window?.orderOut(nil)
    }
    @Test func clickingRecordAndStopUsesTheModuleAndShowsTranscript() async throws {
        _ = NSApplication.shared
        let capture = DemoCaptureFixture()
        let controller = DemoWindowController(resources: .init(root: FileManager.default.temporaryDirectory),
            captureFactory: { capture }, recognizerFactory: { _, _ in DemoRecognizerFixture() })
        controller.startButton.performClick(nil)
        try await waitUntil { controller.session?.state.phase == .recording }
        let session = try #require(controller.session)
        #expect(session.state.phase == .recording)
        capture.sink?([1000, -1000])
        try await waitUntil { session.state.samples.count == 2 }
        controller.startButton.performClick(nil)
        try await waitUntil { session.state.phase == .idle }
        #expect(controller.transcript.string == "界面转写测试")
        #expect(controller.startButton.title == "开始录音")
        await controller.shutdown()
    }

    @Test func sampleCopyClearFailureAndLifecycleUseActualControls() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = DemoResources(root: root)
        let board = NSPasteboard(name: .init("voice-demo-test-" + UUID().uuidString))
        let controller = DemoWindowController(resources: resources,
            recognizerFactory: { _, _ in DemoRecognizerFixture() }, pasteboard: board)
        controller.sampleButton.performClick(nil)
        #expect(controller.status.stringValue.contains("不可用"))
        for name in ["chinese.wav", "english.wav"] { try WAVCodec.encode(AudioClip(samples: [1000, -1000])).write(to: root.appendingPathComponent(name)) }
        controller.language.selectItem(at: 2)
        controller.model.selectItem(at: 1)
        controller.sampleButton.performClick(nil)
        try await waitUntil { controller.session?.state.text == "界面转写测试" }
        controller.copyButton.performClick(nil)
        #expect(board.string(forType: .string) == "界面转写测试")
        controller.clearButton.performClick(nil)
        try await waitUntil { controller.session?.state.text.isEmpty == true }
        controller.language.selectItem(at: 1)
        controller.sampleButton.performClick(nil)
        try await waitUntil { controller.session?.state.phase == .recording }
        controller.cancelButton.performClick(nil)
        try await waitUntil { controller.session?.state.phase == .idle }
        var terminated = false
        let delegate = DemoApplicationDelegate(makeController: { controller }, reply: { terminated = $0 }, activate: {})
        delegate.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        #expect(delegate.controller === controller)
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
        try await waitUntil { terminated }
        controller.window?.orderOut(nil)
        for model in 0..<4 { _ = resources.recognizer(model: model) }
        _ = resources.corrector(useGPU: false)
    }
}
