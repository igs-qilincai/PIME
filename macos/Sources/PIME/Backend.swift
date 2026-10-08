// The Python backend shared by all input method clients.
//
// Written with assistance from Claude Code (Claude Opus 5.5).

import Foundation
import PIMECore

enum Backend {
    /// The GUID of the chewing input method in its ime.json.
    static let textServiceGUID =
        Bundle.main.object(forInfoDictionaryKey: "PIMETextServiceGUID") as? String ?? ""

    /// Bundle layout (see scripts/build_app.sh):
    ///   Contents/Resources/python/bin/python3   bundled Python runtime
    ///   Contents/Resources/backend/              copy of PIME's python/ dir
    static let shared: BackendProcess = {
        let resources = Bundle.main.resourceURL!
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("PYTHON") }
        // The app bundle is signed and must not be modified at runtime.
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUTF8"] = "1"
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PIME/backend.log")
        return BackendProcess(configuration: .init(
            executableURL: resources.appendingPathComponent("python/bin/python3"),
            arguments: ["-u", "server.py"],
            workingDirectory: resources.appendingPathComponent("backend"),
            environment: environment,
            stderrLogURL: logURL))
    }()
}
