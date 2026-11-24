import AppKit

@MainActor final class ModelDownloadRow: NSStackView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private let retry = NSButton(title: "重试", target: nil, action: nil)
    var onRetry: (() -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 2
        bar.style = .bar
        bar.controlSize = .small
        bar.maxValue = 100
        bar.widthAnchor.constraint(equalToConstant: 108).isActive = true
        retry.target = self
        retry.action = #selector(tryAgain)
        [label, bar, retry].forEach { addArrangedSubview($0) }
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func render(_ title: String, status: ModelDownloadStatus?) {
        isHidden = status == nil
        bar.isHidden = true
        retry.isHidden = true
        bar.stopAnimation(nil)
        switch status {
        case .missing: label.stringValue = "\(title) 等待下载"
        case .downloading(let fraction):
            bar.isHidden = false
            bar.isIndeterminate = fraction == nil
            if let fraction {
                let percent = Int((fraction * 100).rounded())
                bar.doubleValue = Double(percent)
                label.stringValue = percent == 100 ? "\(title) 校验中" : "\(title) 下载中 \(percent)%"
            } else {
                bar.startAnimation(nil)
                label.stringValue = "\(title) 下载中，请稍候"
            }
        case .ready: label.stringValue = "\(title) 已就绪"
        case .failed(let message):
            label.stringValue = "\(title) 下载失败 · \(message)"
            retry.isHidden = false
        case nil: label.stringValue = ""
        }
    }

    @objc private func tryAgain() { onRetry?() }
}
