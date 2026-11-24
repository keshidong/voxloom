import AppKit
import ApplicationServices
import SpeechInput

struct DesktopContextReading: Sendable {
    var draft = ""
    var conversation: Result<[String], ConversationReadError> = .failure(.disabled)

    var snapshot: DictationContextSnapshot {
        .init(draft: draft, recentMessages: (try? conversation.get()) ?? [])
    }
}

enum SystemTextInput {
    enum ContextMode { case editableField, terminal }

    private static let beforeCaret = 160
    private static let afterCaret = 80
    private static let excerptLimit = beforeCaret + afterCaret

    static func contextMode(bundleIdentifier: String?, role: String, isWritable: @autoclosure () -> Bool) -> ContextMode? {
        if bundleIdentifier == "com.apple.Terminal", role == kAXTextAreaRole { return .terminal }
        return isWritable() ? .editableField : nil
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

    @MainActor static func contextReader(includeDraft: Bool, includeConversation: Bool)
        -> (@Sendable () async -> DesktopContextReading)? {
        guard let pid = SystemPaste.foregroundTarget() else { return nil }
        let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        return {
            guard !Task.isCancelled else { return .init(conversation: .failure(.cancelled)) }
            guard await isForeground(pid) else { return .init(conversation: .failure(.targetChanged)) }
            let context = readContext(pid, bundleIdentifier: bundleIdentifier,
                                      includeDraft: includeDraft, includeConversation: includeConversation)
            return await isForeground(pid) ? context : .init(conversation: .failure(.targetChanged))
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

    private static func readContext(_ pid: pid_t, bundleIdentifier: String?, includeDraft: Bool,
                                    includeConversation: Bool) -> DesktopContextReading {
        let app = application(pid)
        guard let input = focusedTextInput(in: app) else {
            return .init(conversation: .failure(.noSupportedInput))
        }
        guard let mode = contextMode(
            bundleIdentifier: bundleIdentifier, role: input.role,
            isWritable: isSettable(kAXValueAttribute, on: input.element)
                || isSettable(kAXSelectedTextAttribute, on: input.element)
        ) else {
            return .init(conversation: .failure(.inputNotEditable))
        }
        guard !Task.isCancelled else { return .init(conversation: .failure(.cancelled)) }
        let draft = includeDraft ? readDraft(input.element, mode: mode) : ""
        let conversation = includeConversation ? readConversation(near: input.element, in: app) : .failure(.disabled)
        guard !Task.isCancelled else { return .init(conversation: .failure(.cancelled)) }
        guard let current = focusedTextInput(in: app)?.element, CFEqual(input.element, current) else {
            return .init(conversation: .failure(.targetChanged))
        }
        return .init(draft: draft, conversation: conversation)
    }

    private static func readDraft(_ input: AXUIElement, mode: ContextMode) -> String {
        let selectionRange = selection(of: input)
        let length = (attribute(kAXNumberOfCharactersAttribute, of: input) as? NSNumber)?.intValue
        if mode == .terminal {
            let visible = range(kAXVisibleCharacterRangeAttribute, of: input)
            return terminalExcerpt(at: selectionRange, visible: visible, length: length,
                                   readRange: { string(in: $0, of: input, acceptsAttributedText: true) })
        }
        return excerpt(at: selectionRange, length: length, readRange: { string(in: $0, of: input) },
                       readShortValue: { attribute(kAXValueAttribute, of: input) as? String })
    }

    private static func readConversation(near input: AXUIElement, in app: AXUIElement)
        -> Result<[String], ConversationReadError> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard let window = related(kAXFocusedWindowAttribute, to: app) else { return .failure(.noFocusedWindow) }
        let title = attribute(kAXTitleAttribute, of: window) as? String
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(240))
        let source = ConversationHistory<AXUIElement>(
            isSame: { CFEqual($0, $1) },
            parent: { related(kAXParentAttribute, to: $0) },
            recentChildren: recentChildren,
            kind: conversationKind,
            text: { (attribute(kAXValueAttribute, of: $0) ?? attribute(kAXTitleAttribute, of: $0)) as? String },
            canContinue: { !Task.isCancelled && ContinuousClock.now < deadline }
        )
        return source.read(near: input) {
            guard let currentWindow = related(kAXFocusedWindowAttribute, to: app), CFEqual(window, currentWindow) else {
                return false
            }
            return title == attribute(kAXTitleAttribute, of: currentWindow) as? String
        }
    }

    private static func conversationKind(_ element: AXUIElement) -> ConversationHistory<AXUIElement>.Kind {
        guard let role = attribute(kAXRoleAttribute, of: element) as? String else { return .ignored }
        switch role {
        case "AXApplicationLog": return .history
        case kAXWindowRole, kAXApplicationRole, "AXWebArea", kAXSheetRole: return .scopeBoundary
        case kAXStaticTextRole: return .text
        case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXButtonRole, "AXLink", kAXImageRole,
             kAXMenuRole, kAXMenuBarRole, kAXToolbarRole, "AXLandmarkNavigation", "AXLandmarkComplementary":
            return .ignored
        case kAXGroupRole:
            if attribute(kAXSubroleAttribute, of: element) as? String == "AXApplicationLog" { return .history }
            return .container
        default: return .container
        }
    }

    private static func recentChildren(of element: AXUIElement, limit: Int, visible: Bool) -> [AXUIElement] {
        AXUIElementSetMessagingTimeout(element, 0.025)
        func tail(_ name: String) -> [AXUIElement]? {
            var count: CFIndex = 0
            let key = name as CFString
            guard AXUIElementGetAttributeValueCount(element, key, &count) == .success else { return nil }
            guard count > 0 else { return [] }
            var values: CFArray?
            let size = min(count, limit)
            guard AXUIElementCopyAttributeValues(element, key, count - size, size, &values) == .success else {
                return nil
            }
            return values as? [AXUIElement]
        }
        if visible, let children = tail(kAXVisibleChildrenAttribute) { return children }
        return tail(kAXChildrenAttribute) ?? []
    }

    static func excerpt(at selection: NSRange?, length: Int?, readRange: (NSRange) -> String?,
                        readShortValue: () -> String?) -> String {
        if let selection, selection.location >= 0, selection.location != NSNotFound,
           length.map({ selection.location <= $0 }) ?? true {
            let caret = selection.location
            let range = rangeNearCaret(caret, lowerBound: 0, upperBound: length ?? caret)
            if range.length > 0, let text = readRange(range) {
                return String(decoding: text.utf16.prefix(excerptLimit), as: UTF16.self)
            }
        }
        guard let length, (1...excerptLimit).contains(length), let text = readShortValue(),
              text.utf16.count <= excerptLimit else { return "" }
        return text
    }

    static func terminalExcerpt(at selection: NSRange?, visible: NSRange?, length: Int?,
                                readRange: (NSRange) -> String?) -> String {
        let scanLimit = 4_096
        let scanAfterCaret = 1_024
        let caret = selection.flatMap { $0.length == 0 && (1..<NSNotFound).contains($0.location) ? $0.location : nil }
        let knownLength = length.flatMap { (0..<NSNotFound).contains($0) ? $0 : nil }
        let start: Int
        let end: Int
        if let visible {
            let (visibleEnd, overflow) = visible.location.addingReportingOverflow(visible.length)
            guard !overflow, visibleEnd != NSNotFound, (0..<NSNotFound).contains(visible.location),
                  visible.length > 0 else { return "" }
            start = visible.location
            end = min(visibleEnd, knownLength ?? visibleEnd)
        } else {
            guard let textEnd = knownLength ?? caret else { return "" }
            start = 0
            end = textEnd
        }
        guard end > start else { return "" }
        let range: NSRange
        let caretOffset: Int?
        if let caret, (start...end).contains(caret) {
            let scanStart = max(start, caret - (scanLimit - scanAfterCaret))
            let scanEnd = caret + min(scanAfterCaret, end - caret)
            range = NSRange(location: scanStart, length: scanEnd - scanStart)
            caretOffset = caret - scanStart
        } else {
            let tail = max(start, end - scanLimit)
            range = NSRange(location: tail, length: end - tail)
            caretOffset = nil
        }
        guard let text = readRange(range) else { return "" }
        let scanned = String(decoding: text.utf16.prefix(range.length), as: UTF16.self)
        return compactTerminalRows(in: scanned, caretOffset: caretOffset)
    }

    private static func compactTerminalRows(in text: String, caretOffset: Int?) -> String {
        let rows = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        func hasText(_ row: String) -> Bool { row.contains { $0.isLetter || $0.isNumber } }

        let context: [String]
        if let caretOffset, caretOffset <= text.utf16.count {
            let prefix = String(decoding: text.utf16.prefix(caretOffset), as: UTF16.self)
            let cursorRow = prefix.filter(\.isNewline).count
            // Terminal includes the input row and its placeholder in the rendered text.
            let above = rows.prefix(cursorRow).filter(hasText).suffix(3)
            let below = rows.dropFirst(cursorRow + 1).filter(hasText).prefix(3)
            context = Array(above) + below
        } else {
            context = Array(rows.filter(hasText).suffix(6))
        }

        guard !context.isEmpty else { return "" }
        var remaining = excerptLimit - (context.count - 1)
        return context.enumerated().map { index, row in
            let allowance = remaining / (context.count - index)
            let excerpt = String(decoding: row.utf16.prefix(allowance), as: UTF16.self)
                .trimmingCharacters(in: .whitespaces)
            remaining -= excerpt.utf16.count
            return excerpt
        }.joined(separator: "\n")
    }

    private static func rangeNearCaret(_ caret: Int, lowerBound: Int, upperBound: Int) -> NSRange {
        let start = max(lowerBound, caret - beforeCaret)
        let after = min(afterCaret, upperBound - caret)
        return NSRange(location: start, length: caret - start + after)
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
        range(kAXSelectedTextRangeAttribute, of: element)
    }

    private static func range(_ name: String, of element: AXUIElement) -> NSRange? {
        guard let value = attribute(name, of: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func string(in range: NSRange, of element: AXUIElement, acceptsAttributedText: Bool = false) -> String? {
        var bounds = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &bounds) else { return nil }
        var value: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                       parameter, &value) == .success,
           let text = value as? String { return text }
        guard acceptsAttributedText,
              AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString,
                                                         parameter, &value) == .success else { return nil }
        return (value as? NSAttributedString)?.string
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
