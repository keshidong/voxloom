import AppKit
import SpeechFoundation
import SpeechInput
import RxSwift

@MainActor public final class DemoWindowController: NSWindowController, NSWindowDelegate {
    public let startButton = NSButton(title: "开始录音", target: nil, action: nil)
    public let sampleButton = NSButton(title: "试用示例", target: nil, action: nil)
    public let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    public let copyButton = NSButton(title: "复制文字", target: nil, action: nil)
    public let clearButton = NSButton(title: "清空", target: nil, action: nil)
    public let retryButton = NSButton(title: "用当前设置重识别", target: nil, action: nil)
    public let keywords = NSTextField()
    public let gpu = NSButton(checkboxWithTitle: "Whisper / 纠错 GPU", target: nil, action: nil)
    public let qwen = NSButton(checkboxWithTitle: "Qwen 本地纠错", target: nil, action: nil)
    public let corrected = NSTextView()
    public let correctionStatus = NSTextField(wrappingLabelWithString: "录音中自动纠错 · 原始转写独立保留")
    public let copyCandidateButton = NSButton(title: "复制纠错候选", target: nil, action: nil)
    public let transcript = NSTextView()
    public let status = NSTextField(labelWithString: "准备就绪")
    public let model = NSPopUpButton()
    public let language = NSPopUpButton()
    public private(set) var session: LiveSpeechSession?
    private let resources: DemoResources
    private let captureFactory: @MainActor () -> any AudioCapturing
    private let recognizerFactory: @MainActor (Int, Bool) -> any SpeechRecognizer
    private let correctorFactory: @MainActor (Bool) -> (any TextCorrecting)?
    private let correctionScheduler: any SchedulerType
    private var observation: (any Disposable)?
    private var correctionObservation: (any Disposable)?
    private var correction: CorrectionSession?
    private var startup: Task<Void, Never>?
    private var acceptsCorrections = true
    private let duration = NSTextField(labelWithString: "00:00 / 01:00")
    private let meter = NSLevelIndicator()
    private let activity = NSProgressIndicator()
    private var usingSample = false
    private let sourceLabel = NSTextField(labelWithString: "系统默认麦克风")
    private let pasteboard: NSPasteboard

