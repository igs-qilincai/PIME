// Registers the input method with the Text Input Sources manager.
//
// Written with assistance from Claude Code (Claude Opus 5.5).

import Carbon
import Foundation

enum InputSourceInstaller {
    /// Registers this app (which must be in ~/Library/Input Methods) and
    /// enables its input sources so they show up in the input menu.
    static func install() -> Bool {
        let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
        guard status == noErr else {
            FileHandle.standardError.write(Data("TISRegisterInputSource failed: \(status)\n".utf8))
            return false
        }
        guard let bundleId = Bundle.main.bundleIdentifier else { return false }
        let properties = [kTISPropertyBundleID as String: bundleId] as CFDictionary
        guard let sources = TISCreateInputSourceList(properties, true)?.takeRetainedValue()
                as? [TISInputSource], !sources.isEmpty else {
            FileHandle.standardError.write(Data("No input source found for \(bundleId)\n".utf8))
            return false
        }
        for source in sources {
            TISEnableInputSource(source)
        }
        return true
    }

    /// Makes the input menu in the menu bar redraw itself.
    ///
    /// When the process of the selected input method is killed, e.g. to
    /// install a new version, the input menu can lose its icon and the
    /// input method (a macOS bug) while typing keeps working. Showing the
    /// Keyboard Viewer fixes it, while restarting TextInputSwitcher or
    /// disabling and enabling an input source does not. Shows the Keyboard
    /// Viewer for a moment, then restores whether it was enabled and shown.
    static func refreshInputMenu() -> Bool {
        let properties = [kTISPropertyInputSourceID as String: "com.apple.inputmethod.AssistiveControl"]
            as CFDictionary
        guard let viewer = (TISCreateInputSourceList(properties, true)?.takeRetainedValue()
                as? [TISInputSource])?.first else {
            FileHandle.standardError.write(Data("Keyboard Viewer input source not found\n".utf8))
            return false
        }
        let wasEnabled = boolProperty(viewer, kTISPropertyInputSourceIsEnabled)
        let wasSelected = boolProperty(viewer, kTISPropertyInputSourceIsSelected)
        // It can only be selected while enabled.
        if !wasEnabled {
            TISEnableInputSource(viewer)
        }
        if wasSelected {
            TISDeselectInputSource(viewer)
        }
        let status = TISSelectInputSource(viewer)
        // Give the input menu time to see it before hiding it again.
        Thread.sleep(forTimeInterval: 0.5)
        if !wasSelected {
            TISDeselectInputSource(viewer)
        }
        if !wasEnabled {
            TISDisableInputSource(viewer)
        }
        guard status == noErr else {
            FileHandle.standardError.write(Data("Showing the Keyboard Viewer failed: \(status)\n".utf8))
            return false
        }
        return true
    }

    private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let value = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
    }
}
