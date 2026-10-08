// Translates macOS key events into the Windows-style key events that PIME
// backends expect (see KeyEvent in python/textService.py).
//
// Written with assistance from Claude Code (Claude Opus 5.5).

/// Windows virtual-key codes used by the backends (python/keycodes.py).
public enum VK {
    public static let back = 0x08
    public static let tab = 0x09
    public static let clear = 0x0C
    public static let returnKey = 0x0D
    public static let shift = 0x10
    public static let control = 0x11
    public static let menu = 0x12  // Alt (Option on macOS)
    public static let capital = 0x14  // Caps Lock
    public static let escape = 0x1B
    public static let space = 0x20
    public static let prior = 0x21  // Page Up
    public static let next = 0x22  // Page Down
    public static let end = 0x23
    public static let home = 0x24
    public static let left = 0x25
    public static let up = 0x26
    public static let right = 0x27
    public static let down = 0x28
    public static let insert = 0x2D
    public static let delete = 0x2E
    public static let lwin = 0x5B  // Command on macOS
    public static let rwin = 0x5C
    public static let numpad0 = 0x60
    public static let multiply = 0x6A
    public static let add = 0x6B
    public static let subtract = 0x6D
    public static let decimal = 0x6E
    public static let divide = 0x6F
    public static let f1 = 0x70
    public static let numlock = 0x90
    public static let oemNecEqual = 0x92  // '=' on the numpad
    public static let lshift = 0xA0
    public static let rshift = 0xA1
    public static let lcontrol = 0xA2
    public static let rcontrol = 0xA3
    public static let lmenu = 0xA4
    public static let rmenu = 0xA5
    public static let oem1 = 0xBA  // ;:
    public static let oemPlus = 0xBB  // =+
    public static let oemComma = 0xBC  // ,<
    public static let oemMinus = 0xBD  // -_
    public static let oemPeriod = 0xBE  // .>
    public static let oem2 = 0xBF  // /?
    public static let oem3 = 0xC0  // `~
    public static let oem4 = 0xDB  // [{
    public static let oem5 = 0xDC  // \|
    public static let oem6 = 0xDD  // ]}
    public static let oem7 = 0xDE  // '"
}

/// Keyboard modifiers used by TSF preserved keys (TF_MOD_* in msctf.h).
public enum TFModifier {
    public static let alt = 0x0001
    public static let control = 0x0002
    public static let shift = 0x0004
}

/// Modifier keys held down (or toggled, for Caps Lock) during a key event.
public struct ModifierKeys: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let leftShift = ModifierKeys(rawValue: 1 << 0)
    public static let rightShift = ModifierKeys(rawValue: 1 << 1)
    public static let leftControl = ModifierKeys(rawValue: 1 << 2)
    public static let rightControl = ModifierKeys(rawValue: 1 << 3)
    public static let leftOption = ModifierKeys(rawValue: 1 << 4)
    public static let rightOption = ModifierKeys(rawValue: 1 << 5)
    public static let leftCommand = ModifierKeys(rawValue: 1 << 6)
    public static let rightCommand = ModifierKeys(rawValue: 1 << 7)
    public static let capsLock = ModifierKeys(rawValue: 1 << 8)

    public static let shift: ModifierKeys = [.leftShift, .rightShift]
    public static let control: ModifierKeys = [.leftControl, .rightControl]
    public static let option: ModifierKeys = [.leftOption, .rightOption]
    public static let command: ModifierKeys = [.leftCommand, .rightCommand]

    /// Creates the set from `NSEvent.ModifierFlags.rawValue`, which carries
    /// the device-independent flags plus the device-dependent NX_DEVICE*
    /// bits that tell the left and right keys apart.
    public init(eventFlags: UInt) {
        var keys: ModifierKeys = []
        func add(_ independent: UInt, _ leftBit: UInt, _ rightBit: UInt,
                 _ left: ModifierKeys, _ right: ModifierKeys) {
            guard eventFlags & independent != 0 else { return }
            let hasLeft = eventFlags & leftBit != 0
            let hasRight = eventFlags & rightBit != 0
            if hasLeft || !hasRight { keys.insert(left) }
            if hasRight { keys.insert(right) }
        }
        // NSEvent.ModifierFlags and NX_DEVICE* masks from IOLLEvent.h
        add(1 << 17, 0x0002, 0x0004, .leftShift, .rightShift)
        add(1 << 18, 0x0001, 0x2000, .leftControl, .rightControl)
        add(1 << 19, 0x0020, 0x0040, .leftOption, .rightOption)
        add(1 << 20, 0x0008, 0x0010, .leftCommand, .rightCommand)
        if eventFlags & (1 << 16) != 0 { keys.insert(.capsLock) }
        self = keys
    }

    /// The TF_MOD_* flags used to match preserved keys.
    public var tfModifiers: Int {
        var mods = 0
        if !isDisjoint(with: .option) { mods |= TFModifier.alt }
        if !isDisjoint(with: .control) { mods |= TFModifier.control }
        if !isDisjoint(with: .shift) { mods |= TFModifier.shift }
        return mods
    }
}

