import Foundation

enum ConversationReadError: Error, Sendable, Equatable {
    case disabled, noSupportedInput, inputNotEditable, noFocusedWindow
    case noHistoryArea, ambiguousHistoryArea, noMessageText, searchLimit, timedOut, targetChanged, cancelled
}

/// Reads a bounded portion of an accessibility tree near the focused composer.
struct ConversationHistory<Element> {
    enum Kind { case scopeBoundary, container, history, text, ignored }

    let isSame: (Element, Element) -> Bool
    let parent: (Element) -> Element?
    let recentChildren: (Element, Int, Bool) -> [Element]
    let kind: (Element) -> Kind
    let text: (Element) -> String?
    let canContinue: () -> Bool

    func readNearbyText(near input: Element, isCurrent: () -> Bool) -> [String] {
        var branch = input
        var remainingNodes = 48
        var remainingBytes = 3072
        var candidates: [String] = []
        for _ in 0..<6 {
            guard let scope = parent(branch), !isSame(branch, scope), canContinue() else { break }
            let siblings = recentChildren(scope, 12, true)
            if let position = siblings.firstIndex(where: { isSame($0, branch) }) {
                var pending = siblings[..<position].suffix(6).map { (element: $0, depth: 1) }
                while remainingNodes > 0, candidates.count < 12, canContinue(), let node = pending.popLast() {
                    remainingNodes -= 1
                    switch kind(node.element) {
                    case .text:
                        guard let value = text(node.element), value.utf8.count <= remainingBytes,
                              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        candidates.append(value)
                        remainingBytes -= value.utf8.count
                    case .container, .history:
                        guard node.depth < 5 else { continue }
                        pending.append(contentsOf: recentChildren(node.element, 12, true)
                            .map { (element: $0, depth: node.depth + 1) })
                    default: break
                    }
                }
            }
            if kind(scope) == .scopeBoundary || remainingNodes == 0 || candidates.count == 12 { break }
            branch = scope
        }
        guard canContinue(), isCurrent(), canContinue() else { return [] }
        return candidates.reversed()
    }

    func read(near input: Element, messageLimit: Int = 6, preservesOriginalText: Bool = false,
              isCurrent: () -> Bool) -> Result<[String], ConversationReadError> {
        var remaining = 80
        let history: Element
        do {
            history = try findHistory(near: input, remaining: &remaining)
        } catch {
            return .failure(error)
        }
        guard canContinue() else { return .failure(.timedOut) }
        let children = recentChildren(history, 12, true)
        guard canContinue() else { return .failure(.timedOut) }
        guard let latest = children.last else { return .failure(.noMessageText) }
        var pending = children.map { (element: $0, depth: 1) }
        var messages: [String] = []
        while messages.count < messageLimit, remaining > 0, canContinue(), let node = pending.popLast() {
            remaining -= 1
            switch kind(node.element) {
            case .text:
                if let value = text(node.element) {
                    let content = preservesOriginalText ? value : String(decoding: value.utf8.prefix(320), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if content.utf8.count <= 3072, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        messages.append(content)
                    }
                }
            case .container where node.depth < 6:
                pending.append(contentsOf: recentChildren(node.element, 12, true)
                    .map { ($0, node.depth + 1) })
            default: break
            }
        }
        guard canContinue() else { return .failure(.timedOut) }
        guard !messages.isEmpty else { return .failure(remaining == 0 ? .searchLimit : .noMessageText) }
        let current = recentChildren(history, 1, true).last
        let stillCurrent = current.map { isSame(latest, $0) } == true && isCurrent()
        guard canContinue() else { return .failure(.timedOut) }
        return stillCurrent ? .success(messages.reversed()) : .failure(.targetChanged)
    }

    private func findHistory(near input: Element, remaining: inout Int) throws(ConversationReadError) -> Element {
        var branch = input
        for _ in 0..<8 {
            guard canContinue() else { throw .timedOut }
            guard let scope = parent(branch), !isSame(scope, branch) else {
                throw canContinue() ? .noHistoryArea : .timedOut
            }
            let peers = recentChildren(scope, 16, false).filter { !isSame($0, branch) }
            var pending = peers.reversed().map { (element: $0, depth: 1) }
            var history: Element?
            while let node = pending.popLast() {
                guard canContinue() else { throw .timedOut }
                guard remaining > 0 else { throw .searchLimit }
                remaining -= 1
                switch kind(node.element) {
                case .history:
                    guard history == nil else { throw .ambiguousHistoryArea }
                    history = node.element
                case .container where node.depth < 4:
                    pending.append(contentsOf: recentChildren(node.element, 16, false).reversed()
                        .map { ($0, node.depth + 1) })
                default: break
                }
            }
            if let history { return history }
            if kind(scope) == .scopeBoundary { throw canContinue() ? .noHistoryArea : .timedOut }
            branch = scope
        }
        throw .searchLimit
    }
}
