import AppKit
import Carbon
import IOKit.hidsystem
import RxSwift
import SpeechFoundation
import Testing
@testable import VoxloomDesktop

@MainActor struct KeyboardBoundaryTests {
    @Test func chosenFunctionKeyIsSavedAndConsumesAnUnmodifiedHoldAndRelease() throws {
        _ = NSApplication.shared
        let origin = Date(timeIntervalSince1970: 0)
        let clock = HistoricalScheduler(initialClock: origin)
        var actions: [FunctionKeyGesture.Action] = []
        let input = DictationKeyInput(scheduler: clock, canConfirm: { false }, action: { actions.append($0) })
        var filter: ((NSEvent) -> Bool)?
        let monitor = DictationKeyMonitor(input: input, isTrusted: { true }, filterGlobal: { handler, _ in
            filter = handler
            return { filter = nil }
        })
        let press = try keyEvent(.keyDown, key: kVK_F6)
        let release = try keyEvent(.keyUp, key: kVK_F6)
        var settings = DictationSettings()
        settings.trigger = try #require(DictationTrigger(capturing: press))
        let domain = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        settings.save(to: defaults)
        let restored = DictationSettings(defaults: defaults)
        #expect(restored.trigger == settings.trigger)
        #expect(restored.trigger.name == "F6")
        monitor.setTrigger(restored.trigger)
        monitor.start()
        defer { monitor.stop() }
        let deliver = try #require(filter)
        #expect(!deliver(try keyEvent(.keyDown, key: kVK_F6, flags: .command)))
        #expect(!deliver(release))
        clock.advanceTo(origin.addingTimeInterval(0.2))
        #expect(actions.isEmpty)
        #expect(deliver(press))
        clock.advanceTo(origin.addingTimeInterval(0.4))
        #expect(actions == [.start])
        #expect(deliver(try keyEvent(.keyDown, key: kVK_F6, repeated: true)))
        #expect(deliver(release))
        #expect(actions == [.start, .stop])
    }

