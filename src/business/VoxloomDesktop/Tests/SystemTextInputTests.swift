import ApplicationServices
import AppKit
import Foundation
import Testing
@testable import VoxloomDesktop

struct SystemTextInputTests {
    @Test func onlySnapshotsTheActiveWindowAndSkipsSecureAndHiddenSubtrees() {
        let tree = TextInputFocusFixture()
        let window = tree.element(role: kAXWindowRole)
        let otherWindow = tree.element(role: kAXWindowRole)
        let password = tree.element(role: kAXTextFieldRole)
        let hidden = tree.element(role: kAXGroupRole)
        let hiddenLabel = tree.element(role: kAXStaticTextRole)
        let visible = tree.element(role: kAXStaticTextRole)
        tree.set(kAXFocusedWindowAttribute, on: tree.app, to: window)
        tree.set(kAXTitleAttribute, on: otherWindow, to: "另一个窗口" as CFString)
        tree.set(kAXSubroleAttribute, on: password, to: kAXSecureTextFieldSubrole as CFString)
        tree.set(kAXValueAttribute, on: password, to: "安全控件测试值" as CFString)
        tree.set("AXHidden", on: hidden, to: NSNumber(value: true))
        tree.set(kAXValueAttribute, on: hiddenLabel, to: "隐藏正文" as CFString)
        tree.set(kAXValueAttribute, on: visible, to: "当前正文" as CFString)
        let children = [tree.app: [window, otherWindow], window: [password, hidden, visible], hidden: [hiddenLabel]]
        var input = tree.input
        input.contextChildren = { children[$0] ?? [] }

        #expect(input.contextText(in: tree.app).replacingOccurrences(of: " ", with: "") == "当前正文")
        tree.set(kAXFocusedUIElementAttribute, on: tree.app, to: password)
        #expect(input.contextText(in: tree.app).isEmpty)
    }

    @Test func dropsTheSnapshotIfTheFocusedWindowChangesWhileItIsBeingRead() {
        let tree = TextInputFocusFixture()
        let original = tree.element(role: kAXWindowRole)
        let otherWindow = tree.element(role: kAXWindowRole)
        tree.set(kAXFocusedWindowAttribute, on: tree.app, to: original)
        tree.set(kAXTitleAttribute, on: original, to: "原窗口" as CFString)
        var input = tree.input
        input.contextChildren = { element in
            if element == original { tree.set(kAXFocusedWindowAttribute, on: tree.app, to: otherWindow) }
            return []
        }

        #expect(input.contextText(in: tree.app).isEmpty)
    }

    @Test func includesTheFullTextWhenAnEditorOnlyExposesAccessibilityRanges() {
        let tree = TextInputFocusFixture()
        let window = tree.element(role: kAXWindowRole)
        let field = tree.element(role: kAXTextAreaRole)
        let text = "早期内容\n\n终端输出\n当前输入"
        tree.set(kAXFocusedWindowAttribute, on: tree.app, to: window)
        tree.set(kAXFocusedUIElementAttribute, on: tree.app, to: field)
        tree.set(kAXNumberOfCharactersAttribute, on: field, to: NSNumber(value: text.utf16.count))
        var input = tree.input
        input.contextChildren = { $0 == window ? [field] : [] }
        input.textForRange = { range, element in
            guard element == field, range == NSRange(location: 0, length: text.utf16.count) else { return nil }
            return text as CFString
        }

        #expect(input.contextText(in: tree.app).replacingOccurrences(of: " ", with: "") == "早期内容终端输出当前输入")
    }

    @Test func keepsTheLastThreeHundredValidWordsAfterCleaning() {
        let tree = TextInputFocusFixture()
        let window = tree.element(role: kAXWindowRole)
        let siblings = (0..<300).map { _ in tree.element(role: kAXGroupRole) }
        let levels = (0..<30).map { _ in tree.element(role: kAXGroupRole) }
        let message = tree.element(role: kAXStaticTextRole)
        let expected = String(repeating: "release ", count: 299) + "ready"
        let text = "older content \(expected)\n" + String(repeating: "export DEPLOYMENT_MODE=internal\n", count: 1_010)
        tree.set(kAXFocusedWindowAttribute, on: tree.app, to: window)
        tree.set(kAXValueAttribute, on: message, to: text as CFString)
        var children = Dictionary(uniqueKeysWithValues: zip(levels, (Array(levels.dropFirst()) + [message]).map { [$0] }))
        children[window] = siblings + [levels[0]]
        var input = tree.input
        input.contextChildren = { children[$0] ?? [] }

        #expect(input.contextText(in: tree.app) == expected)
    }

