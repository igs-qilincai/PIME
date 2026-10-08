// swift-tools-version:6.0
//
// macOS front end of PIME (InputMethodKit client).
// Written with assistance from Claude Code (Claude Opus 5.5).

import PackageDescription

let package = Package(
    name: "PIME",
    platforms: [.macOS("26.0")],
    targets: [
        // Platform-neutral logic: key mapping, the backend protocol and the
        // per-client session state. Kept free of AppKit so it can be tested.
        .target(name: "PIMECore"),
        .testTarget(name: "PIMECoreTests", dependencies: ["PIMECore"]),
    ],
    swiftLanguageModes: [.v5]
)
