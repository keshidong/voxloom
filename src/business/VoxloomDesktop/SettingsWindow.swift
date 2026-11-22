import AppKit
import SpeechFoundation

@MainActor final class SettingsWindow: NSWindowController, NSTextFieldDelegate {
    let recognition = NSPopUpButton()
    let correction = NSPopUpButton()
    let language = NSPopUpButton()
    let vocabulary = NSTextField()
    let gpu = NSButton(checkboxWithTitle: "使用 GPU 加速 Whisper 和纠错", target: nil, action: nil)
    let inputContext = NSButton(checkboxWithTitle: "用光标附近的文字辅助转写和纠错", target: nil, action: nil)
    let enableAccessibility = NSButton(title: "启用辅助功能", target: nil, action: nil)
    private let permissionStatus = NSTextField(labelWithString: "")
    var onChange: ((DictationSettings) -> Void)?

    init(settings: DictationSettings) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 406),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Voxloom 设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        build()
        load(settings)
    }

    required init?(coder: NSCoder) { nil }

    func updatePermissions(_ availability: DictationAvailability) {
        permissionStatus.stringValue = switch (availability.globalShortcut, availability.canInsert) {
        case (true, true): "全局 Fn 和自动插入已启用"
        case (false, true): "辅助功能已启用，全局 Fn 暂不可用"
        case (_, false): "在系统设置的「辅助功能」中允许 Voxloom"
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
        for control in [recognition, correction, language, gpu, inputContext] {
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
        permissionStatus.textColor = .secondaryLabelColor
        let permissions = NSStackView(views: [enableAccessibility, permissionStatus])
        permissions.alignment = .centerY
        permissions.spacing = 10
        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [heading, hint, models, gpu, inputContext, separator, permissionHeading, permissions])
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
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func load(_ settings: DictationSettings) {
        recognition.selectItem(at: RecognitionModel.allCases.firstIndex(of: settings.model) ?? 0)
        correction.selectItem(at: settings.correctsText ? 0 : 1)
        language.selectItem(at: RecognitionLanguage.allCases.firstIndex(of: settings.language) ?? 0)
        vocabulary.stringValue = settings.vocabulary
        gpu.state = settings.usesGPU ? .on : .off
        inputContext.state = settings.usesInputContext ? .on : .off
    }

    func controlTextDidChange(_ notification: Notification) { changed() }

    @objc private func changed() {
        guard recognition.indexOfSelectedItem >= 0, language.indexOfSelectedItem >= 0 else { return }
        var selected = DictationSettings()
        selected.model = RecognitionModel.allCases[recognition.indexOfSelectedItem]
        selected.language = RecognitionLanguage.allCases[language.indexOfSelectedItem]
        selected.correctsText = correction.indexOfSelectedItem == 0
        selected.vocabulary = String(vocabulary.stringValue.prefix(240))
        selected.usesGPU = gpu.state == .on
        selected.usesInputContext = inputContext.state == .on
        onChange?(selected)
    }
}
