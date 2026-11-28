import ApplicationServices
import Foundation

struct WindowAccessibilitySnapshot {
    let attribute: (String, AXUIElement) -> CFTypeRef?
    let children: (AXUIElement) -> [AXUIElement]
    let textForRange: (NSRange, AXUIElement) -> CFTypeRef?

    func read(window: AXUIElement, focused: AXUIElement?) -> String {
        if let focused, isSecure(focused) { return "" }
        var pending = [(element: window, depth: 0)]
        var visited: Set<AXUIElement> = []
        var lines: [String] = []
        while let node = pending.popLast() {
            if Task.isCancelled { return "" }
            guard visited.insert(node.element).inserted, !isSecure(node.element),
                  (attribute("AXHidden", node.element) as? NSNumber)?.boolValue != true else { continue }
            let role = (attribute(kAXRoleAttribute, node.element) as? String) ?? kAXUnknownRole
            guard role != kAXApplicationRole, node.depth == 0 || role != kAXWindowRole else { continue }
            lines.append(contentsOf: textFields(of: node.element, role: role))
            pending.append(contentsOf: children(node.element).reversed().map { ($0, node.depth + 1) })
        }
        return WindowContextWords.recent(in: lines.joined(separator: "\n"))
    }

    private func textFields(of element: AXUIElement, role: String) -> [String] {
        [attribute(kAXTitleAttribute, element), attribute(kAXDescriptionAttribute, element), value(of: element, role: role)]
            .compactMap { ($0 as? NSAttributedString)?.string ?? ($0 as? String) }
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        (attribute(kAXSubroleAttribute, element) as? String) == kAXSecureTextFieldSubrole
    }

    private func value(of element: AXUIElement, role: String) -> CFTypeRef? {
        if let value = attribute(kAXValueAttribute, element) { return value }
        guard role == kAXTextAreaRole, let length = (attribute(kAXNumberOfCharactersAttribute, element) as? NSNumber)?.intValue,
              (1..<NSNotFound).contains(length) else { return nil }
        return textForRange(NSRange(location: 0, length: length), element)
    }
}
