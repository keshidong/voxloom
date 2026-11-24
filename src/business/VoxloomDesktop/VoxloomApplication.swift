import AppKit
import RxSwift
import SpeechInput
import SpeechFoundation

@MainActor public enum VoxloomApplication {
    public static func run() {
        let app = NSApplication.shared
        let coordinator = VoxloomCoordinator(root: Bundle.main.resourceURL ?? Bundle.main.bundleURL)
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
    private var activationObservation: (any NSObjectProtocol)?
    private var menuItem: NSStatusItem?
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
         keyScheduler: any SchedulerType = MainScheduler.instance,
         makeMonitor: ((DictationKeyInput) -> DictationKeyMonitor)? = nil,
         replyToQuit: @escaping (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }) {
        self.defaults = defaults
        self.pasteboard = pasteboard
        self.activate = activate
        self.permissions = permissions
        self.keyScheduler = keyScheduler
        self.makeMonitor = makeMonitor ?? { DictationKeyMonitor(input: $0, isTrusted: permissions.isTrusted,
                                                                 filterGlobal: DictationEventTap.install) }
        self.replyToQuit = replyToQuit
        let selected = DictationSettings(defaults: defaults)
        let models = LocalModels(root: root)
        self.models = models
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
            })
        settingsWindow = SettingsWindow(settings: selected)
        super.init()
        #if DEBUG
        flow.debugContextLog = debugContextLog
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        let monitor = makeMonitor(input)
        self.monitor = monitor
        monitor.start()
        activationObservation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshKeyboardMonitoring() }
        }
        connectViews()
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
        if let activationObservation { NSWorkspace.shared.notificationCenter.removeObserver(activationObservation) }
        activationObservation = nil
        monitor?.stop()
        monitor = nil
        if let menuItem { NSStatusBar.system.removeStatusItem(menuItem) }
        menuItem = nil
        systemPaste.restoreClipboard()
        await flow.shutdown()
        #if DEBUG
        debugContextLog.clear()
        #endif
    }

    private func wireControls() {
        for (control, selector) in [
            (overlay.settings, #selector(showSettings)), (overlay.sample, #selector(runSample)),
            (overlay.enableAccessibility, #selector(enableAccessibility)),
            (overlay.insert, #selector(insertDraft)), (overlay.clear, #selector(clearDraft)),
            (overlay.copy, #selector(copyDraft)), (settingsWindow.enableAccessibility, #selector(enableAccessibility))
        ] {
            control.target = self
            control.action = selector
        }
        flow.onChange = { [weak self] in
            if let self { overlay.render(flow, availability: availability) }
        }
        flow.onOpenDraft = { [weak overlay] in overlay?.showDraftEditor() }
        overlay.onEdit = { [weak flow] text, visible, range in flow?.edit(text, basedOn: visible, replacedRange: range) }
        settingsWindow.onChange = { [weak self] value in
            guard let self else { return }
            value.save(to: defaults)
            flow.apply(value)
        }
    }

    private func makeMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voxloom")
        item.button?.toolTip = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Voxloom"
        let menu = NSMenu()
        for (title, action, key) in [
            ("显示语音条", #selector(showOverlay), ""), ("设置…", #selector(showSettings), ","),
            ("退出 Voxloom", #selector(quit), "q")
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
        overlay.render(flow, availability: availability)
        settingsWindow.updatePermissions(availability)
    }

    private func receive(_ event: FunctionKeyGesture.Action) {
        if event == .confirm || (event == .start && flow.canStart) { overlay.finishKeyboardEdit() }
        flow.handle(event)
        if event == .start { showOverlay() }
    }

    @objc func showOverlay() { overlay.panel.orderFrontRegardless() }

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

    @objc private func runSample() {
        do { flow.trySample(try models.sample(for: flow.settings)) }
        catch { flow.showNotice("示例音频不可用") }
    }

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

    @objc private func quit() { NSApp.terminate(nil) }
}
