import Foundation
import ApplicationServices

enum SystemTextInput {
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
        guard let original = focusedTextInput(in: app) else { return nil }
        let range = selection(of: original.element)
        let identity = fieldIdentity(original)
        return {
            guard let current = focusedTextInput(in: app) else { return false }
            guard CFEqual(original.element, current.element) || identity?.matches(fieldIdentity(current)) == true
            else { return false }
            return acceptsSelection(selection(of: current.element), original: range)
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

    private static func focusedTextInput(in app: AXUIElement) -> (element: AXUIElement, role: String)? {
        guard let element = related(kAXFocusedUIElementAttribute, to: app),
              let role = attribute(kAXRoleAttribute, of: element) as? String else { return nil }
        guard role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole,
              (attribute(kAXSubroleAttribute, of: element) as? String) != kAXSecureTextFieldSubrole else { return nil }
        return (element, role)
    }

    private static func fieldIdentity(_ input: (element: AXUIElement, role: String)) -> FieldIdentity? {
        if let domID = attribute(kAXDOMIdentifierAttribute, of: input.element) as? String, !domID.isEmpty {
            // The same DOM ID may appear in different tabs. Compare the web area as well.
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(40))
            var child = input.element
            for _ in 0..<8 {
                guard ContinuousClock.now < deadline, let parent = related(kAXParentAttribute, to: child) else { return nil }
                if attribute(kAXRoleAttribute, of: parent) as? String == "AXWebArea" {
                    return FieldIdentity(identifier: domID, scope: parent, role: input.role)
                }
                child = parent
            }
            return nil
        }
        guard let id = attribute(kAXIdentifierAttribute, of: input.element) as? String, !id.isEmpty,
              let parent = related(kAXParentAttribute, to: input.element) else { return nil }
        return FieldIdentity(identifier: id, scope: parent, role: input.role)
    }

    private static func related(_ name: String, to element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let related = value as! AXUIElement
        AXUIElementSetMessagingTimeout(related, 0.07)
        return related
    }

    private static func selection(of element: AXUIElement) -> NSRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute, of: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
