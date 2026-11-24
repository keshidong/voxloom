import AppKit
import Carbon
import SpeechFoundation
import RxSwift

/// Interprets modifier transitions independently of the event source.
@MainActor final class DictationKeyInput {
    enum RecordingShortcut: Equatable { case edit, cancel }

    let canConfirm: () -> Bool
    let action: (FunctionKeyGesture.Action) -> Void
    private let recordingShortcut: (RecordingShortcut) -> Bool
    private let scheduler: any SchedulerType
    private var gesture = FunctionKeyGesture()
    private var threshold: (any Disposable)?

    init(scheduler: any SchedulerType = MainScheduler.instance, canConfirm: @escaping () -> Bool,
         recordingShortcut: @escaping (RecordingShortcut) -> Bool = { _ in false },
         action: @escaping (FunctionKeyGesture.Action) -> Void) {
        self.scheduler = scheduler
        self.canConfirm = canConfirm
        self.action = action
        self.recordingShortcut = recordingShortcut
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

    func handle(_ shortcut: RecordingShortcut) -> Bool {
        guard gesture.isHolding, recordingShortcut(shortcut) else { return false }
        if shortcut == .cancel { _ = gesture.interrupt() }
        return true
    }
}

/// Routes the selected push-to-talk key and filters recording shortcuts.
@MainActor final class DictationKeyMonitor {
    typealias RemoveMonitor = @MainActor () -> Void
    typealias ObserveGlobal = @MainActor (@escaping (NSEvent) -> Void) -> RemoveMonitor?
    typealias FilterGlobal = @MainActor (@escaping (NSEvent) -> Bool, @escaping () -> Void) -> RemoveMonitor?
    private enum Hold: Equatable { case key(UInt16), modifiers }
    private static let keyboardEvents: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
    private let input: DictationKeyInput
    private let isTrusted: () -> Bool
    private let observeGlobal: ObserveGlobal
    private let filterGlobal: FilterGlobal
    private var removeLocal: RemoveMonitor?
    private var global: (id: UUID, filtersEvents: Bool, remove: RemoveMonitor)?
    private var consumedKeys: Set<UInt16> = []
    private var trigger: DictationTrigger = .fn
    private var selectingTrigger = false
    private var hold: Hold?
    var isGlobal: Bool { global != nil }

    init(input: DictationKeyInput, isTrusted: @escaping () -> Bool,
         filterGlobal: @escaping FilterGlobal = { _, _ in nil },
         observeGlobal: @escaping ObserveGlobal = DictationKeyMonitor.installGlobalObserver) {
        self.input = input
        self.isTrusted = isTrusted
        self.observeGlobal = observeGlobal
        self.filterGlobal = filterGlobal
    }

    deinit {
        let removeLocal = removeLocal
        let removeGlobal = global?.remove
        if removeLocal != nil || removeGlobal != nil {
            Task { @MainActor in
                removeLocal?()
                removeGlobal?()
            }
        }
    }

    func start() {
        if removeLocal == nil {
            let monitor = NSEvent.addLocalMonitorForEvents(matching: Self.keyboardEvents.union(.keyUp)) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, self.global?.filtersEvents != true else { return false }
                    return self.filter(event)
                }
                return consumed ? nil : event
            }
            if let monitor { removeLocal = { NSEvent.removeMonitor(monitor) } }
        }
        refresh()
    }

    func setTrigger(_ value: DictationTrigger) {
        guard trigger != value else { return }
        trigger = value
        cancelHold()
        if !trigger.isModifierOnly, global?.filtersEvents == false { removeGlobal() }
        refresh()
    }

    func setSelectingTrigger(_ selecting: Bool) {
        selectingTrigger = selecting
        if selecting { cancelHold() }
    }

    func refresh() {
        guard removeLocal != nil else { return }
        guard isTrusted() else {
            removeGlobal()
            return
        }
        guard global?.filtersEvents != true else { return }
        let id = UUID()
        if let remove = filterGlobal({ [weak self] event in
            guard let self, global?.id == id else { return false }
            return filter(event)
        }, { [weak self] in
            guard let self, global?.id == id else { return }
            consumedKeys.removeAll()
            cancelHold()
        }) {
            removeGlobal()
            global = (id, true, remove)
            return
        }
        guard global == nil, trigger.isModifierOnly else { return }
        // AppKit sends global observers only events addressed to other apps.
        let remove = observeGlobal { [weak self] event in
            MainActor.assumeIsolated {
                if let self, self.global?.id == id { self.receive(event) }
            }
        }
        if let remove { global = (id, false, remove) }
    }

    func stop() {
        removeLocal?()
        removeLocal = nil
        removeGlobal()
        consumedKeys.removeAll()
        cancelHold()
    }

    private func filter(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyUp:
            if hold == .key(event.keyCode) { releaseHold(at: event.timestamp) }
            return consumedKeys.remove(event.keyCode) != nil
        case .keyDown:
            guard !selectingTrigger else { return false }
            if event.isARepeat {
                if consumedKeys.contains(event.keyCode) { return true }
            } else {
                consumedKeys.remove(event.keyCode)
                if !trigger.isModifierOnly, event.keyCode == trigger.keyCode, trigger.permits(event.modifierFlags) {
                    consumedKeys.insert(event.keyCode)
                    beginHold(.key(event.keyCode), at: event.timestamp)
                    return true
                }
                if trigger.permits(event.modifierFlags),
                   let shortcut = recordingShortcut(for: event.keyCode), input.handle(shortcut) {
                    consumedKeys.insert(event.keyCode)
                    return true
                }
            }
        default: break
        }
        receive(event)
        return false
    }

    private func recordingShortcut(for keyCode: UInt16) -> DictationKeyInput.RecordingShortcut? {
        switch Int(keyCode) {
        case kVK_ANSI_E: .edit
        case kVK_Escape: .cancel
        default: nil
        }
    }

    func receive(_ event: NSEvent) {
        guard !selectingTrigger else { return }
        switch event.type {
        case .flagsChanged: modifierChanged(event)
        case .keyDown:
            cancelHold()
        default: break
        }
    }

    private func modifierChanged(_ event: NSEvent) {
        let flags = event.modifierFlags
        if !trigger.requiredModifiers.isEmpty {
            if hold != nil {
                if !trigger.hasRequiredModifiers(flags) { releaseHold(at: event.timestamp) }
                else if !trigger.permits(flags) { cancelHold() }
            } else if trigger.permits(flags), trigger.isModifierCombinationPress(event) {
                beginHold(.modifiers, at: event.timestamp)
            }
            return
        }

        guard event.keyCode == trigger.keyCode, let modifier = trigger.modifier else {
            cancelHold()
            return
        }
        if !modifier.isPressed(flags) { releaseHold(at: event.timestamp) }
        else if trigger.permits(flags) { beginHold(.modifiers, at: event.timestamp) }
        else { cancelHold() }
    }

    private func beginHold(_ value: Hold, at timestamp: TimeInterval) {
        hold = value
        input.changed(down: true, at: timestamp)
    }

    private func releaseHold(at timestamp: TimeInterval) {
        hold = nil
        input.changed(down: false, at: timestamp)
    }

    private func cancelHold() {
        hold = nil
        input.interrupt()
    }

    private func removeGlobal() {
        guard let global else { return }
        self.global = nil
        global.remove()
        consumedKeys.removeAll()
        cancelHold()
    }

    private static func installGlobalObserver(_ handler: @escaping (NSEvent) -> Void) -> RemoveMonitor? {
        guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: keyboardEvents, handler: handler) else { return nil }
        return { NSEvent.removeMonitor(monitor) }
    }
}