    @Test func extractsNaturalWordsFromWindowTextAndDropsFormattingAndVariables() {
        let tree = TextInputFocusFixture()
        let window = tree.element(role: kAXWindowRole)
        let page = tree.element(role: "AXWebArea")
        let composer = tree.element(role: kAXTextAreaRole)
        let message = tree.element(role: kAXStaticTextRole)
        let sidebar = tree.element(role: kAXListRole)
        let sidebarText = tree.element(role: kAXStaticTextRole)
        tree.set(kAXFocusedWindowAttribute, on: tree.app, to: window)
        tree.set(kAXFocusedUIElementAttribute, on: tree.app, to: composer)
        tree.set(kAXTitleAttribute, on: window, to: "部署页面" as CFString)
        tree.set(kAXValueAttribute, on: composer, to: "未发送的输入" as CFString)
        tree.set(kAXValueAttribute, on: message, to: NSAttributedString(string: """
        **先检查服务** and [review the release](https://example.com/docs)
        <span>滚动部署</span> ${RELEASE_ID} export RELEASE_MODE="internal value"
        deployment_config `let pendingJob = job` \u{001B}[31m ready\u{001B}[0m
        ```sh
        echo diagnostic words
        ```
        """))
        tree.set(kAXValueAttribute, on: sidebarText, to: "环境列表" as CFString)
        let children = [window: [sidebar, page], sidebar: [sidebarText], page: [composer, message]]
        var input = tree.input
        input.contextChildren = { children[$0] ?? [] }

        let text = input.contextText(in: tree.app)
        #expect(text.contains("and review the release"))
        #expect(text.replacingOccurrences(of: " ", with: "") ==
            "部署页面环境列表未发送的输入先检查服务andreviewtherelease滚动部署ready")
    }

    @Test func aCustomTextEditorCanBeCapturedAndRechecked() throws {
        let tree = TextInputFocusFixture()
        let editor = tree.element(role: kAXGroupRole, selection: NSRange(location: 4, length: 0),
                                  writable: [kAXValueAttribute])
        let otherEditor = tree.element(role: kAXGroupRole, selection: NSRange(location: 4, length: 0),
                                       writable: [kAXSelectedTextAttribute])
        tree.set(kAXFocusedUIElementAttribute, on: tree.app, to: editor)
        let stillFocused = try #require(tree.input.captureFocus(in: tree.app))
        #expect(stillFocused())
        tree.set(kAXFocusedUIElementAttribute, on: tree.app, to: otherEditor)
        #expect(!stillFocused())
        #expect(tree.input.captureFocus(in: tree.app)?() == true)
    }

    @Test(arguments: [false, true])
    func aFocusedWindowCanReportTheRealTextInput(appReportsWindowAsFocus: Bool) throws {
        let tree = TextInputFocusFixture()
        let window = tree.element(role: kAXWindowRole)
        let container = tree.element(role: kAXScrollAreaRole)
        let editor = tree.element(role: kAXTextAreaRole)
        tree.set(kAXFocusedWindowAttribute, on: tree.app, to: window)
        if appReportsWindowAsFocus { tree.set(kAXFocusedUIElementAttribute, on: tree.app, to: window) }
        tree.set(kAXFocusedUIElementAttribute, on: window, to: container)
        tree.set(kAXFocusedUIElementAttribute, on: container, to: editor)
        let stillFocused = try #require(tree.input.captureFocus(in: tree.app))
        #expect(stillFocused())
        tree.set(kAXFocusedUIElementAttribute, on: container, to: container)
        #expect(!stillFocused())
    }

    @Test func unsupportedOrSecureControlsNeverConfirmTheFocus() {
        let tree = TextInputFocusFixture()
        let range = NSRange(location: 0, length: 0)
        let readOnlyText = tree.element(role: kAXGroupRole, selection: range)
        let writableSlider = tree.element(role: kAXSliderRole, writable: [kAXValueAttribute])
        let password = tree.element(role: kAXTextFieldRole, selection: range, writable: [kAXValueAttribute])
        tree.set(kAXSubroleAttribute, on: password, to: kAXSecureTextFieldSubrole as CFString)
        for control in [readOnlyText, writableSlider, password] {
            tree.set(kAXFocusedUIElementAttribute, on: tree.app, to: control)
            #expect(tree.input.captureFocus(in: tree.app) == nil)
            #expect(tree.input.contextText(in: tree.app).isEmpty)
        }
    }

    @Test func aRebuiltComposerRequiresTheSameIdentifierDocumentAndRole() {
        let document = AXUIElementCreateApplication(101)
        let otherDocument = AXUIElementCreateApplication(102)
        let anchor = SystemTextInput.FieldIdentity(identifier: "composer", scope: document, role: kAXTextAreaRole)
        let same = SystemTextInput.FieldIdentity(identifier: "composer", scope: document, role: kAXTextAreaRole)
        let otherTab = SystemTextInput.FieldIdentity(identifier: "composer", scope: otherDocument, role: kAXTextAreaRole)
        let search = SystemTextInput.FieldIdentity(identifier: "search", scope: document, role: kAXTextAreaRole)
        let differentRole = SystemTextInput.FieldIdentity(identifier: "composer", scope: document, role: kAXTextFieldRole)
        #expect(anchor.matches(same))
        #expect(!anchor.matches(otherTab))
        #expect(!anchor.matches(search))
        #expect(!anchor.matches(differentRole))
        #expect(!anchor.matches(nil))
    }
}

final class TextInputFocusFixture {
    let app = AXUIElementCreateApplication(100)
    private var nextElementID: pid_t = 101
    private var attributes: [AXUIElement: [String: CFTypeRef]] = [:]
    private var writableAttributes: [AXUIElement: Set<String>] = [:]

    var input: SystemTextInput {
        SystemTextInput(attribute: { self.attributes[$1]?[$0] },
                        isSettable: { self.writableAttributes[$1]?.contains($0) == true })
    }

    func element(role: String, selection: NSRange? = nil, writable: Set<String> = []) -> AXUIElement {
        let element = AXUIElementCreateApplication(nextElementID)
        nextElementID += 1
        set(kAXRoleAttribute, on: element, to: role as CFString)
        if let selection {
            var range = CFRange(location: selection.location, length: selection.length)
            set(kAXSelectedTextRangeAttribute, on: element, to: AXValueCreate(.cfRange, &range))
        }
        writableAttributes[element] = writable
        return element
    }

    func set(_ attribute: String, on element: AXUIElement, to value: CFTypeRef?) {
        attributes[element, default: [:]][attribute] = value
    }
}
