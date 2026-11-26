import AppKit
import Carbon
import SpeechFoundation
import SpeechInput

@MainActor final class VoxloomPanel: NSPanel {
    static let width: CGFloat = 380
    private let allowsKeyboardFocus: Bool

    init(height: CGFloat = 56, allowsKeyboardFocus: Bool = false) {
        self.allowsKeyboardFocus = allowsKeyboardFocus
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: height),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = VoxloomIdentity.displayName()
        appearance = NSAppearance(named: .darkAqua)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = !allowsKeyboardFocus
        if !allowsKeyboardFocus, let visible = NSScreen.main?.visibleFrame { place(in: visible) }
    }

    func showOnActiveDisplay(in visibleFrame: NSRect? = nil) {
        let pointer = NSEvent.mouseLocation
        let display = NSScreen.screens.first { $0.frame.contains(pointer) } ?? screen ?? NSScreen.main
        if let visible = visibleFrame ?? display?.visibleFrame, !visible.contains(frame) {
            place(in: visible)
        }
        orderFrontRegardless()
    }

    private func place(in visible: NSRect) {
        let inset = min(22, max(0, visible.height - frame.height))
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + inset))
    }

    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override var canBecomeMain: Bool { false }
}

enum VoiceBarSetup {
    case accessibility
    case microphone(MicrophoneCapture.Authorization)
    case requestingMicrophone
    case model(ModelDownloadStatus)
}

@MainActor final class VoxloomOverlay: NSWindowController, NSTextViewDelegate, NSWindowDelegate {
    private static let draftHeight: CGFloat = 156
    private static let editorPanelHeight: CGFloat = draftHeight + 24
    private static let previewPanelHeight: CGFloat = 38
    let panel = VoxloomPanel()
    private let textPanel = VoxloomPanel(height: editorPanelHeight, allowsKeyboardFocus: true)
    private let barSurface = VoiceBarSurface()
    private let textSurface = VoiceBarSurface()
    let holdToTalk = HoldToTalkButton()
    let settings = NSButton(title: "设置", target: nil, action: nil)
    let enableAccessibility = NSButton(title: "启用辅助功能", target: nil, action: nil)
    let deferAccessibility = NSButton(title: "稍后", target: nil, action: nil)
    let enableMicrophone = NSButton(title: "授权麦克风", target: nil, action: nil)
    let retryModelDownload = NSButton(title: "重试下载", target: nil, action: nil)
    let downloadProgress = NSProgressIndicator()
    let insert = NSButton(title: "插入 ↵", target: nil, action: nil)
    let copy = NSButton(title: "复制", target: nil, action: nil)
    let clear = NSButton(title: "清空", target: nil, action: nil)
    var onEdit: ((String, String, NSRange?) -> Void)?
    let editor = PanelEditor()
    let status = NSTextField(wrappingLabelWithString: "")
    private let draftToggle = NSButton(title: "展开", target: nil, action: nil)
    private let draftBody = NSStackView()
    private let preview = LivePreviewLabel(labelWithString: "")
    private let waveform = VoiceWaveformView()
    private let sentIcon = NSImageView()
    private let meter = NSLevelIndicator()
    private let progress = NSProgressIndicator()
    private let placeholder = NSTextField(labelWithString: "转写会出现在这里")
    private var presented = ""
    private var keyboardRange: NSRange?
    private var openedByShortcut = false

    init() {
        super.init(window: panel)
        build()
        panel.delegate = self
        textPanel.animationBehavior = .none
        textPanel.hasShadow = false
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        let bar = makeBar()
        panel.contentView = barSurface
        add(bar, to: barSurface, height: 28)

        buildDraft()
        preview.font = .systemFont(ofSize: 15)
        preview.maximumNumberOfLines = 1
        preview.lineBreakMode = .byTruncatingHead
        preview.setAccessibilityLabel("实时草稿")
        preview.isHidden = true
        draftBody.isHidden = true
        textPanel.contentView = textSurface
        add(draftBody, to: textSurface, height: Self.draftHeight)
        add(preview, to: textSurface, height: 22)
    }

