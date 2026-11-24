import AppKit
import Carbon
import IOKit.hidsystem

struct DictationTrigger: Equatable {
    struct Capture {
        private var pendingModifiers: DictationTrigger?

        mutating func receive(_ event: NSEvent) -> DictationTrigger? {
            if event.type == .keyDown {
                guard !event.isARepeat else { return nil }
                pendingModifiers = nil
                return DictationTrigger(capturing: event)
            }
            guard event.type == .flagsChanged, let modifier = DictationTrigger.modifiers[Int(event.keyCode)] else {
                return nil
            }
            if modifier.isPressed(event.modifierFlags) {
                pendingModifiers = DictationTrigger(capturing: event)
            } else if let pendingModifiers, !pendingModifiers.hasRequiredModifiers(event.modifierFlags) {
                self.pendingModifiers = nil
                return pendingModifiers
            }
            return nil
        }
    }

    struct Modifier {
        let name: String
        let flag: NSEvent.ModifierFlags
        var deviceMask: Int32 = 0
        var oppositeMask: Int32 = 0

        func isPressed(_ flags: NSEvent.ModifierFlags) -> Bool {
            let raw = flags.rawValue
            if raw & UInt(deviceMask | oppositeMask) != 0 {
                return raw & UInt(deviceMask) != 0
            }
            return flags.contains(flag)
        }
    }

