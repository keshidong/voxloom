import ApplicationServices
import Foundation
import Testing
@testable import VoxloomDesktop

struct SystemTextInputTests {
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
