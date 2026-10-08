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
}
