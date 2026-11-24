import AppKit
import Carbon
import IOKit.hidsystem

struct DictationTrigger: Equatable {
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
    let keyCode: UInt16
    let name: String

    var modifier: Modifier? { Self.modifiers[Int(keyCode)] }

    func permits(_ flags: NSEvent.ModifierFlags) -> Bool {
        guard let modifier else { return flags.isDisjoint(with: Self.chordModifiers) }
        let other = Self.chordModifiers.union(.function).subtracting(modifier.flag)
        return flags.isDisjoint(with: other) && flags.rawValue & UInt(modifier.oppositeMask) == 0
    }

    init?(capturing event: NSEvent) {
        let key = Int(event.keyCode)
        if event.type == .flagsChanged, let modifier = Self.modifiers[key] {
            self.init(keyCode: event.keyCode, name: modifier.name)
            guard modifier.isPressed(event.modifierFlags), permits(event.modifierFlags) else { return nil }
        } else {
            guard event.type == .keyDown, !event.isARepeat, key != kVK_Escape, key != kVK_ANSI_E,
                  Self.modifiers[key] == nil, event.modifierFlags.isDisjoint(with: Self.chordModifiers) else { return nil }
            self.init(keyCode: event.keyCode, name: Self.keyName(event))
        }
    }

    init?(stored: [String: Any]?) {
        guard let code = stored?["keyCode"] as? Int, let keyCode = UInt16(exactly: code),
              let name = stored?["name"] as? String, !name.isEmpty, name.count <= 32,
              code != kVK_Escape, code != kVK_ANSI_E, code != kVK_CapsLock else { return nil }
        self.init(keyCode: keyCode, name: Self.modifiers[code]?.name ?? name)
    }

    var stored: [String: Any] { ["keyCode": Int(keyCode), "name": name] }

    private init(keyCode: UInt16, name: String) {
        self.keyCode = keyCode
        self.name = name
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
