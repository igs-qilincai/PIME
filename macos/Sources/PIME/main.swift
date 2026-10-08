// Entry point of the PIME input method app.
//
// Written with assistance from Claude Code (Claude Opus 5.5).

import AppKit
import InputMethodKit

// "PIME --install" registers and enables the input method, then exits.
if CommandLine.arguments.contains("--install") {
    exit(InputSourceInstaller.install() ? 0 : 1)
}

guard let connectionName = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
      let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
else {
    NSLog("PIME: failed to create the IMKServer")
    exit(1)
}

withExtendedLifetime(server) {
    NSApplication.shared.run()
}