    private func add(_ row: NSView, to surface: NSView, height: CGFloat) {
        row.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: height)
        ])
    }

    private func makeBar() -> NSStackView {
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "隐藏悬浮窗口") ?? NSImage(),
                             target: self, action: #selector(hide))
        close.isBordered = false
        close.setAccessibilityLabel("隐藏悬浮窗口")
        close.toolTip = "隐藏悬浮窗口"
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")
        settings.imagePosition = .imageOnly
        settings.isBordered = false
        settings.toolTip = "设置"
        settings.setAccessibilityLabel("设置")
        draftToggle.bezelStyle = .rounded
        draftToggle.target = self
        draftToggle.action = #selector(toggleDraft)
        draftToggle.setAccessibilityLabel("展开草稿")
        enableAccessibility.bezelStyle = .rounded
        enableAccessibility.contentTintColor = .systemMint
        deferAccessibility.bezelStyle = .rounded
        deferAccessibility.isHidden = true
        enableMicrophone.bezelStyle = .rounded
        enableMicrophone.contentTintColor = .systemMint
        enableMicrophone.isHidden = true
        retryModelDownload.bezelStyle = .rounded
        retryModelDownload.isHidden = true
        downloadProgress.style = .bar
        downloadProgress.controlSize = .small
        downloadProgress.maxValue = 100
        downloadProgress.isHidden = true
        downloadProgress.widthAnchor.constraint(equalToConstant: 64).isActive = true
        downloadProgress.setAccessibilityLabel("ASR 模型下载进度")
        status.font = .systemFont(ofSize: 13, weight: .medium)
        status.maximumNumberOfLines = 1
        status.lineBreakMode = .byTruncatingTail
        status.setAccessibilityLabel("录音状态")
        meter.minValue = 0
        meter.maxValue = 1
        meter.levelIndicatorStyle = .continuousCapacity
        meter.widthAnchor.constraint(equalToConstant: 48).isActive = true
        meter.setAccessibilityLabel("麦克风音量")
        meter.isHidden = true
        progress.style = .spinning
        progress.controlSize = .small
        progress.isHidden = true
        progress.setAccessibilityLabel("转写进度")
        sentIcon.image = VoxloomIdentity.brandWaveform()
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        sentIcon.contentTintColor = .systemMint
        sentIcon.imageScaling = .scaleProportionallyUpOrDown
        sentIcon.isHidden = true
        NSLayoutConstraint.activate([
            sentIcon.widthAnchor.constraint(equalToConstant: VoiceWaveformView.size.width),
            sentIcon.heightAnchor.constraint(equalToConstant: VoiceWaveformView.size.height)
        ])
        for icon in [waveform, sentIcon] {
            icon.translatesAutoresizingMaskIntoConstraints = false
            holdToTalk.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: holdToTalk.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: holdToTalk.centerYAnchor)
            ])
        }
        let bar = NSStackView(views: [holdToTalk, status, meter, progress, downloadProgress, NSView(),
                                     enableMicrophone, retryModelDownload, enableAccessibility, deferAccessibility,
                                     draftToggle, settings, close])
        bar.alignment = .centerY
        bar.spacing = 8
        return bar
    }

    private func buildDraft() {
        for button in [insert, copy, clear] {
            button.bezelStyle = .rounded
        }
        insert.bezelColor = .systemMint
        insert.contentTintColor = .black
        insert.setAccessibilityLabel("插入")
        insert.toolTip = "Enter 插入到目标光标或替换所选文字，Shift+Enter 换行"
        let footer = NSStackView(views: [NSView(), clear, copy, insert])
        draftBody.orientation = .vertical
        draftBody.alignment = .leading
        draftBody.spacing = 8
        for row in [makePaper(), footer] {
            draftBody.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: draftBody.widthAnchor).isActive = true
        }
    }

    private func makePaper() -> NSView {
        editor.font = .systemFont(ofSize: 16)
        editor.isRichText = false
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 10, height: 8)
        editor.setAccessibilityLabel("语音草稿")
        editor.delegate = self
        editor.onSubmit = { [weak self] in
            guard let self, insert.isEnabled else { return false }
            return insert.sendAction(insert.action, to: insert.target)
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.documentView = editor
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 9
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let paper = NSView()
        paper.addSubview(scroll)
        placeholder.font = .systemFont(ofSize: 14)
        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        paper.addSubview(placeholder)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: paper.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: paper.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: paper.bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 15),
            placeholder.topAnchor.constraint(equalTo: paper.topAnchor, constant: 10),
            paper.heightAnchor.constraint(greaterThanOrEqualToConstant: 92)
        ])
        return paper
    }

    func show(in visibleFrame: NSRect? = nil) {
        panel.showOnActiveDisplay(in: visibleFrame)
        layoutTextPanel()
    }

    @objc private func hide() {
        holdToTalk.cancelPress()
        textPanel.orderOut(nil)
        panel.orderOut(nil)
    }

    @objc private func toggleDraft() {
        let show = draftBody.isHidden
        if !show { finishKeyboardEdit() }
        setDraftVisible(show)
        if show, editor.isEditable { focusEditor() }
    }

    func showDraftEditor() {
        if !panel.isVisible { show() }
        openedByShortcut = true
        setDraftVisible(true)
        focusEditor()
    }

    private func focusEditor() {
        textPanel.makeFirstResponder(editor)
        textPanel.makeKey()
    }

    private func setDraftVisible(_ show: Bool) {
        if !show {
            openedByShortcut = false
            textPanel.makeFirstResponder(nil)
            if textPanel.isKeyWindow { textPanel.orderOut(nil) }
        }
        draftBody.isHidden = !show
        draftToggle.title = show ? "收起" : "展开"
        draftToggle.setAccessibilityLabel(show ? "收起草稿" : "展开草稿")
        layoutTextPanel()
    }

    func windowDidMove(_ notification: Notification) {
        if textPanel.parent === panel { layoutTextPanel() }
    }

    private func layoutTextPanel() {
        let expanded = !draftBody.isHidden
        preview.isHidden = expanded || preview.stringValue.isEmpty
        guard panel.isVisible, expanded || !preview.isHidden else {
            if textPanel.isVisible { textPanel.orderOut(nil) }
            barSurface.joinedEdge = nil
            panel.hasShadow = true
            return
        }

        let bar = panel.frame
        let height = expanded ? Self.editorPanelHeight : Self.previewPanelHeight
        let below = bar.minY - height
        let opensBelow = panel.screen.map { screen in
            let bounds = screen.visibleFrame
            return bar.maxY + height > bounds.maxY && below >= bounds.minY
        } ?? false
        let originY = opensBelow ? below : bar.maxY
        barSurface.joinedEdge = opensBelow ? .bottom : .top
        textSurface.joinedEdge = opensBelow ? .top : .bottom
        panel.hasShadow = false
        let frame = NSRect(x: bar.minX, y: originY, width: bar.width, height: height)
        if frame != textPanel.frame { textPanel.setFrame(frame, display: true, animate: false) }
        if textPanel.parent == nil { panel.addChildWindow(textPanel, ordered: .above) }
        if !textPanel.isVisible { textPanel.orderFrontRegardless() }
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if !textView.hasMarkedText(), textView.string == presented {
            keyboardRange = replacementString == nil ? nil : affectedCharRange
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !editor.hasMarkedText() else { return }
        let range = keyboardRange
        keyboardRange = nil
        if editor.string != presented { onEdit?(editor.string, presented, range) }
    }

    func finishKeyboardEdit() {
        if editor.hasMarkedText() { editor.unmarkText() }
        textDidChange(Notification(name: NSText.didChangeNotification))
    }

    func render(_ flow: VoxloomFlow, availability: DictationAvailability, setup: VoiceBarSetup? = nil) {
        let current = flow.state
        let phase = current?.live.phase ?? .idle
        let text = current?.text ?? ""
        let available = !text.isEmpty
        let previewText = flow.didSendInsertion ? "" : text.split(whereSeparator: \.isNewline).joined(separator: " ")
        if preview.stringValue != previewText { preview.stringValue = previewText }
        if openedByShortcut, flow.didSendInsertion { setDraftVisible(false) }
        else { layoutTextPanel() }
        if !editor.hasMarkedText(), presented != text {
            presented = text
            if editor.string != text {
                let selection = DraftSelection.rebase(editor.selectedRange(), from: editor.string, to: text)
                editor.string = text
                editor.setSelectedRange(selection)
            }
        }
        editor.isEditable = current?.phase == .editing
        placeholder.isHidden = available
        let introducingAccessibility = if case .accessibility? = setup { true } else { false }
        enableAccessibility.isHidden = availability.canInsert || phase != .idle || (setup != nil && !introducingAccessibility)
        deferAccessibility.isHidden = !introducingAccessibility
        draftToggle.isHidden = introducingAccessibility && !available && draftBody.isHidden
        let key = flow.settings.trigger.name
        let level = min(1, (current?.live.level ?? 0) * 5)
        meter.isHidden = phase != .recording
        meter.doubleValue = level
        waveform.update(level: phase == .recording ? level : nil)
        let readyHint = availability.globalShortcut ? "按住声波或 \(key) 说话" : "按住左侧声波说话"
        let stateText = switch phase {
        case .authorizing: "等待麦克风授权"
        case .recording: "正在录音  \(Int(current?.live.seconds ?? 0)) 秒"
        case .finishing: "正在整理最后一段"
        case .idle: available ? "草稿已就绪" : readyHint
        }
        let correctionText: String?
        switch current?.correction {
        case .working: correctionText = phase == .idle ? "正在本机纠错" : nil
        case .candidate(let candidate) where candidate.numbersChanged: correctionText = "数字发生变化，请核对草稿"
        case .failed(let message): correctionText = message
        default: correctionText = nil
        }
        let processing = phase == .finishing || (phase == .idle && current?.correction == .working)
        progress.isHidden = !processing
        if processing { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        let editText = flow.editsRecordingOnRelease ? "松开 \(key) 后编辑" : nil
        status.stringValue = renderSetup(setup) ?? flow.notice ?? current?.live.error ?? editText ?? correctionText ?? stateText
        let showsSentIcon = flow.didSendInsertion && status.stringValue == VoxloomFlow.insertionSentNotice
        waveform.isHidden = showsSentIcon
        sentIcon.isHidden = !showsSentIcon
        status.toolTip = status.stringValue
        status.textColor = phase == .recording ? .systemMint : .labelColor
        insert.isEnabled = flow.canInsert
        copy.isEnabled = available
        let readyToClear = flow.canStart
        clear.title = readyToClear ? "清空" : "取消"
        clear.toolTip = readyToClear ? "Esc 清空草稿" : nil
        clear.isEnabled = available || !readyToClear
    }

    private func renderSetup(_ setup: VoiceBarSetup?) -> String? {
        enableMicrophone.isHidden = true
        retryModelDownload.isHidden = true
        downloadProgress.isHidden = true
        downloadProgress.stopAnimation(nil)
        switch setup {
        case .accessibility: return "全局快捷键"
        case .microphone(.notDetermined):
            enableMicrophone.title = "授权麦克风"
            enableMicrophone.isHidden = false
            return "首次使用"
        case .microphone(.denied):
            enableMicrophone.title = "麦克风设置"
            enableMicrophone.isHidden = false
            return "麦克风权限未开启"
        case .microphone(.restricted): return "麦克风受系统限制"
        case .requestingMicrophone: return "等待麦克风授权"
        case .model(.missing): return "等待下载转写模型"
        case .model(.downloading(let fraction)):
            downloadProgress.isHidden = false
            downloadProgress.isIndeterminate = fraction == nil
            if let fraction {
                let percent = Int((fraction * 100).rounded())
                downloadProgress.doubleValue = Double(percent)
                return percent == 100 ? "正在校验转写模型" : "转写模型下载中 \(percent)%"
            }
            downloadProgress.startAnimation(nil)
            return "正在下载转写模型"
        case .model(.failed):
            retryModelDownload.isHidden = false
            return "转写模型下载失败"
        case .microphone(.authorized), .model(.ready), nil: return nil
        }
    }
}

@MainActor private final class VoiceBarSurface: NSView {
    enum Edge { case top, bottom }

    var joinedEdge: Edge? {
        didSet {
            if joinedEdge != oldValue { needsDisplay = true }
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 16
        var outline = bounds.insetBy(dx: 0.5, dy: 0.5)
        // Draw the joining corners and border outside the window's visible bounds.
        if let joinedEdge {
            let extensionHeight = radius + 1
            if joinedEdge == .bottom { outline.origin.y -= extensionHeight }
            outline.size.height += extensionHeight
        }
        let path = NSBezierPath(roundedRect: outline, xRadius: radius, yRadius: radius)
        NSColor(srgbRed: 0.075, green: 0.13, blue: 0.14, alpha: 1).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

@MainActor private final class LivePreviewLabel: NSTextField {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
    }
}

@MainActor final class PanelEditor: NSTextView {
    var onSubmit: (() -> Bool)?
    var onClearDraft: (() -> Bool)?

    override var needsPanelToBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if !handleDraftShortcut(event) { super.keyDown(with: event) }
    }

    func handleDraftShortcut(_ event: NSEvent) -> Bool {
        guard !event.isARepeat,
              event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command]),
              !hasMarkedText() else { return false }
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return onSubmit?() == true
        case kVK_Escape where !event.modifierFlags.contains(.function): return onClearDraft?() == true
        default: return false
        }
    }
}
