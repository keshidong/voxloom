import AppKit
import RxSwift
import SpeechInput
import SpeechFoundation

@MainActor public enum VoxloomApplication {
    public static func run() {
        let app = NSApplication.shared
        let coordinator = VoxloomCoordinator(root: Bundle.main.resourceURL ?? Bundle.main.bundleURL,
            downloadDirectory: VoxloomCoordinator.modelDirectory)
        app.setActivationPolicy(.accessory)
        app.delegate = coordinator
        app.run()
        withExtendedLifetime(coordinator) {}
    }
}

@MainActor final class VoxloomCoordinator: NSObject, NSApplicationDelegate {
    let overlay = VoxloomOverlay()
    let settingsWindow: SettingsWindow
    let flow: VoxloomFlow
    private let defaults: UserDefaults
    private let models: LocalModels
    private let modelPreparation: ModelPreparation?
    private let enrollment: VoiceEnrollment
    private let voiceIsolator: VoiceIsolator?
    private let pasteboard: NSPasteboard
    private let systemPaste: SystemPaste
    private let activate: () -> Void
    private let permissions: DictationPermissions
    private let makeMonitor: (DictationKeyInput) -> DictationKeyMonitor
    private let keyScheduler: any SchedulerType
    private let replyToQuit: (Bool) -> Void
    private lazy var input = DictationKeyInput(scheduler: keyScheduler, canConfirm: { [weak self] in self?.flow.canInsert == true },
        recordingShortcut: { [weak self] shortcut in
            guard let self else { return false }
            switch shortcut {
            case .edit: return flow.requestRecordingEdit()
            case .cancel: return flow.cancelHeldRecording()
            }
        },
        action: { [weak self] event in self?.receive(event) })
    private var monitor: DictationKeyMonitor?
    private var availability = DictationAvailability()
    private var deferredAccessibility = false
    private var needsAccessibilityGuide: Bool { !availability.canInsert && !deferredAccessibility }
    private var microphoneAuthorization: MicrophoneCapture.Authorization
    private var microphoneRequest: Task<Void, Never>?
    private var activationObservation: (any NSObjectProtocol)?
    private var menuItem: NSStatusItem?
    private var voicePreparation: Task<Void, Never>?
    #if DEBUG
    private let debugContextLog = DebugContextLog()
    private lazy var debugContextWindow = DebugContextLogWindow(log: debugContextLog)
    #endif

