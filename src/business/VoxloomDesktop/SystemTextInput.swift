import Foundation
import ApplicationServices

struct SystemTextInput {
    var attribute: (String, AXUIElement) -> CFTypeRef? = readAttribute
    var isSettable: (String, AXUIElement) -> Bool = attributeIsSettable

    private struct FocusedInput {
        let element: AXUIElement
        let role: String
        let selection: NSRange?
    }

    struct FieldIdentity {
        let identifier: String
        let scope: AXUIElement
        let role: String

        func matches(_ candidate: FieldIdentity?) -> Bool {
            guard let candidate, identifier == candidate.identifier, role == candidate.role else { return false }
            return CFEqual(scope, candidate.scope)
        }
    }

    static func captureFocus(_ pid: pid_t) -> (() -> Bool)? {
        let app = application(pid)
        return SystemTextInput().captureFocus(in: app)
    }

    func captureFocus(in app: AXUIElement) -> (() -> Bool)? {
        guard let original = focusedTextInput(in: app) else { return nil }
        let identity = fieldIdentity(original)
        return {
            guard let current = focusedTextInput(in: app) else { return false }
            guard CFEqual(original.element, current.element) || identity?.matches(fieldIdentity(current)) == true
            else { return false }
            return Self.acceptsSelection(current.selection, original: original.selection)
        }
    }

    static func acceptsSelection(_ current: NSRange?, original: NSRange?) -> Bool {
        if original?.length ?? 0 > 0 { return current == original }
        return current?.length ?? 0 == 0
    }

    private static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        return app
    }

    private func focusedTextInput(in app: AXUIElement) -> FocusedInput? {
        guard var element = related(kAXFocusedUIElementAttribute, to: app)
                ?? related(kAXFocusedWindowAttribute, to: app) else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(40))
        for _ in 0..<4 {
            guard (attribute(kAXSubroleAttribute, element) as? String) != kAXSecureTextFieldSubrole else { return nil }
            if let input = textInput(element) { return input }
            guard ContinuousClock.now < deadline,
                  let child = related(kAXFocusedUIElementAttribute, to: element),
                  !CFEqual(element, child) else { return nil }
            element = child
        }
        return nil
    }

    private func textInput(_ element: AXUIElement) -> FocusedInput? {
        guard let role = attribute(kAXRoleAttribute, element) as? String else { return nil }
        let selection = selection(of: element)
        switch role {
        case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole:
            break
        default:
            guard selection != nil,
                  isSettable(kAXSelectedTextAttribute, element) || isSettable(kAXValueAttribute, element)
            else { return nil }
        }
        return FocusedInput(element: element, role: role, selection: selection)
    }

    private func fieldIdentity(_ input: FocusedInput) -> FieldIdentity? {
        if let domID = attribute(kAXDOMIdentifierAttribute, input.element) as? String, !domID.isEmpty {
            // The same DOM ID may appear in different tabs. Compare the web area as well.
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(40))
            var child = input.element
            for _ in 0..<8 {
                guard ContinuousClock.now < deadline, let parent = related(kAXParentAttribute, to: child) else { return nil }
                if attribute(kAXRoleAttribute, parent) as? String == "AXWebArea" {
                    return FieldIdentity(identifier: domID, scope: parent, role: input.role)
                }
                child = parent
            }
            return nil
        }
        guard let id = attribute(kAXIdentifierAttribute, input.element) as? String, !id.isEmpty,
              let parent = related(kAXParentAttribute, to: input.element) else { return nil }
        return FieldIdentity(identifier: id, scope: parent, role: input.role)
    }

    private func related(_ name: String, to element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let related = value as! AXUIElement
        AXUIElementSetMessagingTimeout(related, 0.07)
        return related
    }

    private func selection(of element: AXUIElement) -> NSRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute, element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func readAttribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func attributeIsSettable(_ name: String, on element: AXUIElement) -> Bool {
        var canSet = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &canSet) == .success && canSet.boolValue
    }
}
