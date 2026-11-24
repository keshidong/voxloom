import AppKit
import Carbon
import SpeechFoundation

@MainActor final class SettingsWindow: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    let recognition = NSPopUpButton()
    let correction = NSPopUpButton()
    let language = NSPopUpButton()
    let vocabulary = NSTextField()
    let gpu = NSButton(checkboxWithTitle: "使用 GPU 加速 Whisper 和 Qwen3-4B", target: nil, action: nil)
    let voiceIsolation = NSButton(checkboxWithTitle: "只保留我的声音（实验）", target: nil, action: nil)
    let enableAccessibility = NSButton(title: "启用辅助功能", target: nil, action: nil)
    private let changeTrigger = NSButton(title: "更改…", target: nil, action: nil)
    private let resetTrigger = NSButton(title: "恢复 Fn", target: nil, action: nil)
    private let triggerLabel = NSTextField(labelWithString: "")
    private var trigger: DictationTrigger = .fn
    private var triggerCapture = DictationTrigger.Capture()
    private var triggerMonitor: Any?
    private let permissionStatus = NSTextField(labelWithString: "")
    private let voiceStatus = NSTextField(labelWithString: "")
    private let recognitionDownload = ModelDownloadRow()
    private let correctionDownload = ModelDownloadRow()
    private let isolationDownload = ModelDownloadRow()
    private var voiceRows: [(kind: VoiceSampleKind, label: NSTextField, record: NSButton,
                             play: NSButton, remove: NSButton)] = []
    var onChange: ((DictationSettings) -> Void)?
    var onRecordVoice: ((VoiceSampleKind) -> Void)?
    var onPlayVoice: ((VoiceSampleKind) -> Void)?
    var onRemoveVoice: ((VoiceSampleKind) -> Void)?
    var onClose: (() -> Void)?
    var onRetryModel: ((String) -> Void)?
    var onTriggerCapture: ((Bool) -> Void)?

    init(settings: DictationSettings, hasModelDownloads: Bool = false) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: hasModelDownloads ? 790 : 690),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "\(VoxloomIdentity.displayName()) 设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        build()
        load(settings)
    }

    required init?(coder: NSCoder) { nil }

    func updatePermissions(_ availability: DictationAvailability) {
        permissionStatus.stringValue = switch (availability.globalShortcut, availability.canInsert) {
        case (true, true): "全局快捷键和自动插入已启用"
        case (false, true): "全局快捷键暂不可用"
        case (_, false): "在系统设置的「辅助功能」中允许 \(VoxloomIdentity.displayName())"
        }
        enableAccessibility.isEnabled = !availability.canInsert
    }

    private func build() {
        let heading = NSTextField(labelWithString: "识别与纠错")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let hint = NSTextField(labelWithString: "模型与词汇设置在下一次录音时生效。")
        hint.textColor = .secondaryLabelColor
        recognition.addItems(withTitles: RecognitionModel.allCases.map(\.title))
        correction.addItems(withTitles: ["Qwen3-4B Instruct", "关闭纠错"])
        language.addItems(withTitles: ["自动", "中文", "English"])
        vocabulary.placeholderString = "术语、人名或产品名"
        vocabulary.delegate = self
        for (control, label) in [(recognition, "转写模型"), (correction, "纠错模型"),
                                  (language, "语言"), (vocabulary, "词汇提示")] {
            control.setAccessibilityLabel(label)
        }
        for control in [recognition, correction, language, gpu, voiceIsolation] {
            control.target = self
            control.action = #selector(changed)
        }
        let models = NSGridView(views: [
            [NSTextField(labelWithString: "转写模型"), recognition],
            [NSTextField(labelWithString: "纠错模型"), correction],
            [NSTextField(labelWithString: "语言"), language],
            [NSTextField(labelWithString: "词汇提示"), vocabulary]
        ])
        models.columnSpacing = 18
        models.rowSpacing = 9
        models.column(at: 0).xPlacement = .trailing
        models.column(at: 1).xPlacement = .fill
        vocabulary.widthAnchor.constraint(greaterThanOrEqualToConstant: 236).isActive = true
        let permissionHeading = NSTextField(labelWithString: "快捷键与插入")
        permissionHeading.font = .systemFont(ofSize: 17, weight: .semibold)
        changeTrigger.target = self
        changeTrigger.action = #selector(beginTriggerCapture)
        changeTrigger.setAccessibilityLabel("更改按住说话键")
        resetTrigger.target = self
        resetTrigger.action = #selector(useFunctionKey)
        let keyboard = NSStackView(views: [NSTextField(labelWithString: "按住说话键"),
                                           triggerLabel, changeTrigger, resetTrigger])
        keyboard.alignment = .centerY
        keyboard.spacing = 8
        permissionStatus.textColor = .secondaryLabelColor
        let permissions = NSStackView(views: [enableAccessibility, permissionStatus])
        permissions.alignment = .centerY
        permissions.spacing = 10
        let separator = NSBox()
        separator.boxType = .separator
        let voiceSection = makeVoiceSection()
        let stack = NSStackView(views: [heading, hint, models, recognitionDownload, correctionDownload,
                                       gpu,
                                       separator, voiceSection, permissionHeading, keyboard, permissions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window!.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            voiceSection.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func makeVoiceSection() -> NSView {
        let heading = NSTextField(labelWithString: "人声分离")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        let prompt = NSTextField(labelWithString: "录制时可以读这句")
        prompt.textColor = .secondaryLabelColor
        let example = NSTextField(wrappingLabelWithString: "今天我想试试语音输入。Can you hear me clearly?")
        voiceStatus.textColor = .secondaryLabelColor
        voiceRows = VoiceSampleKind.allCases.enumerated().map { index, kind in
            let label = NSTextField(labelWithString: kind.label)
            let record = NSButton(title: "录制", target: self, action: #selector(recordVoice(_:)))
            let play = NSButton(title: "试听", target: self, action: #selector(playVoice(_:)))
            let remove = NSButton(title: "删除", target: self, action: #selector(removeVoice(_:)))
            record.tag = index
            play.tag = index
            remove.tag = index
            record.setAccessibilityLabel("录制\(kind.label)样本")
            remove.setAccessibilityLabel("删除\(kind.label)样本")
            return (kind, label, record, play, remove)
        }
        let rows = NSGridView(views: voiceRows.map { [$0.label, $0.record, $0.play, $0.remove] })
        rows.rowSpacing = 4
        rows.columnSpacing = 12
        let section = NSStackView(views: [heading, voiceIsolation, isolationDownload, prompt, example, rows, voiceStatus])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        example.widthAnchor.constraint(lessThanOrEqualTo: section.widthAnchor).isActive = true
        return section
    }

    func updateModelDownloads(_ setup: ModelPreparation, settings: DictationSettings) {
        let model = settings.model
        recognitionDownload.render(model.title, status: setup.status(for: model.rawValue))
        correctionDownload.render("Qwen3-4B Instruct", status: settings.correctsText ? setup.status(for: "correction") : nil)
        isolationDownload.render("人声分离模型", status: settings.usesVoiceIsolation ? setup.status(for: "voiceIsolation") : nil)
        recognitionDownload.onRetry = { [weak self] in self?.onRetryModel?(model.rawValue) }
        correctionDownload.onRetry = { [weak self] in self?.onRetryModel?("correction") }
        isolationDownload.onRetry = { [weak self] in self?.onRetryModel?("voiceIsolation") }
    }

    func updateVoiceEnrollment(_ enrollment: VoiceEnrollment, modelAvailable: Bool) {
        voiceIsolation.isEnabled = modelAvailable || voiceIsolation.state == .on
        voiceStatus.stringValue = enrollment.notice ?? (modelAvailable
            ? "每段录 3～8 秒。样本保存在本机。"
            : "此安装包未包含人声分离模型")
        for row in voiceRows {
            let saved = enrollment.store.contains(row.kind)
            let active = enrollment.active == row.kind
            let playing = enrollment.playing == row.kind
            row.label.stringValue = row.kind.label + (saved ? " · 已录" : "")
            row.record.title = active ? (enrollment.isRecording ? "保存" : "取消") : (saved ? "重录" : "录制")
            row.record.isEnabled = active || enrollment.active == nil
            row.play.title = playing ? "停止" : "试听"
            row.play.setAccessibilityLabel((playing ? "停止试听" : "试听") + row.kind.label + "样本")
            row.play.isEnabled = saved && enrollment.active == nil
            row.remove.isEnabled = saved && enrollment.active == nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopTriggerCapture()
        onClose?()
    }

    func windowDidResignKey(_ notification: Notification) { stopTriggerCapture() }

    @objc private func beginTriggerCapture() {
        if triggerMonitor != nil { stopTriggerCapture(); return }
        changeTrigger.title = "取消"
        triggerLabel.stringValue = "按下单键或组合键"
        resetTrigger.isEnabled = false
        onTriggerCapture?(true)
        triggerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let captured = MainActor.assumeIsolated { self?.captureTrigger(event) == true }
            return captured ? nil : event
        }
        if triggerMonitor == nil {
            onTriggerCapture?(false)
            refreshTriggerControls()
        }
    }

    private func captureTrigger(_ event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true else { return false }
        if event.type == .keyDown, Int(event.keyCode) == kVK_Escape {
            stopTriggerCapture()
        } else if let captured = triggerCapture.receive(event) {
            trigger = captured
            stopTriggerCapture()
            changed()
        } else if event.type == .keyDown, !event.isARepeat {
            triggerLabel.stringValue = "请试另一个快捷键"
        }
        return true
    }

    func stopTriggerCapture() {
        guard let triggerMonitor else { return }
        NSEvent.removeMonitor(triggerMonitor)
        self.triggerMonitor = nil
        triggerCapture = .init()
        onTriggerCapture?(false)
        refreshTriggerControls()
    }

    @objc private func useFunctionKey() {
        trigger = .fn
        refreshTriggerControls()
        changed()
    }

    private func refreshTriggerControls() {
        triggerLabel.stringValue = trigger.name
        changeTrigger.title = "更改…"
        triggerLabel.toolTip = "按住 \(trigger.name) 时听写"
        resetTrigger.isEnabled = trigger != .fn
    }
    @objc private func recordVoice(_ sender: NSButton) { onRecordVoice?(VoiceSampleKind.allCases[sender.tag]) }
    @objc private func playVoice(_ sender: NSButton) { onPlayVoice?(VoiceSampleKind.allCases[sender.tag]) }
    @objc private func removeVoice(_ sender: NSButton) { onRemoveVoice?(VoiceSampleKind.allCases[sender.tag]) }

    private func load(_ settings: DictationSettings) {
        trigger = settings.trigger
        refreshTriggerControls()
        recognition.selectItem(at: RecognitionModel.allCases.firstIndex(of: settings.model) ?? 0)
        correction.selectItem(at: settings.correctsText ? 0 : 1)
        language.selectItem(at: RecognitionLanguage.allCases.firstIndex(of: settings.language) ?? 0)
        vocabulary.stringValue = settings.vocabulary
        gpu.state = settings.usesGPU ? .on : .off
        voiceIsolation.state = settings.usesVoiceIsolation ? .on : .off
    }

    func controlTextDidChange(_ notification: Notification) { changed() }

    @objc private func changed() {
        guard recognition.indexOfSelectedItem >= 0, language.indexOfSelectedItem >= 0 else { return }
        var selected = DictationSettings()
        selected.trigger = trigger
        selected.model = RecognitionModel.allCases[recognition.indexOfSelectedItem]
        selected.language = RecognitionLanguage.allCases[language.indexOfSelectedItem]
        selected.correctsText = correction.indexOfSelectedItem == 0
        selected.vocabulary = String(vocabulary.stringValue.prefix(240))
        selected.usesGPU = gpu.state == .on
        selected.usesVoiceIsolation = voiceIsolation.state == .on
        onChange?(selected)
    }
}