    init(root: URL, defaults: UserDefaults = .standard, pasteboard: NSPasteboard = .general,
         recognizer: ((DictationSettings) -> any SpeechRecognizer)? = nil,
         capture: @escaping () -> any AudioCapturing = { MicrophoneCapture() },
         insertion: CaretInsertion? = nil,
         activate: @escaping () -> Void = { NSApp.activate() },
         permissions: DictationPermissions = .init(),
         downloadDirectory: URL? = nil,
         downloadModel: @escaping ModelDownloads.Download = ModelDownloads.fetch,
         voiceSampleDirectory: URL? = nil,
         voiceSamplePlayer: any VoiceSamplePlaying = VoiceSamplePlayback(),
         keyScheduler: any SchedulerType = MainScheduler.instance,
         makeMonitor: ((DictationKeyInput) -> DictationKeyMonitor)? = nil,
         replyToQuit: @escaping (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }) {
        self.defaults = defaults
        self.pasteboard = pasteboard
        self.activate = activate
        self.permissions = permissions
        microphoneAuthorization = permissions.microphoneAuthorization()
        self.keyScheduler = keyScheduler
        self.makeMonitor = makeMonitor ?? { DictationKeyMonitor(input: $0, isTrusted: permissions.isTrusted,
                                                                 filterGlobal: DictationEventTap.install) }
        self.replyToQuit = replyToQuit
        let selected = DictationSettings(defaults: defaults)
        let models = LocalModels(root: root, downloadDirectory: downloadDirectory)
        self.models = models
        modelPreparation = models.downloads.map { ModelPreparation(downloads: $0, download: downloadModel) }
        let directory = voiceSampleDirectory ?? Self.voiceSampleDirectory
        let store = VoiceSampleStore(directory: directory)
        enrollment = VoiceEnrollment(store: store, makeCapture: capture, player: voiceSamplePlayer)
        let voiceIsolator = models.voiceIsolator()
        self.voiceIsolator = voiceIsolator
        let systemPaste = SystemPaste(board: pasteboard)
        self.systemPaste = systemPaste
        flow = VoxloomFlow(settings: selected, capture: capture,
            recognizer: recognizer ?? models.recognizer, corrector: models.corrector,
            insertion: insertion ?? CaretInsertion(foregroundTarget: SystemPaste.foregroundTarget,
                canPost: { permissions.canInsert }, paste: systemPaste.paste, captureFocus: SystemTextInput.captureFocus),
            readContext: { settings in
                guard permissions.isTrusted() else { return nil }
                return SystemTextInput.contextReader(includeDraft: settings.usesInputContext,
                                                     includeConversation: settings.usesConversationContext)
            },
            prepareVoiceIsolation: {
                guard let voiceIsolator else { throw VoiceIsolationSetupError.unavailable }
                guard models.downloads?.isInstalled("voiceIsolation") != false else {
                    throw VoiceIsolationSetupError.unavailable
                }
                let references = try VoiceSampleKind.allCases.compactMap { try store.read($0) }
                guard !references.isEmpty else { throw VoiceIsolationSetupError.missingSamples }
                let session = UUID()
                return VoiceIsolationPreparation(
                    preview: { audio in try await voiceIsolator.preview(audio, references: references, session: session) },
                    final: { audio in try await voiceIsolator.isolate(audio, references: references) })
            },
            recognitionAvailable: { models.canRecognize($0.model) })
        settingsWindow = SettingsWindow(settings: selected, hasModelDownloads: modelPreparation != nil)
        super.init()
        #if DEBUG
        flow.debugContextLog = debugContextLog
        #endif
    }

    private static var applicationSupport: URL {
        let manager = FileManager.default
        return manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    fileprivate static var modelDirectory: URL {
        applicationSupport.appending(path: "dev.voxloom.app/Models", directoryHint: .isDirectory)
    }

    private static var voiceSampleDirectory: URL {
        applicationSupport.appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.voxloom.app")
            .appendingPathComponent("Voice Samples", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        let monitor = makeMonitor(input)
        self.monitor = monitor
        monitor.setTrigger(flow.settings.trigger)
        monitor.start()
        activationObservation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshKeyboardMonitoring() }
        }
        connectViews()
        prepareSelectedModels()
        flow.prepareForFirstRecording()
        prepareVoiceIsolationIfEnabled()
    }

    func connectViews() {
        wireControls()
        refreshPermissions()
        showOverlay()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshKeyboardMonitoring()
    }

    func applicationDidResignActive(_ notification: Notification) {
        if monitor?.isGlobal != true { input.interrupt() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showOverlay()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await stop()
            replyToQuit(true)
        }
        return .terminateLater
    }

    func stop() async {
        enrollment.cancel()
        settingsWindow.stopTriggerCapture()
        microphoneRequest?.cancel()
        microphoneRequest = nil
        voicePreparation?.cancel()
        if let activationObservation { NSWorkspace.shared.notificationCenter.removeObserver(activationObservation) }
        activationObservation = nil
        monitor?.stop()
        monitor = nil
        if let menuItem { NSStatusBar.system.removeStatusItem(menuItem) }
        menuItem = nil
        systemPaste.restoreClipboard()
        await modelPreparation?.stop()
        await flow.shutdown()
        await voiceIsolator?.shutdown()
        await voicePreparation?.value
        #if DEBUG
        debugContextLog.clear()
        #endif
    }

