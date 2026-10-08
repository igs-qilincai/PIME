// Written with assistance from Claude Code (Claude Opus 5.5).

import Testing
@testable import PIMECore

// NSEvent.ModifierFlags raw values and NX_DEVICE* bits
private let shiftFlag: UInt = 1 << 17
private let controlFlag: UInt = 1 << 18
private let optionFlag: UInt = 1 << 19
private let commandFlag: UInt = 1 << 20
private let capsLockFlag: UInt = 1 << 16
private let deviceLeftShift: UInt = 0x0002
private let deviceRightShift: UInt = 0x0004

@Suite struct ModifierKeysTests {
    @Test func distinguishesLeftAndRightShift() {
        #expect(ModifierKeys(eventFlags: shiftFlag | deviceLeftShift) == .leftShift)
        #expect(ModifierKeys(eventFlags: shiftFlag | deviceRightShift) == .rightShift)
        #expect(ModifierKeys(eventFlags: shiftFlag | deviceLeftShift | deviceRightShift) == .shift)
    }

    @Test func defaultsToLeftWithoutDeviceBits() {
        #expect(ModifierKeys(eventFlags: shiftFlag | controlFlag | optionFlag | commandFlag)
            == [.leftShift, .leftControl, .leftOption, .leftCommand])
    }

    @Test func ignoresDeviceBitsOfReleasedKeys() {
        #expect(ModifierKeys(eventFlags: deviceLeftShift) == [])
    }

    @Test func capsLock() {
        #expect(ModifierKeys(eventFlags: capsLockFlag) == .capsLock)
    }

    @Test func tfModifiers() {
        #expect(ModifierKeys.rightShift.tfModifiers == TFModifier.shift)
        #expect(ModifierKeys([.leftControl, .leftOption]).tfModifiers == TFModifier.control | TFModifier.alt)
        #expect(ModifierKeys([.leftCommand, .capsLock]).tfModifiers == 0)
    }
}

@Suite struct KeyEventDataTests {
    let kVK_ANSI_A: UInt16 = 0x00
    let kVK_ANSI_1: UInt16 = 0x12
    let kVK_ANSI_Semicolon: UInt16 = 0x29
    let kVK_Space: UInt16 = 0x31
    let kVK_Return: UInt16 = 0x24
    let kVK_LeftArrow: UInt16 = 0x7B
    let kVK_Keypad5: UInt16 = 0x57
    let kVK_Shift: UInt16 = 0x38

    @Test func letter() throws {
        let key = try #require(KeyEventData.make(macKeyCode: kVK_ANSI_A, modifiers: [], isKeyDown: true))
        #expect(key.keyCode == 0x41)
        #expect(key.charCode == Int(Character("a").asciiValue!))
        #expect(key.keyStates[0x41] == 0x80)
        #expect(!key.isExtended)
    }

    @Test func shiftAndCapsLockLikeToAscii() throws {
        let shifted = try #require(KeyEventData.make(macKeyCode: kVK_ANSI_A, modifiers: .leftShift, isKeyDown: true))
        #expect(shifted.charCode == Int(Character("A").asciiValue!))
        let caps = try #require(KeyEventData.make(macKeyCode: kVK_ANSI_A, modifiers: .capsLock, isKeyDown: true))
        #expect(caps.charCode == Int(Character("A").asciiValue!))
        // Windows inverts Shift when Caps Lock is on.
        let both = try #require(KeyEventData.make(macKeyCode: kVK_ANSI_A, modifiers: [.capsLock, .leftShift], isKeyDown: true))
        #expect(both.charCode == Int(Character("a").asciiValue!))
        // Caps Lock does not affect non-letters.
        let digit = try #require(KeyEventData.make(macKeyCode: kVK_ANSI_1, modifiers: .capsLock, isKeyDown: true))
        #expect(digit.charCode == Int(Character("1").asciiValue!))
    }

    @Test func controlDoesNotChangeCharCode() throws {
        let key = try #require(KeyEventData.make(macKeyCode: kVK_ANSI_1, modifiers: .leftControl, isKeyDown: true))
        #expect(key.charCode == Int(Character("1").asciiValue!))
        #expect(key.keyStates[VK.control] == 0x80)
        #expect(key.keyStates[VK.lcontrol] == 0x80)
    }

    @Test func punctuationUsesOemKeyCodes() throws {
        let key = try #require(KeyEventData.make(macKeyCode: kVK_ANSI_Semicolon, modifiers: .rightShift, isKeyDown: true))
        #expect(key.keyCode == VK.oem1)
        #expect(key.charCode == Int(Character(":").asciiValue!))
        #expect(key.keyStates[VK.shift] == 0x80)
        #expect(key.keyStates[VK.rshift] == 0x80)
        #expect(key.keyStates[VK.lshift] == 0)
    }

    @Test func nonPrintableKeys() throws {
        let space = try #require(KeyEventData.make(macKeyCode: kVK_Space, modifiers: [], isKeyDown: true))
        #expect(space.keyCode == VK.space && space.charCode == 0x20)
        let enter = try #require(KeyEventData.make(macKeyCode: kVK_Return, modifiers: [], isKeyDown: true))
        #expect(enter.keyCode == VK.returnKey && enter.charCode == 0x0D)
        let left = try #require(KeyEventData.make(macKeyCode: kVK_LeftArrow, modifiers: [], isKeyDown: true))
        #expect(left.keyCode == VK.left && left.charCode == 0 && left.isExtended)
    }

    @Test func keypadIsNumLockOn() throws {
        let key = try #require(KeyEventData.make(macKeyCode: kVK_Keypad5, modifiers: [], isKeyDown: true))
        #expect(key.keyCode == VK.numpad0 + 5)
        #expect(key.charCode == Int(Character("5").asciiValue!))
        #expect(key.keyStates[VK.numlock] & 1 == 1)
    }

    @Test func keyUpClearsTheKey() throws {
        let key = try #require(KeyEventData.make(macKeyCode: kVK_Shift, modifiers: [], isKeyDown: false))
        #expect(key.keyCode == VK.shift)
        #expect(key.keyStates[VK.shift] == 0)
    }

    @Test func unknownKey() {
        #expect(KeyEventData.make(macKeyCode: 0x3F /* fn */, modifiers: [], isKeyDown: true) == nil)
    }

    @Test func requestFields() throws {
        let key = try #require(KeyEventData.make(macKeyCode: kVK_ANSI_A, modifiers: [], isKeyDown: true))
        let fields = key.requestFields
        #expect(fields["keyCode"] as? Int == 0x41)
        #expect((fields["keyStates"] as? [Int])?.count == 256)
        #expect(fields["isExtended"] as? Bool == false)
    }
}