/// A key event in the format of PIME's JSON protocol.
public struct KeyEventData: Equatable, Sendable {
    public var charCode: Int
    public var keyCode: Int
    public var repeatCount: Int
    public var scanCode: Int
    public var isExtended: Bool
    /// Same layout as Win32 GetKeyboardState(): bit 7 = down, bit 0 = toggled.
    public var keyStates: [UInt8]

    /// The key event fields of a filterKeyDown/onKeyDown/... request.
    public var requestFields: [String: Any] {
        [
            "charCode": charCode,
            "keyCode": keyCode,
            "repeatCount": repeatCount,
            "scanCode": scanCode,
            "isExtended": isExtended,
            "keyStates": keyStates.map { Int($0) },
        ]
    }

    /// Converts a macOS key event. Returns nil for keys PIME does not know.
    ///
    /// `charCode` mimics Win32 ToAscii() the way libIME calls it: Shift and
    /// Caps Lock are applied, Ctrl is ignored. Characters always come from
    /// the US layout because bopomofo keyboard layouts are defined by key
    /// positions, not by the characters of the active macOS layout.
    public static func make(macKeyCode: UInt16, modifiers: ModifierKeys,
                            isKeyDown: Bool, isRepeat: Bool = false) -> KeyEventData? {
        guard let info = macKeys[macKeyCode] else { return nil }

        var charCode = 0
        if let normal = info.normal {
            var ch = modifiers.isDisjoint(with: .shift) ? normal : (info.shifted ?? normal)
            if modifiers.contains(.capsLock) {
                if ch >= 0x61 && ch <= 0x7A {
                    ch -= 0x20
                } else if ch >= 0x41 && ch <= 0x5A {
                    ch += 0x20
                }
            }
            charCode = Int(ch)
        }

        var states = [UInt8](repeating: 0, count: 256)
        func press(_ vk: Int) { states[vk] |= 0x80 }
        if modifiers.contains(.leftShift) { press(VK.shift); press(VK.lshift) }
        if modifiers.contains(.rightShift) { press(VK.shift); press(VK.rshift) }
        if modifiers.contains(.leftControl) { press(VK.control); press(VK.lcontrol) }
        if modifiers.contains(.rightControl) { press(VK.control); press(VK.rcontrol) }
        if modifiers.contains(.leftOption) { press(VK.menu); press(VK.lmenu) }
        if modifiers.contains(.rightOption) { press(VK.menu); press(VK.rmenu) }
        if modifiers.contains(.leftCommand) { press(VK.lwin) }
        if modifiers.contains(.rightCommand) { press(VK.rwin) }
        if modifiers.contains(.capsLock) { states[VK.capital] |= 0x01 }
        // Mac keypads always type digits, which is NumLock-on on Windows.
        states[VK.numlock] |= 0x01
        if isKeyDown {
            press(info.vk)
        } else {
            states[info.vk] &= ~0x80
        }

        return KeyEventData(charCode: charCode, keyCode: info.vk,
                            repeatCount: 1, scanCode: 0,
                            isExtended: info.isExtended, keyStates: states)
    }
}

private struct MacKeyInfo {
    var vk: Int
    var normal: UInt8? = nil
    var shifted: UInt8? = nil
    var isExtended = false
}

private func char(_ vk: Int, _ normal: Character, _ shifted: Character) -> MacKeyInfo {
    MacKeyInfo(vk: vk, normal: normal.asciiValue, shifted: shifted.asciiValue)
}

private func letter(_ upper: Character) -> MacKeyInfo {
    let code = upper.asciiValue!
    return MacKeyInfo(vk: Int(code), normal: code + 0x20, shifted: code)
}

private func keypad(_ vk: Int, _ ch: Character, isExtended: Bool = false) -> MacKeyInfo {
    MacKeyInfo(vk: vk, normal: ch.asciiValue, shifted: ch.asciiValue, isExtended: isExtended)
}

private func control(_ vk: Int, _ code: UInt8? = nil, isExtended: Bool = false) -> MacKeyInfo {
    MacKeyInfo(vk: vk, normal: code, shifted: code, isExtended: isExtended)
}