    private func wireControls() {
        for (control, selector) in [
            (overlay.settings, #selector(showSettings)),
            (overlay.enableAccessibility, #selector(enableAccessibility)),
            (overlay.deferAccessibility, #selector(deferAccessibility)),
            (overlay.enableMicrophone, #selector(enableMicrophone)), (overlay.retryModelDownload, #selector(retryASR)),
            (overlay.insert, #selector(insertDraft)), (overlay.clear, #selector(clearDraft)),
            (overlay.copy, #selector(copyDraft)), (settingsWindow.enableAccessibility, #selector(enableAccessibility))
        ] {
            control.target = self
            control.action = selector
        }
        flow.onChange = { [weak self] in self?.renderOverlay() }
        flow.onOpenDraft = { [weak overlay] in overlay?.showDraftEditor() }
        overlay.onEdit = { [weak flow] text, visible, range in flow?.edit(text, basedOn: visible, replacedRange: range) }
        settingsWindow.onChange = { [weak self] value in
            guard let self else { return }
            let previous = flow.settings
            value.save(to: defaults)
            if previous.trigger != value.trigger { monitor?.setTrigger(value.trigger) }
            flow.apply(value)
            if previous.model != value.model { modelPreparation?.cancel(previous.model.rawValue) }
            if !value.correctsText { modelPreparation?.cancel("correction") }
            if !value.usesVoiceIsolation { modelPreparation?.cancel("voiceIsolation") }
            prepareSelectedModels()
            if value.usesVoiceIsolation && !previous.usesVoiceIsolation { prepareVoiceIsolationIfEnabled() }
            refreshVoiceEnrollment()
            if previous.trigger != value.trigger { refreshKeyboardMonitoring() }
        }
        settingsWindow.onTriggerCapture = { [weak self] capturing in self?.monitor?.setSelectingTrigger(capturing) }
        settingsWindow.onRetryModel = { [weak self] model in self?.modelPreparation?.prepare(model, retry: true) }
        modelPreparation?.onChange = { [weak self] model in self?.modelDownloadChanged(model) }
        settingsWindow.onRecordVoice = { [weak self] kind in
            guard let self else { return }
            guard flow.canStart else { enrollment.showNotice("请先结束听写，再录语音样本"); return }
            enrollment.toggle(kind)
        }
        settingsWindow.onPlayVoice = { [weak self] kind in
            guard let self else { return }
            guard flow.canStart else { enrollment.showNotice("请先结束听写，再试听语音样本"); return }
            enrollment.togglePlayback(kind)
        }
        settingsWindow.onRemoveVoice = { [weak enrollment] kind in enrollment?.remove(kind) }
        settingsWindow.onClose = { [weak enrollment] in enrollment?.cancel() }
        enrollment.onChange = { [weak self] in self?.refreshVoiceEnrollment() }
        refreshVoiceEnrollment()
    }

    private func refreshVoiceEnrollment() {
        settingsWindow.updateVoiceEnrollment(enrollment, modelAvailable: voiceIsolator != nil)
    }

    private func prepareSelectedModels() {
        guard let modelPreparation else { return }
        let settings = flow.settings
        modelPreparation.prepare(settings.model.rawValue)
        if settings.correctsText { modelPreparation.prepare("correction") }
        if settings.usesVoiceIsolation, voiceIsolator != nil { modelPreparation.prepare("voiceIsolation") }
        settingsWindow.updateModelDownloads(modelPreparation, settings: settings)
    }

    private func modelDownloadChanged(_ model: String) {
        guard let modelPreparation else { return }
        let settings = flow.settings
        settingsWindow.updateModelDownloads(modelPreparation, settings: settings)
        guard modelPreparation.status(for: model) == .ready else {
            if model == settings.model.rawValue { renderOverlay() }
            return
        }
        if model == settings.model.rawValue {
            flow.showNotice("转写模型已就绪")
            flow.prepareForFirstRecording()
        }
        if model == "voiceIsolation" { prepareVoiceIsolationIfEnabled() }
    }

    private func prepareVoiceIsolationIfEnabled() {
        guard flow.settings.usesVoiceIsolation, let voiceIsolator, voicePreparation == nil,
              models.downloads?.isInstalled("voiceIsolation") != false else { return }
        voicePreparation = Task(priority: .utility) { [weak self] in
            await voiceIsolator.prepare()
            self?.voicePreparation = nil
        }
    }

    private func makeMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let name = VoxloomIdentity.displayName()
        item.button?.image = VoxloomIdentity.menuBarIcon()
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: name)
        item.button?.setAccessibilityLabel(name)
        item.button?.toolTip = name
        let menu = NSMenu()
        for (title, action, key) in [
            ("显示语音条", #selector(showOverlay), ""), ("设置…", #selector(showSettings), ","),
            ("退出 \(name)", #selector(quit), "q")
        ] {
            let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            entry.target = self
        }
        #if DEBUG
        let context = NSMenuItem(title: "ASR 上下文日志…", action: #selector(showContextLog), keyEquivalent: "")
        context.target = self
        menu.insertItem(context, at: 2)
        #endif
        item.menu = menu
        menuItem = item
    }

    private func refreshKeyboardMonitoring() {
        monitor?.refresh()
        refreshPermissions()
    }

    private func refreshPermissions() {
        availability = DictationAvailability(globalShortcut: monitor?.isGlobal == true, canInsert: permissions.canInsert)
        microphoneAuthorization = permissions.microphoneAuthorization()
        renderOverlay()
        settingsWindow.updatePermissions(availability)
    }

    private func renderOverlay() {
        let setup: VoiceBarSetup?
        if needsAccessibilityGuide, flow.canStart {
            setup = .accessibility
        } else if microphoneRequest != nil {
            setup = .requestingMicrophone
        } else if microphoneAuthorization != .authorized {
            setup = .microphone(microphoneAuthorization)
        } else if let status = modelPreparation?.status(for: flow.settings.model.rawValue), status != .ready {
            setup = .model(status)
        } else {
            setup = nil
        }
        overlay.render(flow, availability: availability, setup: setup)
    }

    private func receive(_ event: FunctionKeyGesture.Action) {
        if event == .start {
            guard enrollment.active == nil else { return }
            refreshPermissions()
            guard !needsAccessibilityGuide, microphoneAuthorization == .authorized else {
                overlay.show(in: NSScreen.main?.visibleFrame)
                return
            }
            if flow.canStart { enrollment.stopPlayback() }
        }
        if event == .confirm || (event == .start && flow.canStart) { overlay.finishKeyboardEdit() }
        flow.handle(event)
        if event == .start { overlay.show(in: NSScreen.main?.visibleFrame) }
    }

    @objc func showOverlay() { overlay.show() }

    @objc func showSettings() {
        refreshKeyboardMonitoring()
        settingsWindow.window?.makeKeyAndOrderFront(nil)
        activate()
    }

    #if DEBUG
    @objc func showContextLog() {
        debugContextWindow.showWindow(nil)
        debugContextWindow.window?.makeKeyAndOrderFront(nil)
        activate()
    }
    #endif

    @objc private func insertDraft() { receive(.confirm) }
    @objc private func clearDraft() { flow.clearOrCancel() }

    @objc private func copyDraft() {
        overlay.finishKeyboardEdit()
        guard let text = flow.state?.text, !text.isEmpty else { return }
        pasteboard.clearContents()
        if pasteboard.setString(text, forType: .string) { flow.showNotice("已复制草稿") }
    }

    @objc private func enableAccessibility() {
        permissions.requestAccess()
        refreshKeyboardMonitoring()
    }

    @objc private func deferAccessibility() {
        deferredAccessibility = true
        renderOverlay()
    }

    @objc private func enableMicrophone() {
        guard microphoneRequest == nil else { return }
        refreshPermissions()
        guard !needsAccessibilityGuide else { return }
        switch microphoneAuthorization {
        case .notDetermined:
            microphoneRequest = Task { [weak self, request = permissions.requestMicrophone] in
                _ = await request()
                guard !Task.isCancelled, let self else { return }
                microphoneRequest = nil
                refreshPermissions()
            }
            renderOverlay()
        case .denied: permissions.openMicrophoneSettings()
        case .restricted, .authorized: break
        }
    }

    @objc private func retryASR() {
        modelPreparation?.prepare(flow.settings.model.rawValue, retry: true)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