    public init(resources: DemoResources,
                captureFactory: @escaping @MainActor () -> any AudioCapturing = { MicrophoneCapture() },
                recognizerFactory: (@MainActor (Int, Bool) -> any SpeechRecognizer)? = nil,
                pasteboard: NSPasteboard = .general,
                correctorFactory: (@MainActor (Bool) -> (any TextCorrecting)?)? = nil,
                correctionScheduler: any SchedulerType = MainScheduler.instance) {
        self.resources = resources
        self.captureFactory = captureFactory
        self.pasteboard = pasteboard
        self.recognizerFactory = recognizerFactory ?? { resources.recognizer(model: $0, useGPU: $1) }
        self.correctorFactory = correctorFactory ?? { resources.corrector(useGPU: $0) }
        self.correctionScheduler = correctionScheduler
        super.init(window: NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false))
        buildWindow()
        render(LiveState())
    }
    required init?(coder: NSCoder) { nil }
    public func shutdown() async {
        startup?.cancel()
        await startup?.value
        await session?.shutdown()
        await correction?.shutdown()
    }

    private func buildWindow() {
        guard let window, let content = window.contentView else { return }
        window.title = "voxloom 0.3.2"
        window.minSize = NSSize(width: 980, height: 760)
        window.center()
        window.delegate = self
        let title = NSTextField(labelWithString: "本地语音转写")
        title.font = .systemFont(ofSize: 30, weight: .bold)
        let subtitle = NSTextField(labelWithString: "离线语音识别 → Qwen3-4B 纠错 · 中文 / English · 本机处理")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 14)
        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical; header.alignment = .leading; header.spacing = 8

        model.addItems(withTitles: ["Whisper base", "Whisper tiny", "Whisper Turbo", "Qwen ASR 1.7B · 默认"])
        model.selectItem(at: 3)
        language.addItems(withTitles: ["自动识别语言", "中文", "English"])
        language.selectItem(at: 1)
        gpu.state = .on
        qwen.state = .on
        qwen.target = self; qwen.action = #selector(toggleCorrection)
        let settings = NSStackView(views: [model, language, gpu, qwen])
        settings.spacing = 12
        keywords.placeholderString = "可选词汇提示：英文术语、人名、产品名，以空格分隔"
        keywords.setAccessibilityLabel("词汇提示")
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.font = .systemFont(ofSize: 12)
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.font = .systemFont(ofSize: 23)
        transcript.textContainerInset = NSSize(width: 20, height: 20)
        transcript.autoresizingMask = [.width]
        transcript.isHorizontallyResizable = false
        transcript.textContainer?.widthTracksTextView = true
        transcript.setAccessibilityLabel("实时转写文本")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 12
        scroll.documentView = transcript
        corrected.isEditable = true
        corrected.isSelectable = true
        corrected.font = .systemFont(ofSize: 23)
        corrected.textContainerInset = NSSize(width: 20, height: 20)
        corrected.autoresizingMask = [.width]
        corrected.isHorizontallyResizable = false
        corrected.textContainer?.widthTracksTextView = true
        corrected.setAccessibilityLabel("纠错候选文本")
        let candidateScroll = NSScrollView()
        candidateScroll.hasVerticalScroller = true
        candidateScroll.documentView = corrected
        candidateScroll.wantsLayer = true
        candidateScroll.layer?.cornerRadius = 12
        correctionStatus.textColor = .secondaryLabelColor
        correctionStatus.font = .systemFont(ofSize: 12)

        meter.levelIndicatorStyle = .continuousCapacity
        meter.minValue = 0; meter.maxValue = 1
        meter.warningValue = 0.8; meter.criticalValue = 0.95
        meter.widthAnchor.constraint(equalToConstant: 100).isActive = true
        meter.setAccessibilityLabel("麦克风音量")
        duration.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        duration.textColor = .secondaryLabelColor
        activity.style = .spinning
        activity.controlSize = .small
        activity.isDisplayedWhenStopped = false
        let statusRow = NSStackView(views: [activity, status, meter, duration])
        statusRow.spacing = 12
        for button in [startButton, sampleButton, cancelButton, copyButton, clearButton, retryButton, copyCandidateButton] {
            button.bezelStyle = .rounded
            button.target = self
            button.controlSize = .large
        }
        startButton.action = #selector(toggleRecording)
        startButton.keyEquivalent = "\r"
        startButton.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        startButton.imagePosition = .imageLeading
        startButton.bezelColor = .controlAccentColor
        startButton.contentTintColor = .white
        sampleButton.action = #selector(startSample)
        cancelButton.action = #selector(cancelRecording)
        copyButton.action = #selector(copyText)
        clearButton.action = #selector(clearText)
        retryButton.action = #selector(retryRecording)
        copyCandidateButton.action = #selector(copyCandidate)
        let actions = NSStackView(views: [startButton, sampleButton, cancelButton, copyButton, clearButton, retryButton])
        actions.spacing = 12
        let candidateRow = NSStackView(views: [correctionStatus, copyCandidateButton])
        candidateRow.spacing = 12
        let hint = NSTextField(wrappingLabelWithString: "使用系统默认麦克风；AirPods 请先在系统声音设置中选中。首次加载模型较慢，后续逐段更新，每次最长 60 秒。\n文字稳定约 0.8 秒或持续变化约 3 秒时触发纠错。候选可编辑；数字、金额及百分比请听音核对。")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [header, settings, keywords, sourceLabel,
            NSTextField(labelWithString: "原始转写"), scroll,
            NSTextField(labelWithString: "纠错候选"), candidateScroll, candidateRow, statusRow, actions, hint])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            candidateScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            candidateRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            keywords.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            candidateScroll.heightAnchor.constraint(equalTo: scroll.heightAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func toggleRecording() {
        switch session?.state.phase ?? .idle {
        case .idle: begin(capture: captureFactory(), sample: false)
        case .recording: session?.stop()
        case .authorizing: session?.cancel()
        case .finishing: break
        }
    }

    @objc private func startSample() {
        do { begin(capture: SampleCapture(audio: try resources.sample(english: language.indexOfSelectedItem == 2)), sample: true) }
        catch { status.stringValue = "示例音频不可用：\(error.localizedDescription)" }
    }

    private func begin(capture: any AudioCapturing, sample: Bool) {
        usingSample = sample
        acceptsCorrections = true
        startup?.cancel()
        let previous = self.session
        observation?.dispose()
        resetCorrection()
        let session = LiveSpeechSession(capture: capture)
        self.session = session
        observation = session.states.subscribe(onNext: { [weak self] in self?.render($0) })
        let options: [RecognitionLanguage] = [.automatic, .chinese, .english]
        let recognizer = recognizerFactory(model.indexOfSelectedItem, gpu.state == .on)
        let selectedOptions = RecognitionOptions(language: options[language.indexOfSelectedItem], context: keywords.stringValue)
        startup = Task { [weak self] in
            await previous?.shutdown()
            guard !Task.isCancelled, self?.session === session else { return }
            session.start(recognizer: recognizer, options: selectedOptions)
        }
    }

    private func resetCorrection() {
        correction?.cancel()
        correctionObservation?.dispose()
        correction = nil
        renderCorrection(.idle)
        guard qwen.state == .on, let corrector = correctorFactory(gpu.state == .on) else { return }
        let next = CorrectionSession(corrector: corrector, scheduler: correctionScheduler)
        correction = next
        correctionObservation = next.states.subscribe(onNext: { [weak self] in self?.renderCorrection($0) })
    }

    private func renderCorrection(_ state: CorrectionStatus) {
        switch state {
        case .idle:
            corrected.string = ""
            correctionStatus.stringValue = qwen.state == .on ? "录音中自动纠错 · 等待转写文字" : "本地纠错已关闭"
        case .working: correctionStatus.stringValue = "正在本机纠错… · 上一候选暂时保留"
        case .candidate(let candidate):
            corrected.string = candidate.text
            correctionStatus.stringValue = candidate.numbersChanged ? "数字发生变化，请听音核对后使用" :
                candidate.containsNumbers ? "候选已更新 · 请核对数字、金额及百分比" : "候选已更新 · 请核对后使用"
        case .failed(let message): correctionStatus.stringValue = message + " · 原始转写仍可使用"
        }
        copyCandidateButton.isEnabled = !corrected.string.isEmpty
    }

    private func render(_ state: LiveState) {
        let active = state.phase != .idle
        model.isEnabled = !active; language.isEnabled = !active
        gpu.isEnabled = !active; keywords.isEnabled = !active
        retryButton.isEnabled = !active && !state.samples.isEmpty
        sampleButton.isEnabled = !active
        cancelButton.isEnabled = active
        clearButton.isEnabled = !active && !state.text.isEmpty
        copyButton.isEnabled = !state.text.isEmpty
        startButton.isEnabled = state.phase != .finishing
        startButton.title = state.phase == .recording ? "停止录音" : state.phase == .authorizing ? "取消授权等待" : "开始录音"
        let visibleText = state.text.isEmpty ? "转写文字会出现在这里…" : state.text
        if transcript.string != visibleText { transcript.string = visibleText }
        transcript.textColor = state.text.isEmpty ? .tertiaryLabelColor : .labelColor
        meter.doubleValue = min(1, state.level * 8)
        duration.stringValue = String(format: "%02d:%02d / 01:00", Int(state.seconds) / 60, Int(state.seconds) % 60)
        sourceLabel.stringValue = session?.sourceDescription ?? "系统默认麦克风"
        let source = usingSample ? "示例录音 · " : ""
        switch state.phase {
        case .idle: status.stringValue = state.error ?? (state.text.isEmpty ? "准备就绪" : "转写完成")
        case .authorizing: status.stringValue = source + "正在准备音频…"
        case .recording: status.stringValue = source + (state.busy ? "录音中 · 正在转写…" : "录音中 · 请说话")
        case .finishing: status.stringValue = source + "正在完成最后一段…"
        }
        if state.busy || state.phase == .authorizing { activity.startAnimation(nil) }
        else { activity.stopAnimation(nil) }
        if acceptsCorrections, qwen.state == .on, !state.text.isEmpty {
            let request = CorrectionRequest(text: state.text, vocabulary: keywords.stringValue)
            if state.phase == .idle { correction?.run(request) }
            else { correction?.update(request) }
        }
    }

    @objc private func cancelRecording() { acceptsCorrections = false; session?.cancel(); correction?.cancel() }
    @objc private func clearText() { acceptsCorrections = false; session?.clear(); correction?.cancel() }
    @objc private func toggleCorrection() {
        resetCorrection()
        if let state = session?.state { render(state) }
    }
    @objc private func copyCandidate() {
        guard !corrected.string.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(corrected.string, forType: .string)
    }
    @objc private func retryRecording() {
        guard let samples = session?.state.samples, !samples.isEmpty,
              let audio = try? AudioClip(samples: samples) else { return }
        begin(capture: SampleCapture(audio: audio, realtime: false), sample: false)
    }
    @objc private func copyText() {
        guard let text = session?.state.text, !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
