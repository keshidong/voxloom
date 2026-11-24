import ApplicationServices
import Foundation
import Testing
@testable import VoxloomDesktop

struct SystemTextInputTests {
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
