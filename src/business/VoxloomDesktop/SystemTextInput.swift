import AppKit
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

    @MainActor static func contextReader() -> (@Sendable () async -> String)? {
        guard let pid = SystemPaste.foregroundTarget() else { return nil }
        return {
            guard !Task.isCancelled, await isForeground(pid) else { return "" }
            let text = readContext(pid)
            return await isForeground(pid) ? text : ""
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

    @MainActor private static func isForeground(_ pid: pid_t) -> Bool {
        SystemPaste.foregroundTarget() == pid
    }

    private static func readContext(_ pid: pid_t) -> String {
        let app = application(pid)
        guard let input = focusedTextInput(in: app)?.element,
              isSettable(kAXValueAttribute, on: input) || isSettable(kAXSelectedTextAttribute, on: input),
              !Task.isCancelled else { return "" }
        let range = selection(of: input)
        let length = (attribute(kAXNumberOfCharactersAttribute, of: input) as? NSNumber)?.intValue
        let text = excerpt(at: range, length: length, readRange: { string(in: $0, of: input) },
                           readShortValue: { attribute(kAXValueAttribute, of: input) as? String })
        guard !text.isEmpty, let current = focusedTextInput(in: app)?.element, CFEqual(input, current) else { return "" }
        return text
    }

    static func excerpt(at selection: NSRange?, length: Int?, readRange: (NSRange) -> String?,
                        readShortValue: () -> String?) -> String {
        let limit = 240
        if let selection, selection.location >= 0, selection.location != NSNotFound,
           length.map({ selection.location <= $0 }) ?? true {
            let caret = selection.location
            let start = max(0, caret - 160)
            let after = length.map { min(80, $0 - caret) } ?? 0
            let count = caret - start + after
            if count > 0, let text = readRange(NSRange(location: start, length: count)) {
                return String(decoding: text.utf16.prefix(limit), as: UTF16.self)
            }
        }
        guard let length, (1...limit).contains(length), let text = readShortValue(), text.utf16.count <= limit else { return "" }
        return text
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

    private static func string(in range: NSRange, of element: AXUIElement) -> String? {
        var bounds = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &bounds) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                        parameter, &value) == .success else { return nil }
        return value as? String
    }

    private static func isSettable(_ name: String, on element: AXUIElement) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