    static let fn = Self(keyCode: UInt16(kVK_Function), name: "Fn")
    private static let chordModifiers: NSEvent.ModifierFlags = [.shift, .control, .command, .option]
    private static let modifierSymbols: [(NSEvent.ModifierFlags, String)] = [
        (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
    ]
    let keyCode: UInt16?
    private let baseName: String
    let requiredModifiers: NSEvent.ModifierFlags

    var name: String {
        Self.modifierSymbols.compactMap { requiredModifiers.contains($0.0) ? $0.1 : nil }.joined() + baseName
    }

    var modifier: Modifier? { keyCode.flatMap { Self.modifiers[Int($0)] } }
    var isModifierOnly: Bool { keyCode == nil || modifier != nil }

    func hasRequiredModifiers(_ flags: NSEvent.ModifierFlags) -> Bool {
        modifier?.isPressed(flags) ?? flags.isSuperset(of: requiredModifiers)
    }

    func isModifierCombinationPress(_ event: NSEvent) -> Bool {
        guard keyCode == nil, let modifier = Self.modifiers[Int(event.keyCode)] else { return false }
        return requiredModifiers.contains(modifier.flag) && modifier.isPressed(event.modifierFlags)
    }

    func permits(_ flags: NSEvent.ModifierFlags) -> Bool {
        if let modifier {
            let other = Self.chordModifiers.union(.function).subtracting(modifier.flag)
            return flags.isDisjoint(with: other) && flags.rawValue & UInt(modifier.oppositeMask) == 0
        }
        let relevantFlags = keyCode == nil ? Self.chordModifiers.union(.function) : Self.chordModifiers
        return flags.intersection(relevantFlags) == requiredModifiers
    }

    init?(capturing event: NSEvent) {
        let key = Int(event.keyCode)
        let heldModifiers = event.modifierFlags.intersection(Self.chordModifiers)
        if event.type == .flagsChanged, let modifier = Self.modifiers[key] {
            guard modifier.isPressed(event.modifierFlags) else { return nil }
            if heldModifiers.rawValue.nonzeroBitCount > 1 {
                guard !event.modifierFlags.contains(.function) else { return nil }
                self.init(keyCode: nil, name: "", requiredModifiers: heldModifiers)
            } else {
                self.init(keyCode: event.keyCode, name: modifier.name)
                guard permits(event.modifierFlags) else { return nil }
            }
        } else {
            guard event.type == .keyDown, !event.isARepeat, Self.isAllowedKey(key),
                  Self.modifiers[key] == nil else { return nil }
            self.init(keyCode: event.keyCode, name: Self.keyName(event), requiredModifiers: heldModifiers)
        }
    }

    init?(stored: [String: Any]?) {
        guard let stored else { return nil }
        let keyFields: [String: Any]
        let requiredModifiers: NSEvent.ModifierFlags
        if let encoded = stored["combination"] {
            guard let combination = encoded as? [String: Any],
                  let value = combination["modifiers"] as? Int, value > 0,
                  let raw = UInt(exactly: value) else { return nil }
            requiredModifiers = NSEvent.ModifierFlags(rawValue: raw)
            guard Self.chordModifiers.isSuperset(of: requiredModifiers) else { return nil }
            keyFields = combination
        } else {
            requiredModifiers = []
            keyFields = stored
        }
        if keyFields["keyCode"] == nil {
            guard requiredModifiers.rawValue.nonzeroBitCount > 1 else { return nil }
            self.init(keyCode: nil, name: "", requiredModifiers: requiredModifiers)
            return
        }
        guard let code = keyFields["keyCode"] as? Int, let keyCode = UInt16(exactly: code),
              let name = keyFields["name"] as? String, !name.isEmpty, name.count <= 32,
              Self.isAllowedKey(code), requiredModifiers.isEmpty || Self.modifiers[code] == nil else { return nil }
        self.init(keyCode: keyCode, name: Self.modifiers[code]?.name ?? name, requiredModifiers: requiredModifiers)
    }

    var stored: [String: Any] {
        var value: [String: Any] = [:]
        if let keyCode {
            value["keyCode"] = Int(keyCode)
            value["name"] = baseName
        }
        guard !requiredModifiers.isEmpty else { return value }
        value["modifiers"] = Int(requiredModifiers.rawValue)
        return ["combination": value]
    }

    private init(keyCode: UInt16?, name: String, requiredModifiers: NSEvent.ModifierFlags = []) {
        self.keyCode = keyCode
        baseName = name
        self.requiredModifiers = requiredModifiers
    }

    private static func isAllowedKey(_ key: Int) -> Bool {
        key != kVK_Escape && key != kVK_ANSI_E && key != kVK_CapsLock
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "空格"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Forward Delete"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: break
        }
        if let index = functionKeys.firstIndex(of: Int(event.keyCode)) { return "F\(index + 1)" }
        let characters = event.charactersIgnoringModifiers ?? ""
        if let scalar = characters.unicodeScalars.first {
            let value = Int(scalar.value)
            if value >= 32, value < 0xf700 { return String(characters.uppercased().prefix(8)) }
        }
        return "键 \(event.keyCode)"
    }

    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let modifiers: [Int: Modifier] = [
        kVK_Function: .init(name: "Fn", flag: .function),
        kVK_Option: .init(name: "左 Option", flag: .option, deviceMask: NX_DEVICELALTKEYMASK, oppositeMask: NX_DEVICERALTKEYMASK),
        kVK_RightOption: .init(name: "右 Option", flag: .option, deviceMask: NX_DEVICERALTKEYMASK, oppositeMask: NX_DEVICELALTKEYMASK),
        kVK_Control: .init(name: "左 Control", flag: .control, deviceMask: NX_DEVICELCTLKEYMASK, oppositeMask: NX_DEVICERCTLKEYMASK),
        kVK_RightControl: .init(name: "右 Control", flag: .control, deviceMask: NX_DEVICERCTLKEYMASK, oppositeMask: NX_DEVICELCTLKEYMASK),
        kVK_Command: .init(name: "左 Command", flag: .command, deviceMask: NX_DEVICELCMDKEYMASK, oppositeMask: NX_DEVICERCMDKEYMASK),
        kVK_RightCommand: .init(name: "右 Command", flag: .command, deviceMask: NX_DEVICERCMDKEYMASK, oppositeMask: NX_DEVICELCMDKEYMASK),
        kVK_Shift: .init(name: "左 Shift", flag: .shift, deviceMask: NX_DEVICELSHIFTKEYMASK, oppositeMask: NX_DEVICERSHIFTKEYMASK),
        kVK_RightShift: .init(name: "右 Shift", flag: .shift, deviceMask: NX_DEVICERSHIFTKEYMASK, oppositeMask: NX_DEVICELSHIFTKEYMASK),
    ]
}
