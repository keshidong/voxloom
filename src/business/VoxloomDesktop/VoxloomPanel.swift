import AppKit
import Carbon
import SpeechFoundation
import SpeechInput

@MainActor final class VoxloomPanel: NSPanel {
    enum Layout { case controls, preview, editor }

    private static let barSize = NSSize(width: 380, height: 56)
    private static let previewSize = NSSize(width: 380, height: 88)
    private static let draftSize = NSSize(width: 480, height: 252)
    private var placement: (anchor: NSPoint, frame: NSRect)?

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.barSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Voxloom"
        appearance = NSAppearance(named: .darkAqua)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        if let visible = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + 22))
        }
    }

    func setLayout(_ layout: Layout) {
        let size = switch layout {
        case .controls: Self.barSize
        case .preview: Self.previewSize
        case .editor: Self.draftSize
        }
        let previous = frame
        guard previous.size != size else { return }
        let anchor = placement.flatMap { $0.frame == previous ? $0.anchor : nil }
            ?? NSPoint(x: previous.midX, y: previous.minY)
        var origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y)
        if let bounds = screen?.visibleFrame {
            origin.x = max(bounds.minX, min(origin.x, bounds.maxX - size.width))
            origin.y = max(bounds.minY, min(origin.y, bounds.maxY - size.height))
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        placement = (anchor, frame)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class VoxloomOverlay: NSWindowController, NSTextViewDelegate {
    let panel = VoxloomPanel()
    let sample = NSButton(title: "试用示例", target: nil, action: nil)
    let settings = NSButton(title: "设置", target: nil, action: nil)
    let enableAccessibility = NSButton(title: "启用辅助功能", target: nil, action: nil)
    let insert = NSButton(title: "插入 ↵", target: nil, action: nil)
    let copy = NSButton(title: "复制", target: nil, action: nil)
    let clear = NSButton(title: "清空", target: nil, action: nil)
    var onEdit: ((String, String, NSRange?) -> Void)?
    let editor = PanelEditor()
    let status = NSTextField(wrappingLabelWithString: "")
    private let draftToggle = DraftToggleButton(title: "草稿", target: nil, action: nil)
    private let draftBody = NSStackView()
    private let preview = LivePreviewLabel(labelWithString: "")
    private let model = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "松开 Fn 自动插入")
    private let waveform = VoiceWaveformView()
    private let meter = NSLevelIndicator()
    private let progress = NSProgressIndicator()
    private let placeholder = NSTextField(labelWithString: "转写会出现在这里")
    private var presented = ""
    private var keyboardRange: NSRange?

    init() {
        super.init(window: panel)
        build()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        let bar = makeBar()
        buildDraft()
        preview.font = .systemFont(ofSize: 15)
        preview.maximumNumberOfLines = 1
        preview.lineBreakMode = .byTruncatingHead
        preview.setAccessibilityLabel("实时草稿")
        preview.isHidden = true
        let surface = NSView()
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor(srgbRed: 0.075, green: 0.13, blue: 0.14, alpha: 1).cgColor
        surface.layer?.cornerRadius = 16
        surface.layer?.borderWidth = 1
        surface.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        surface.layer?.masksToBounds = true
        panel.contentView = surface
        for row in [draftBody, preview, bar] {
            row.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 14),
                row.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -14)
            ])
        }
        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 28),
            bar.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -14),
            preview.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
            preview.heightAnchor.constraint(equalToConstant: 22),
            draftBody.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -12),
            draftBody.heightAnchor.constraint(equalToConstant: 184)
        ])
        draftBody.isHidden = true
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
        draftToggle.setAccessibilityLabel("草稿")
        enableAccessibility.bezelStyle = .rounded
        enableAccessibility.contentTintColor = .systemMint
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
        let bar = NSStackView(views: [waveform, status, meter, progress, NSView(),
                                     enableAccessibility, draftToggle, settings, close])
        bar.alignment = .centerY
        bar.spacing = 8
        return bar
    }

    private func buildDraft() {
        for button in [sample, insert, copy, clear] {
            button.bezelStyle = .rounded
        }
        insert.bezelColor = .systemMint
        insert.contentTintColor = .black
        insert.setAccessibilityLabel("插入")
        insert.toolTip = "Enter 插入到目标光标或替换所选文字，Shift+Enter 换行"
        model.font = .systemFont(ofSize: 11, weight: .medium)
        model.textColor = .secondaryLabelColor
        shortcut.font = .systemFont(ofSize: 11, weight: .medium)
        shortcut.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [sample, NSView(), clear, copy, insert])
        let details = NSStackView(views: [model, NSView(), shortcut])
        draftBody.orientation = .vertical
        draftBody.alignment = .leading
        draftBody.spacing = 8
        for row in [makePaper(), footer, details] {
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

    @objc private func hide() { panel.orderOut(nil) }

    @objc private func toggleDraft() {
        let show = draftBody.isHidden
        if !show { finishKeyboardEdit() }
        draftBody.isHidden = !show
        draftToggle.title = show ? "收起" : "草稿"
        draftToggle.setAccessibilityLabel(show ? "收起草稿" : "草稿")
        layoutPanel()
        if show, editor.isEditable {
            panel.makeFirstResponder(editor)
        } else if !show, panel.isKeyWindow {
            panel.makeFirstResponder(nil)
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    private func layoutPanel() {
        let expanded = !draftBody.isHidden
        preview.isHidden = expanded || preview.stringValue.isEmpty
        panel.setLayout(expanded ? .editor : (preview.isHidden ? .controls : .preview))
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

    func render(_ flow: VoxloomFlow, availability: DictationAvailability) {
        let current = flow.state
        let phase = current?.live.phase ?? .idle
        let text = current?.text ?? ""
        let available = !text.isEmpty
        let previewText = flow.didSendInsertion ? "" : text.split(whereSeparator: \.isNewline).joined(separator: " ")
        if preview.stringValue != previewText { preview.stringValue = previewText }
        layoutPanel()
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
        enableAccessibility.isHidden = availability.canInsert || phase != .idle
        shortcut.stringValue = switch (availability.globalShortcut, availability.canInsert) {
        case (true, true): "松开 Fn 自动插入"
        case (true, false): "启用辅助功能后自动插入"
        case (false, _): "仅在 Voxloom 内响应 Fn"
        }
        model.stringValue = flow.settings.model.title
        let level = min(1, (current?.live.level ?? 0) * 5)
        meter.isHidden = phase != .recording
        meter.doubleValue = level
        waveform.update(level: phase == .recording ? level : nil, isSample: flow.usesSample)
        let stateText = switch phase {
        case .authorizing: "等待麦克风授权"
        case .recording: "\(flow.usesSample ? "正在读取示例" : "正在录音")  \(Int(current?.live.seconds ?? 0)) 秒"
        case .finishing: "正在整理最后一段"
        case .idle:
            available ? "草稿已就绪" : (availability.globalShortcut && availability.canInsert ? "按住 Fn 说话，松开插入" : "按住 Fn 说话")
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
        status.stringValue = flow.notice ?? current?.live.error ?? correctionText ?? stateText
        status.toolTip = status.stringValue
        status.textColor = phase == .recording ? .systemMint : .labelColor
        sample.isEnabled = flow.canTrySample
        insert.isEnabled = flow.canInsert
        copy.isEnabled = available
        clear.title = flow.canStart ? "清空" : "取消"
        clear.isEnabled = available || !flow.canStart
    }
}

@MainActor private final class LivePreviewLabel: NSTextField {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
    }
}

@MainActor private final class DraftToggleButton: NSButton {
    override var needsPanelToBecomeKey: Bool { true }
}

@MainActor final class PanelEditor: NSTextView {
    var onSubmit: (() -> Bool)?

    override var needsPanelToBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let key = Int(event.keyCode)
        if (key == kVK_Return || key == kVK_ANSI_KeypadEnter),
           event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command]),
           !event.isARepeat, !hasMarkedText(), onSubmit?() == true {
            return
        }
        super.keyDown(with: event)
    }
}
