import AppKit
import ApplicationServices
import SpeechInput

struct DesktopContextReading: Sendable {
    var draft = ""
    var conversation: Result<[String], ConversationReadError> = .failure(.disabled)
    var nearbyChatText: [String] = []

    var snapshot: DictationContextSnapshot {
        .init(draft: draft, recentMessages: (try? conversation.get()) ?? [], nearbyChatText: nearbyChatText)
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

    @MainActor static func contextReader(includeDraft: Bool, includeConversation: Bool, usesConversationModel: Bool = false)
        -> (@Sendable () async -> DesktopContextReading)? {
        guard let pid = SystemPaste.foregroundTarget() else { return nil }
        let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        return {
            guard !Task.isCancelled else { return .init(conversation: .failure(.cancelled)) }
            guard await isForeground(pid) else { return .init(conversation: .failure(.targetChanged)) }
            let context = readContext(pid, bundleIdentifier: bundleIdentifier,
                                      includeDraft: includeDraft, includeConversation: includeConversation,
                                      usesConversationModel: usesConversationModel)
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
                                    includeConversation: Bool, usesConversationModel: Bool) -> DesktopContextReading {
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
        var context = DesktopContextReading()
        if mode == .terminal && includeConversation && usesConversationModel {
            context = readTerminal(input.element, includeDraft: includeDraft, includeConversation: true)
        } else {
            if includeConversation {
                context = readConversation(near: input.element, in: app, usesModel: usesConversationModel)
            }
            if includeDraft { context.draft = readDraft(input.element, mode: mode) }
        }
        guard !Task.isCancelled else { return .init(conversation: .failure(.cancelled)) }
        guard let current = focusedTextInput(in: app)?.element, CFEqual(input.element, current) else {
            return .init(conversation: .failure(.targetChanged))
        }
        return context
    }

    private static func readDraft(_ input: AXUIElement, mode: ContextMode) -> String {
        if mode == .terminal {
            return readTerminal(input, includeDraft: true, includeConversation: false).draft
        }
        let selectionRange = selection(of: input)
        let length = (attribute(kAXNumberOfCharactersAttribute, of: input) as? NSNumber)?.intValue
        return excerpt(at: selectionRange, length: length, readRange: { string(in: $0, of: input) },
                       readShortValue: { attribute(kAXValueAttribute, of: input) as? String })
    }

    private static func readTerminal(_ input: AXUIElement, includeDraft: Bool, includeConversation: Bool) -> DesktopContextReading {
        let selectionRange = selection(of: input)
        let visible = range(kAXVisibleCharacterRangeAttribute, of: input)
        let length = (attribute(kAXNumberOfCharactersAttribute, of: input) as? NSNumber)?.intValue
        return terminalReading(at: selectionRange, visible: visible, length: length, includeDraft: includeDraft,
                               includeConversation: includeConversation,
                               readRange: { string(in: $0, of: input, acceptsAttributedText: true) })
    }

    private static func readConversation(near input: AXUIElement, in app: AXUIElement, usesModel: Bool)
        -> DesktopContextReading {
        guard !Task.isCancelled else { return .init(conversation: .failure(.cancelled)) }
        guard let window = related(kAXFocusedWindowAttribute, to: app) else {
            return .init(conversation: .failure(.noFocusedWindow))
        }
        let title = attribute(kAXTitleAttribute, of: window) as? String
        var deadline = ContinuousClock.now.advanced(by: .milliseconds(240))
        let source = ConversationHistory<AXUIElement>(
            isSame: { CFEqual($0, $1) },
            parent: { related(kAXParentAttribute, to: $0) },
            recentChildren: recentChildren,
            kind: conversationKind,
            text: { (attribute(kAXValueAttribute, of: $0) ?? attribute(kAXTitleAttribute, of: $0)) as? String },
            canContinue: { !Task.isCancelled && ContinuousClock.now < deadline }
        )
        func isCurrent() -> Bool {
            guard let currentWindow = related(kAXFocusedWindowAttribute, to: app), CFEqual(window, currentWindow) else {
                return false
            }
            return title == attribute(kAXTitleAttribute, of: currentWindow) as? String
        }
        let conversation = source.read(near: input, messageLimit: usesModel ? 2 : 6,
                                       preservesOriginalText: usesModel, isCurrent: isCurrent)
        guard usesModel else { return .init(conversation: conversation) }
        let needsFallback = switch conversation {
        case .success(let messages): messages.count < 2
        case .failure(.noHistoryArea), .failure(.noMessageText): true
        default: false
        }
        guard needsFallback else { return .init(conversation: conversation) }
        deadline = ContinuousClock.now.advanced(by: .milliseconds(140))
        return .init(conversation: conversation, nearbyChatText: source.readNearbyText(near: input, isCurrent: isCurrent))
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
        terminalReading(at: selection, visible: visible, length: length, includeDraft: true,
                        includeConversation: false, readRange: readRange).draft
    }

    static func terminalReading(at selection: NSRange?, visible: NSRange?, length: Int?,
                                includeDraft: Bool, includeConversation: Bool,
                                readRange: (NSRange) -> String?) -> DesktopContextReading {
        let scanLimit = includeConversation ? 8_192 : 4_096
        let conversation: Result<[String], ConversationReadError> = .failure(includeConversation ? .noHistoryArea : .disabled)
        guard let screen = terminalScan(at: selection, visible: visible, length: length, scanLimit: scanLimit,
                                        readRange: readRange) else { return .init(conversation: conversation) }
        return .init(draft: includeDraft ? compactTerminalRows(in: screen.text, caretOffset: screen.caretOffset) : "",
                     conversation: conversation,
                     nearbyChatText: includeConversation ? terminalChatCandidates(in: screen.text, caretOffset: screen.caretOffset) : [])
    }

    private static func terminalScan(at selection: NSRange?, visible: NSRange?, length: Int?, scanLimit: Int,
                                     readRange: (NSRange) -> String?) -> (text: String, caretOffset: Int?)? {
        let scanAfterCaret = 1_024
        let caret = selection.flatMap { $0.length == 0 && (1..<NSNotFound).contains($0.location) ? $0.location : nil }
        let knownLength = length.flatMap { (0..<NSNotFound).contains($0) ? $0 : nil }
        let start: Int
        let end: Int
        if let visible {
            let (visibleEnd, overflow) = visible.location.addingReportingOverflow(visible.length)
            guard !overflow, visibleEnd != NSNotFound, (0..<NSNotFound).contains(visible.location),
                  visible.length > 0 else { return nil }
            start = visible.location
            end = min(visibleEnd, knownLength ?? visibleEnd)
        } else {
            guard let textEnd = knownLength ?? caret else { return nil }
            start = 0
            end = textEnd
        }
        guard end > start else { return nil }
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
        guard let text = readRange(range) else { return nil }
        return (String(decoding: text.utf16.prefix(range.length), as: UTF16.self), caretOffset)
    }

    private static func terminalChatCandidates(in text: String, caretOffset: Int?) -> [String] {
        let rows = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let promptMarkers: Set<Character> = ["›", "❯", "»"]
        let frameBars: Set<Character> = ["│", "┃", "║"]
        func isPrompt(_ row: Substring) -> Bool {
            row.first(where: { !$0.isWhitespace }).map { promptMarkers.contains($0) } ?? false
        }

        let caretRow = terminalRow(at: caretOffset, in: text)
        let promptRow = rows.lastIndex(where: isPrompt)
        let nearbyPrompt: Int? = promptRow.flatMap { prompt in
            guard let caretRow, (0...3).contains(caretRow - prompt) else { return nil }
            return prompt
        }
        let end = nearbyPrompt ?? caretRow ?? promptRow ?? rows.count

        var candidates: [String] = []
        var block: [String] = []
        var framedBlock = false
        func finishBlock() {
            if !block.isEmpty { candidates.append(block.joined(separator: "\n")) }
            block = []
        }
        for row in rows.prefix(end) {
            var body = row.trimmingCharacters(in: .whitespaces)
            guard let marker = body.first, body.contains(where: { $0.isLetter || $0.isNumber }) else {
                finishBlock()
                continue
            }
            if marker == "•", body.range(of: #"\(\s*\d+[hms](?:\s+\d+[hms])*\s*\)(?:\s*[·–—]\s*.*)?$"#,
                                          options: .regularExpression) != nil {
                finishBlock()
                continue
            }
            let framed = frameBars.contains(marker)
            let startsMessage = promptMarkers.contains(marker) || marker == "•"
            if framed || startsMessage { body.removeFirst() }
            if framed, body.last == marker { body.removeLast() }
            body = body.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            let continuesBlock = framed ? framedBlock : (!framedBlock && !startsMessage && row.hasPrefix("  "))
            if !continuesBlock { finishBlock() }
            block.append(body)
            framedBlock = framed
        }
        finishBlock()
        return Array(candidates.suffix(12))
    }

    private static func terminalRow(at offset: Int?, in text: String) -> Int? {
        guard let offset, offset <= text.utf16.count else { return nil }
        return String(decoding: text.utf16.prefix(offset), as: UTF16.self).filter(\.isNewline).count
    }

    private static func compactTerminalRows(in text: String, caretOffset: Int?) -> String {
        let rows = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        func hasText(_ row: String) -> Bool { row.contains { $0.isLetter || $0.isNumber } }

        let context: [String]
        if let cursorRow = terminalRow(at: caretOffset, in: text) {
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
