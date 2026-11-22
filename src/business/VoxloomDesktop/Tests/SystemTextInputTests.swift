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
    @Test func readsOnlyABoundedRangeNearTheCaretInALongInput() {
        var requested: NSRange?
        let result = SystemTextInput.excerpt(at: NSRange(location: 5_000, length: 0), length: 10_000,
            readRange: { requested = $0; return "附近文字" },
            readShortValue: { Issue.record("A long field must not be fetched in full"); return nil })
        #expect(requested == NSRange(location: 4_840, length: 240))
        #expect(result == "附近文字")
    }
}
