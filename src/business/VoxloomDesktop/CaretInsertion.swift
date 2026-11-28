import Foundation
import SpeechInput

enum InsertionError: LocalizedError, Equatable {
    case noTarget, noFocusedInput, permission, targetChanged, unavailable

    var errorDescription: String? {
        switch self {
        case .noTarget: "请先将光标移到要输入的 App。"
        case .noFocusedInput: "无法确认目标输入框，草稿已保留。"
        case .permission: "请为 Voxloom 启用辅助功能，草稿已保留。"
        case .targetChanged: "目标输入位置已变化，草稿已保留。"
        case .unavailable: "无法发送粘贴请求。草稿已保留。"
        }
    }
}

@MainActor struct CaretInsertion {
    struct Destination {
        fileprivate let pid: pid_t
        fileprivate let stillFocused: (() -> Bool)?
    }

    var foregroundTarget: () -> pid_t?
    var canPost: () -> Bool
    var paste: (String, pid_t) -> Bool
    var captureFocus: (pid_t) -> (() -> Bool)? = { _ in nil }
    var applicationInfo: (pid_t) -> DictationApplication? = { _ in nil }
    var readApplicationContext: (pid_t) async -> String = { _ in "" }

    func destination(requireFocusedInput: Bool = false) throws -> Destination {
        try destination(for: foregroundTarget(), requireFocusedInput: requireFocusedInput)
    }

    func recordingTarget(includeApplication: Bool) -> (destination: Result<Destination, Error>,
        application: DictationApplication?, readContext: (@MainActor () async -> String)?) {
        let pid = foregroundTarget()
        let destination = Result { try self.destination(for: pid, requireFocusedInput: true) }
        guard includeApplication, let pid else { return (destination, nil, nil) }
        let stillFocused = (try? destination.get())?.stillFocused
        let readContext = canPost() ? contextReader(for: pid, stillFocused: stillFocused) : nil
        return (destination, applicationInfo(pid), readContext)
    }

    private func contextReader(for pid: pid_t, stillFocused: (() -> Bool)?) -> (@MainActor () async -> String) {
        return {
            guard !Task.isCancelled, canPost(), foregroundTarget() == pid else { return "" }
            let text = await readApplicationContext(pid)
            guard !Task.isCancelled, canPost(), foregroundTarget() == pid, stillFocused?() ?? true else { return "" }
            return text
        }
    }

    private func destination(for pid: pid_t?, requireFocusedInput: Bool) throws -> Destination {
        guard canPost() else { throw InsertionError.permission }
        guard let pid else { throw InsertionError.noTarget }
        if requireFocusedInput {
            guard let stillFocused = captureFocus(pid) else { throw InsertionError.noFocusedInput }
            return Destination(pid: pid, stillFocused: stillFocused)
        }
        return Destination(pid: pid, stillFocused: nil)
    }

    func insert(_ text: String, at destination: Destination) throws {
        guard canPost() else { throw InsertionError.permission }
        guard foregroundTarget() == destination.pid else { throw InsertionError.targetChanged }
        if let stillFocused = destination.stillFocused {
            guard stillFocused(), foregroundTarget() == destination.pid else { throw InsertionError.targetChanged }
        }
        guard paste(text, destination.pid) else { throw InsertionError.unavailable }
    }
}
