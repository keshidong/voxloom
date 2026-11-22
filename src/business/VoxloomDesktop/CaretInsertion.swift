import Foundation

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

    func destination(requireFocusedInput: Bool = false) throws -> Destination {
        guard canPost() else { throw InsertionError.permission }
        guard let target = foregroundTarget() else { throw InsertionError.noTarget }
        if requireFocusedInput {
            guard let stillFocused = captureFocus(target) else { throw InsertionError.noFocusedInput }
            return Destination(pid: target, stillFocused: stillFocused)
        }
        return Destination(pid: target, stillFocused: nil)
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
