#if DEBUG
import Foundation
import SpeechFoundation
import SpeechInput

@MainActor final class DebugContextLog {
    private struct Entry {
        let id: UUID
        let settings: DictationSettings
        let readerAvailable: Bool
        let target: String?
        var snapshot: DictationContextSnapshot?
        var conversationError: ConversationReadError?
        var prompt: String?
    }

    private var entry: Entry?
    var onChange: (() -> Void)?

    func begin(settings: DictationSettings, readerAvailable: Bool, target: String?) -> UUID {
        let id = UUID()
        entry = Entry(id: id, settings: settings, readerAvailable: readerAvailable, target: target)
        onChange?()
        return id
    }

    func record(_ snapshot: DictationContextSnapshot, for id: UUID, conversationError: ConversationReadError? = nil) {
        guard entry?.id == id else { return }
        entry?.snapshot = snapshot
        entry?.conversationError = conversationError
        onChange?()
    }

    func record(prompt: String, for id: UUID) {
        guard entry?.id == id, entry?.prompt == nil else { return }
        entry?.prompt = prompt
        onChange?()
    }

    func clear() {
        entry = nil
        onChange?()
    }

    var text: String {
        guard let entry else { return "切回目标 App，按住 Fn 说话。这里会显示最近一轮的读取结果。" }
        let settings = entry.settings
        let status: String
        if let snapshot = entry.snapshot {
            status = snapshot.draft.isEmpty && snapshot.recentMessages.isEmpty ? "未读到可用文字" : "读取完成"
        } else if entry.readerAvailable {
            status = "等待读取"
        } else if settings.usesInputContext || settings.usesConversationContext {
            status = "辅助功能未授权，或没有可读取的前台 App"
        } else {
            status = "上下文开关均已关闭"
        }
        let draft = entry.snapshot?.draft ?? ""
        let messages = (entry.snapshot?.recentMessages ?? []).enumerated().map { "\($0.offset + 1). \($0.element)" }
        let promptState = entry.prompt.map { $0.isEmpty ? "（空）" : $0 } ?? "等待识别请求"
        let bytes = entry.prompt.map { String($0.utf8.count) } ?? "—"
        let conversationStatus: String
        if !settings.usesConversationContext {
            conversationStatus = "近期消息开关已关闭"
        } else if let error = entry.conversationError {
            conversationStatus = error.debugMessage
        } else {
            conversationStatus = entry.snapshot == nil ? status : "已读取"
        }
        return """
        前台 App  \(entry.target ?? "未知")
        识别模型  \(settings.model.title)
        读取状态  \(status)

        光标附近文字 · \(settings.usesInputContext ? "开启" : "关闭")
        \(draft.isEmpty ? "（无）" : draft)

        近期消息片段 · \(settings.usesConversationContext ? "开启" : "关闭") · \(messages.count) 条
        近期消息读取  \(conversationStatus)
        \(messages.isEmpty ? "（无）" : messages.joined(separator: "\n\n"))

        ASR 提示词 · \(bytes) / \(settings.model.promptByteLimit) UTF-8 字节
        \(promptState)
        """
    }

    func tracking(_ reader: @escaping @Sendable () async -> DesktopContextReading, for id: UUID)
        -> @Sendable () async -> DictationContextSnapshot {
        return { [weak self] in
            let reading = await reader()
            let snapshot = reading.snapshot
            if !Task.isCancelled {
                let error: ConversationReadError?
                if case .failure(let failure) = reading.conversation { error = failure } else { error = nil }
                await self?.record(snapshot, for: id, conversationError: error)
            }
            return snapshot
        }
    }

    func tracking(_ recognizer: any SpeechRecognizer, for id: UUID) -> any SpeechRecognizer {
        TrackingRecognizer(provider: recognizer, log: self, id: id)
    }

    private struct TrackingRecognizer: SpeechRecognizer {
        let provider: any SpeechRecognizer
        weak var log: DebugContextLog?
        let id: UUID

        func transcribe(_ audio: AudioClip, options: RecognitionOptions) async throws -> Transcript {
            try Task.checkCancellation()
            await log?.record(prompt: options.context, for: id)
            return try await provider.transcribe(audio, options: options)
        }

        func shutdown() async { await provider.shutdown() }
    }
}

private extension ConversationReadError {
    var debugMessage: String {
        switch self {
        case .disabled: "近期消息开关已关闭"
        case .noSupportedInput: "未找到受支持的聚焦输入框"
        case .inputNotEditable: "当前焦点控件未通过可编辑检查"
        case .noFocusedWindow: "无法读取当前窗口"
        case .noHistoryArea: "找不到辅助功能标记的聊天记录区域"
        case .ambiguousHistoryArea: "同一范围内有多个聊天记录区域"
        case .noMessageText: "找到了聊天记录区域，里面没有可读的消息文字"
        case .searchLimit: "已达到辅助功能树的扫描上限"
        case .timedOut: "读取聊天记录超时"
        case .targetChanged: "读取期间 App、焦点或会话发生变化"
        case .cancelled: "读取已取消"
        }
    }
}
#endif
