import AppKit
import Carbon
import SpeechFoundation
import RxSwift

/// Interprets modifier transitions independently of the event source.
@MainActor final class DictationKeyInput {
    let canConfirm: () -> Bool
    let action: (FunctionKeyGesture.Action) -> Void
    private let scheduler: any SchedulerType
    private var gesture = FunctionKeyGesture()
    private var threshold: (any Disposable)?

    init(scheduler: any SchedulerType = MainScheduler.instance, canConfirm: @escaping () -> Bool,
         action: @escaping (FunctionKeyGesture.Action) -> Void) {
        self.scheduler = scheduler
        self.canConfirm = canConfirm
        self.action = action
    }

    func changed(down: Bool, at timestamp: TimeInterval) {
        if down {
            guard gesture.press() else { return }
            threshold = scheduler.scheduleRelative((), dueTime: .milliseconds(180)) { [weak self] _ in
                if let self, let event = gesture.reachHoldThreshold() { action(event) }
                return Disposables.create()
            }
        } else {
            threshold?.dispose()
            threshold = nil
            if let event = gesture.release(at: timestamp, canConfirm: canConfirm()) { action(event) }
        }
    }

    func interrupt() {
        threshold?.dispose()
        threshold = nil
        if let event = gesture.interrupt() { action(event) }
    }
}

/// Observes Fn in the active app without changing the events it receives.
@MainActor final class DictationKeyMonitor {
    typealias ObserveGlobal = @MainActor (@escaping (NSEvent) -> Void) -> (() -> Void)?
    private static let otherModifiers: NSEvent.ModifierFlags = [.shift, .control, .command, .option]
    private static let keyboardEvents: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
    private let input: DictationKeyInput
    private let isTrusted: () -> Bool
    private let observeGlobal: ObserveGlobal
    private var local: Any?
    private var globalObserver: (id: UUID, remove: () -> Void)?
    var isGlobal: Bool { globalObserver != nil }

    init(input: DictationKeyInput, isTrusted: @escaping () -> Bool,
         observeGlobal: @escaping ObserveGlobal = DictationKeyMonitor.installGlobalObserver) {
        self.input = input
        self.isTrusted = isTrusted
        self.observeGlobal = observeGlobal
    }

    func start() {
        if local == nil {
            local = NSEvent.addLocalMonitorForEvents(matching: Self.keyboardEvents) { [weak self] event in
                MainActor.assumeIsolated { self?.receive(event) }
                return event
            }
        }
        refresh()
    }

    func refresh() {
        guard local != nil else { return }
        guard isTrusted() else {
            removeGlobal()
            return
        }
        guard !isGlobal else { return }
        // AppKit sends global observers only events addressed to other apps.
        let id = UUID()
        let remove = observeGlobal { [weak self] event in
            MainActor.assumeIsolated {
                if let self, self.globalObserver?.id == id { self.receive(event) }
            }
        }
        if let remove { globalObserver = (id, remove) }
    }

    func stop() {
        if let local { NSEvent.removeMonitor(local) }
        local = nil
        removeGlobal()
        input.interrupt()
    }

    func receive(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            flagsChanged(keyCode: Int(event.keyCode), flags: event.modifierFlags, at: event.timestamp)
        case .keyDown:
            input.interrupt()
        default: break
        }
    }

    private func flagsChanged(keyCode: Int, flags: NSEvent.ModifierFlags, at timestamp: TimeInterval) {
        guard keyCode == kVK_Function else { input.interrupt(); return }
        let down = flags.contains(.function)
        guard !down || flags.intersection(Self.otherModifiers).isEmpty else { input.interrupt(); return }
        input.changed(down: down, at: timestamp)
    }

    private func removeGlobal() {
        guard let globalObserver else { return }
        self.globalObserver = nil
        globalObserver.remove()
        input.interrupt()
    }

    private static func installGlobalObserver(_ handler: @escaping (NSEvent) -> Void) -> (() -> Void)? {
        guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: keyboardEvents, handler: handler) else { return nil }
        return { NSEvent.removeMonitor(monitor) }
    }
}