    @Test func selectedRightOptionStartsAndStopsDictationWithoutUsingFnOrLeftOption() throws {
        _ = NSApplication.shared
        let initial = Date(timeIntervalSince1970: 0)
        let clock = HistoricalScheduler(initialClock: initial)
        var actions: [FunctionKeyGesture.Action] = []
        var edited = false
        let input = DictationKeyInput(scheduler: clock, canConfirm: { false },
            recordingShortcut: { edited = $0 == .edit; return edited }, action: { actions.append($0) })
        var filter: ((NSEvent) -> Bool)?
        let monitor = DictationKeyMonitor(input: input, isTrusted: { true }, filterGlobal: { handler, _ in
            filter = handler
            return { filter = nil }
        })
        let left = NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICELALTKEYMASK))
        let right = NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICERALTKEYMASK))
        let rightPressed = try keyEvent(.flagsChanged, key: kVK_RightOption, flags: [.option, right])
        let rightReleased = try keyEvent(.flagsChanged, key: kVK_RightOption)
        monitor.setTrigger(try #require(DictationTrigger(capturing: rightPressed)))
        monitor.start()
        defer { monitor.stop() }
        let deliver = try #require(filter)

        #expect(!deliver(try keyEvent(.flagsChanged, key: kVK_Function, flags: .function)))
        #expect(!deliver(try keyEvent(.flagsChanged, key: kVK_Option, flags: [.option, left])))
        clock.advanceTo(initial.addingTimeInterval(0.2))
        #expect(actions.isEmpty)
        #expect(!deliver(try keyEvent(.flagsChanged, key: kVK_RightOption, flags: [.option, right, left])))
        clock.advanceTo(initial.addingTimeInterval(0.4))
        #expect(actions.isEmpty)
        #expect(!deliver(try keyEvent(.flagsChanged, key: kVK_RightOption, flags: [.option, left])))
        clock.advanceTo(initial.addingTimeInterval(0.6))
        #expect(actions.isEmpty)

        #expect(!deliver(rightPressed))
        clock.advanceTo(initial.addingTimeInterval(0.8))
        #expect(actions == [.start])
        #expect(deliver(try keyEvent(.keyDown, key: kVK_ANSI_E, flags: [.option, right])))
        #expect(edited)
        #expect(!deliver(rightReleased))
        #expect(actions == [.start, .stop])
    }

    @Test func editChordFiltersBothKeyEventsWithoutEndingTheHold() throws {
        _ = NSApplication.shared
        let initial = Date(timeIntervalSince1970: 0)
        let clock = HistoricalScheduler(initialClock: initial)
        var actions: [FunctionKeyGesture.Action] = []
        var shortcuts: [DictationKeyInput.RecordingShortcut] = []
        let input = DictationKeyInput(scheduler: clock, canConfirm: { false }, recordingShortcut: {
            shortcuts.append($0)
            return true
        }, action: { actions.append($0) })
        var filter: ((NSEvent) -> Bool)?
        let monitor = DictationKeyMonitor(input: input, isTrusted: { true }, filterGlobal: { handler, _ in
            filter = handler
            return { filter = nil }
        }, observeGlobal: { _ in nil })
        monitor.start()
        defer { monitor.stop() }
        let deliver = try #require(filter)
        let press = try keyEvent(.flagsChanged, key: kVK_Function, flags: .function)
        let release = try keyEvent(.flagsChanged, key: kVK_Function)
        let edit = try keyEvent(.keyDown, key: kVK_ANSI_E)
        let repeatedEdit = try keyEvent(.keyDown, key: kVK_ANSI_E, flags: .function, repeated: true)
        let editUp = try keyEvent(.keyUp, key: kVK_ANSI_E)

        #expect(!deliver(try keyEvent(.keyDown, key: kVK_ANSI_E)))
        #expect(!deliver(press))
        clock.advanceTo(initial.addingTimeInterval(0.2))
        #expect(deliver(edit))
        #expect(deliver(repeatedEdit))
        #expect(actions == [.start])
        #expect(shortcuts == [.edit])
        #expect(!deliver(release))
        #expect(deliver(editUp))
        #expect(actions == [.start, .stop])
        #expect(!deliver(try keyEvent(.keyDown, key: kVK_ANSI_E)))
    }

    @Test func cancelChordPreventsReleaseFromStoppingOrConfirmingTheDraft() throws {
        _ = NSApplication.shared
        let initial = Date(timeIntervalSince1970: 0)
        let clock = HistoricalScheduler(initialClock: initial)
        var actions: [FunctionKeyGesture.Action] = []
        var shortcuts: [DictationKeyInput.RecordingShortcut] = []
        let input = DictationKeyInput(scheduler: clock, canConfirm: { true }, recordingShortcut: {
            shortcuts.append($0)
            return true
        }, action: { actions.append($0) })
        input.changed(down: true, at: 0)
        clock.advanceTo(initial.addingTimeInterval(0.2))
        #expect(input.handle(.cancel))
        #expect(!input.handle(.edit))
        input.changed(down: false, at: 0.22)
        #expect(actions == [.start])
        #expect(shortcuts == [.cancel])

        input.changed(down: true, at: 0.3)
        clock.advanceTo(initial.addingTimeInterval(0.5))
        input.changed(down: false, at: 0.51)
        #expect(actions == [.start, .start, .stop])
    }

    @Test func accessibilityEnablesGlobalFnAndRevocationEndsAnActiveHold() throws {
        _ = NSApplication.shared
        let initial = Date(timeIntervalSince1970: 0)
        let clock = HistoricalScheduler(initialClock: initial)
        var events: [FunctionKeyGesture.Action] = []
        let input = DictationKeyInput(scheduler: clock, canConfirm: { false }, action: { events.append($0) })
        var trusted = false
        var globalHandler: ((NSEvent) -> Void)?
        let monitor = DictationKeyMonitor(input: input, isTrusted: { trusted }, observeGlobal: { handler in
            globalHandler = handler
            return { globalHandler = nil }
        })
        monitor.start()
        defer { monitor.stop() }
        #expect(!monitor.isGlobal)
        #expect(globalHandler == nil)
        trusted = true
        monitor.refresh()
        #expect(monitor.isGlobal)
        let deliver = try #require(globalHandler)

        deliver(try keyEvent(.flagsChanged, key: kVK_Option, flags: .option))
        clock.advanceTo(initial.addingTimeInterval(0.2))
        #expect(events.isEmpty)
        deliver(try keyEvent(.flagsChanged, key: kVK_RightOption, flags: .option))
        clock.advanceTo(initial.addingTimeInterval(0.4))
        #expect(events.isEmpty)
        let press = try keyEvent(.flagsChanged, key: kVK_Function, flags: .function)
        let release = try keyEvent(.flagsChanged, key: kVK_Function)
        deliver(press)
        clock.advanceTo(initial.addingTimeInterval(0.6))
        #expect(events == [.start])
        deliver(release)
        #expect(events == [.start, .stop])
        deliver(press)
        clock.advanceTo(initial.addingTimeInterval(0.8))
        trusted = false
        monitor.refresh()
        #expect(!monitor.isGlobal)
        #expect(globalHandler == nil)
        #expect(events == [.start, .stop, .start, .interrupted])
        deliver(press)
        clock.advanceTo(initial.addingTimeInterval(1))
        deliver(release)
        #expect(events == [.start, .stop, .start, .interrupted])

        trusted = true
        monitor.refresh()
        let newDeliver = try #require(globalHandler)
        deliver(press)
        clock.advanceTo(initial.addingTimeInterval(1.2))
        deliver(release)
        #expect(events == [.start, .stop, .start, .interrupted])
        newDeliver(press)
        clock.advanceTo(initial.addingTimeInterval(1.4))
        newDeliver(release)
        #expect(events == [.start, .stop, .start, .interrupted, .start, .stop])
    }

    @Test func inputUsesTheHoldThresholdAndRejectsReleasedTimers() {
        let origin = Date(timeIntervalSince1970: 0)
        let clock = HistoricalScheduler(initialClock: origin)
        var events: [FunctionKeyGesture.Action] = []
        let input = DictationKeyInput(scheduler: clock, canConfirm: { true }, action: { events.append($0) })
        input.changed(down: true, at: 0)
        input.changed(down: false, at: 0.05)
        clock.advanceTo(origin.addingTimeInterval(0.19))
        #expect(events.isEmpty)
        input.changed(down: true, at: 0.2)
        input.changed(down: false, at: 0.25)
        #expect(events == [.confirm])
        input.changed(down: true, at: 0.3)
        input.changed(down: true, at: 0.35)
        clock.advanceTo(origin.addingTimeInterval(0.5))
        #expect(events == [.confirm, .start])
        input.interrupt()
        #expect(events == [.confirm, .start, .interrupted])
    }

    @Test func fnChordsCannotStartDictationOrCombineWithATap() throws {
        let origin = Date(timeIntervalSince1970: 0)
        let clock = HistoricalScheduler(initialClock: origin)
        var actions: [FunctionKeyGesture.Action] = []
        let input = DictationKeyInput(scheduler: clock, canConfirm: { true }, action: { actions.append($0) })
        let monitor = DictationKeyMonitor(input: input, isTrusted: { false })
        let press = try keyEvent(.flagsChanged, key: kVK_Function, flags: .function)
        let release = try keyEvent(.flagsChanged, key: kVK_Function)
        let letter = try keyEvent(.keyDown, key: kVK_ANSI_E)

        monitor.receive(press)
        monitor.receive(letter)
        clock.advanceTo(origin.addingTimeInterval(0.2))
        #expect(actions.isEmpty)
        monitor.receive(release)

        monitor.receive(press)
        monitor.receive(release)
        #expect(actions.isEmpty)

        monitor.receive(try keyEvent(.flagsChanged, key: kVK_Function, flags: [.function, .shift]))
        clock.advanceTo(origin.addingTimeInterval(0.4))
        #expect(actions.isEmpty)
        monitor.receive(try keyEvent(.flagsChanged, key: kVK_Function, flags: .shift))

        monitor.receive(press)
        clock.advanceTo(origin.addingTimeInterval(0.6))
        #expect(actions == [.start])
        monitor.receive(letter)
        #expect(actions == [.start, .interrupted])
    }

    @Test func localAppKitEventsUseTheSameFnGesturesWithoutGlobalPermission() throws {
        let app = NSApplication.shared
        let origin = Date(timeIntervalSince1970: 0)
        let clock = HistoricalScheduler(initialClock: origin)
        var actions: [FunctionKeyGesture.Action] = []
        let input = DictationKeyInput(scheduler: clock, canConfirm: { true }, action: { actions.append($0) })
        let monitor = DictationKeyMonitor(input: input, isTrusted: { false })
        monitor.start()
        defer { monitor.stop() }

        func send(_ type: NSEvent.EventType, key: Int, flags: NSEvent.ModifierFlags, at time: TimeInterval) throws {
            app.sendEvent(try keyEvent(type, key: key, flags: flags, at: time))
        }

        try send(.flagsChanged, key: kVK_Function, flags: .function, at: 1)
        try send(.keyDown, key: kVK_ANSI_K, flags: .function, at: 1.05)
        clock.advanceTo(origin.addingTimeInterval(0.2))
        try send(.flagsChanged, key: kVK_Function, flags: [], at: 1.2)
        #expect(actions.isEmpty)

        try send(.flagsChanged, key: kVK_Function, flags: .function, at: 2)
        try send(.flagsChanged, key: kVK_Function, flags: [], at: 2.05)
        try send(.flagsChanged, key: kVK_Function, flags: .function, at: 2.2)
        try send(.flagsChanged, key: kVK_Function, flags: [], at: 2.25)
        #expect(actions == [.confirm])
    }

    @Test func anEditableSelectionIsReplacedAndTheClipboardIsRestored() {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("原剪贴板", forType: .string)
        var keyEvents: [CGEventType] = []
        let paste = SystemPaste(board: board) { event, pid in
            #expect(pid == 101)
            #expect(event.flags.contains(.maskCommand))
            keyEvents.append(event.type)
        }
        let target = NSTextView()
        target.string = "请保留旧词之后的内容"
        target.setSelectedRange(NSRange(location: 3, length: 2))
        #expect(paste.paste("新词", to: 101))
        #expect(keyEvents == [.keyDown, .keyUp])
        #expect(target.readSelection(from: board, type: .string))
        #expect(target.string == "请保留新词之后的内容")
        paste.restoreClipboard()
        #expect(board.string(forType: .string) == "原剪贴板")

        target.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(paste.paste("前缀 ", to: 101))
        #expect(target.readSelection(from: board, type: .string))
        #expect(target.string == "前缀 请保留新词之后的内容")
        #expect(paste.stageClipboard("草稿"))
        #expect(paste.stageClipboard("另一段草稿"))
        board.clearContents()
        board.setString("用户刚复制的内容", forType: .string)
        paste.restoreClipboard()
        #expect(board.string(forType: .string) == "用户刚复制的内容")
    }

    private func keyEvent(_ type: NSEvent.EventType, key: Int, flags: NSEvent.ModifierFlags = [],
                          at time: TimeInterval = 0, repeated: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: time, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: repeated, keyCode: UInt16(key)))
    }
}