// Keyed by macOS virtual key codes (kVK_* in HIToolbox/Events.h).
private let macKeys: [UInt16: MacKeyInfo] = [
    0x00: letter("A"), 0x01: letter("S"), 0x02: letter("D"), 0x03: letter("F"),
    0x04: letter("H"), 0x05: letter("G"), 0x06: letter("Z"), 0x07: letter("X"),
    0x08: letter("C"), 0x09: letter("V"), 0x0B: letter("B"), 0x0C: letter("Q"),
    0x0D: letter("W"), 0x0E: letter("E"), 0x0F: letter("R"), 0x10: letter("Y"),
    0x11: letter("T"), 0x1F: letter("O"), 0x20: letter("U"), 0x22: letter("I"),
    0x23: letter("P"), 0x25: letter("L"), 0x26: letter("J"), 0x28: letter("K"),
    0x2D: letter("N"), 0x2E: letter("M"),

    0x12: char(0x31, "1", "!"), 0x13: char(0x32, "2", "@"), 0x14: char(0x33, "3", "#"),
    0x15: char(0x34, "4", "$"), 0x17: char(0x35, "5", "%"), 0x16: char(0x36, "6", "^"),
    0x1A: char(0x37, "7", "&"), 0x1C: char(0x38, "8", "*"), 0x19: char(0x39, "9", "("),
    0x1D: char(0x30, "0", ")"),

    0x18: char(VK.oemPlus, "=", "+"), 0x1B: char(VK.oemMinus, "-", "_"),
    0x1E: char(VK.oem6, "]", "}"), 0x21: char(VK.oem4, "[", "{"),
    0x27: char(VK.oem7, "'", "\""), 0x29: char(VK.oem1, ";", ":"),
    0x2A: char(VK.oem5, "\\", "|"), 0x2B: char(VK.oemComma, ",", "<"),
    0x2C: char(VK.oem2, "/", "?"), 0x2F: char(VK.oemPeriod, ".", ">"),
    0x32: char(VK.oem3, "`", "~"),
    0x31: char(VK.space, " ", " "),

    0x24: control(VK.returnKey, 0x0D),
    0x30: control(VK.tab, 0x09),
    0x33: control(VK.back, 0x08),  // kVK_Delete is Backspace
    0x35: control(VK.escape, 0x1B),

    0x52: keypad(VK.numpad0, "0"), 0x53: keypad(VK.numpad0 + 1, "1"),
    0x54: keypad(VK.numpad0 + 2, "2"), 0x55: keypad(VK.numpad0 + 3, "3"),
    0x56: keypad(VK.numpad0 + 4, "4"), 0x57: keypad(VK.numpad0 + 5, "5"),
    0x58: keypad(VK.numpad0 + 6, "6"), 0x59: keypad(VK.numpad0 + 7, "7"),
    0x5B: keypad(VK.numpad0 + 8, "8"), 0x5C: keypad(VK.numpad0 + 9, "9"),
    0x41: keypad(VK.decimal, "."), 0x43: keypad(VK.multiply, "*"),
    0x45: keypad(VK.add, "+"), 0x4E: keypad(VK.subtract, "-"),
    0x4B: keypad(VK.divide, "/", isExtended: true),
    0x51: keypad(VK.oemNecEqual, "="),
    0x4C: control(VK.returnKey, 0x0D, isExtended: true),  // keypad Enter
    0x47: control(VK.clear),

    0x73: control(VK.home, isExtended: true), 0x77: control(VK.end, isExtended: true),
    0x74: control(VK.prior, isExtended: true), 0x79: control(VK.next, isExtended: true),
    0x75: control(VK.delete, isExtended: true), 0x72: control(VK.insert, isExtended: true),
    0x7B: control(VK.left, isExtended: true), 0x7C: control(VK.right, isExtended: true),
    0x7D: control(VK.down, isExtended: true), 0x7E: control(VK.up, isExtended: true),

    0x7A: control(VK.f1), 0x78: control(VK.f1 + 1), 0x63: control(VK.f1 + 2),
    0x76: control(VK.f1 + 3), 0x60: control(VK.f1 + 4), 0x61: control(VK.f1 + 5),
    0x62: control(VK.f1 + 6), 0x64: control(VK.f1 + 7), 0x65: control(VK.f1 + 8),
    0x6D: control(VK.f1 + 9), 0x67: control(VK.f1 + 10), 0x6F: control(VK.f1 + 11),
    0x69: control(VK.f1 + 12), 0x6B: control(VK.f1 + 13), 0x71: control(VK.f1 + 14),
    0x6A: control(VK.f1 + 15), 0x40: control(VK.f1 + 16), 0x4F: control(VK.f1 + 17),
    0x50: control(VK.f1 + 18), 0x5A: control(VK.f1 + 19),

    // Modifier keys (delivered as flagsChanged events)
    0x38: control(VK.shift), 0x3C: control(VK.shift),
    0x3B: control(VK.control), 0x3E: control(VK.control, isExtended: true),
    0x3A: control(VK.menu), 0x3D: control(VK.menu, isExtended: true),
    0x37: control(VK.lwin, isExtended: true), 0x36: control(VK.rwin, isExtended: true),
    0x39: control(VK.capital),
]

/// macOS virtual key codes of modifier keys, and the modifier each one sets.
public let macModifierKeys: [UInt16: ModifierKeys] = [
    0x38: .leftShift, 0x3C: .rightShift,
    0x3B: .leftControl, 0x3E: .rightControl,
    0x3A: .leftOption, 0x3D: .rightOption,
    0x37: .leftCommand, 0x36: .rightCommand,
    0x39: .capsLock,
]
