import AppKit
import Carbon

@MainActor final class DictationWindow: NSWindow {
    var onFunctionPress: ((TimeInterval) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged, event.keyCode == kVK_Function, event.modifierFlags.contains(.function) {
            onFunctionPress?(event.timestamp)
        }
        super.sendEvent(event)
    }
}
