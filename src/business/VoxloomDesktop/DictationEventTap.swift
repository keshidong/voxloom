import AppKit

@MainActor final class DictationEventTap {
    private let filter: (NSEvent) -> Bool
    private let onInterruption: () -> Void
    private var port: CFMachPort?

    private init(filter: @escaping (NSEvent) -> Bool, onInterruption: @escaping () -> Void) {
        self.filter = filter
        self.onInterruption = onInterruption
    }

    static func install(filter: @escaping (NSEvent) -> Bool,
                        onInterruption: @escaping () -> Void) -> (@MainActor () -> Void)? {
        guard let runLoop = CFRunLoopGetMain() else { return nil }
        let tap = DictationEventTap(filter: filter, onInterruption: onInterruption)
        let events = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(CGEventMask(0)) { mask, type in
            mask | (1 << type.rawValue)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: events, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<DictationEventTap>.fromOpaque(context).takeUnretainedValue()
                let consumed = MainActor.assumeIsolated { tap.receive(type, event: event) }
                return consumed ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(tap).toOpaque()),
            let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return nil }
        tap.port = port
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        // Retain the callback context until the source has been removed and the port invalidated.
        return { tap.remove(source, from: runLoop) }
    }

    private func receive(_ type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            onInterruption()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        guard let event = NSEvent(cgEvent: event) else { return false }
        return filter(event)
    }

    private func remove(_ source: CFRunLoopSource, from runLoop: CFRunLoop) {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(port)
        self.port = nil
    }
}
