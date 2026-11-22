import SpeechFoundation
import Testing

struct DictationShortcutTests {
    @Test func functionHoldStartsAndReleasesOnceWithDoubleTapForDraft() {
        var key = FunctionKeyGesture()
        #expect(key.press() == true)
        #expect(key.press() == false)
        #expect(key.reachHoldThreshold() == .start)
        #expect(key.reachHoldThreshold() == nil)
        #expect(key.release(at: 1, canConfirm: true) == .stop)
        #expect(key.release(at: 1.1, canConfirm: true) == nil)

        #expect(key.press() == true)
        #expect(key.release(at: 2, canConfirm: true) == nil)
        #expect(key.press() == true)
        #expect(key.release(at: 2.2, canConfirm: true) == .confirm)
        #expect(key.reachHoldThreshold() == nil)
    }

    @Test func interruptedOrExpiredFunctionTapsCannotStartOrConfirm() {
        var key = FunctionKeyGesture()
        #expect(key.press() == true)
        #expect(key.release(at: 0, canConfirm: false) == nil)
        #expect(key.press() == true)
        #expect(key.release(at: 0.2, canConfirm: true) == nil)
        #expect(key.press() == true)
        #expect(key.release(at: 0.6, canConfirm: true) == nil)
        #expect(key.press() == true)
        #expect(key.interrupt() == nil)
        #expect(key.reachHoldThreshold() == nil)
        #expect(key.press() == true)
        #expect(key.release(at: 0.7, canConfirm: true) == nil)
        #expect(key.press() == true)
        #expect(key.reachHoldThreshold() == .start)
        #expect(key.interrupt() == .interrupted)
        #expect(key.release(at: 0.9, canConfirm: true) == nil)
        #expect(key.interrupt() == nil)
    }

    @Test func startsOnOnePressAndConfirmsOnTwoNewPressesWithinTheWindow() {
        var shortcut = DictationShortcut()
        #expect(shortcut.press(at: 0, isEditing: false) == .start)
        #expect(shortcut.press(at: 0.1, isEditing: true) == nil)
        #expect(shortcut.press(at: 0.5, isEditing: true) == nil)
        #expect(shortcut.press(at: 0.75, isEditing: true) == .confirm)
        #expect(shortcut.press(at: 0.8, isEditing: true) == nil)
        #expect(shortcut.press(at: 0.9, isEditing: false) == .start)
        #expect(shortcut.press(at: 1, isEditing: true) == nil)
    }
}
