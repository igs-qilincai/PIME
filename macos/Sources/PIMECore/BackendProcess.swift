// Runs a PIME backend server (python/server.py) as a child process and talks
// to it over stdin/stdout, the same protocol PIMELauncher uses on Windows:
//
//   request:  "<client_id>|<JSON>\n"
//   response: "PIME_MSG|<client_id>|<JSON>\n"
//
// Other lines on stdout (debug prints of the backend) are ignored.
//
// Written with assistance from Claude Code (Claude Opus 5.5).

import Foundation
import os

/// Sends requests of input method clients to a backend.
public protocol BackendTransport: AnyObject {
    /// Changes every time a new backend process is started. Clients have to
    /// initialize themselves again when it changes.
    var generation: Int { get }

    /// Starts the backend if it is not running.
    func ensureRunning()

    /// Sends a request and waits for its reply. Returns nil on failure.
    func request(clientId: String, message: [String: Any], timeout: TimeInterval) -> [String: Any]?

    /// Sends a request which has no reply (e.g. "close").
    func post(clientId: String, message: [String: Any])
}

public final class BackendProcess: BackendTransport, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var executableURL: URL
        public var arguments: [String]
        public var workingDirectory: URL
        public var environment: [String: String]
        /// The backend's stderr is appended to this file if set.
        public var stderrLogURL: URL?

        public init(executableURL: URL, arguments: [String], workingDirectory: URL,
                    environment: [String: String], stderrLogURL: URL? = nil) {
            self.executableURL = executableURL
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.environment = environment
            self.stderrLogURL = stderrLogURL
        }
    }

    /// Do not restart a crashing backend more often than this.
    public var minimumRestartInterval: TimeInterval = 3

    public private(set) var generation = 0

    private let config: Configuration
    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var channel: LineChannel?
    private var lastStartTime: Date?
    private let log = Logger(subsystem: "org.easyime.inputmethod.PIME", category: "backend")

    public init(configuration: Configuration) {
        config = configuration
    }

    deinit {
        stopLocked()
    }

    public func ensureRunning() {
        lock.withLock { _ = ensureRunningLocked() }
    }

    public func request(clientId: String, message: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        lock.withLock {
            guard ensureRunningLocked(), let channel else { return nil }
            guard send(clientId: clientId, message: message) else { return nil }

            let seqNum = message["seqNum"] as? Int
            let deadline = DispatchTime.now() + timeout
            while let line = channel.pop(until: deadline) {
                let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, parts[1] == clientId,
                      let reply = try? JSONSerialization.jsonObject(with: Data(parts[2].utf8)) as? [String: Any]
                else { continue }
                // Skip a late reply of an earlier request. Error replies
                // ({"success":false}) do not carry a seqNum.
                if let seqNum, let replySeqNum = reply["seqNum"] as? Int, replySeqNum != seqNum {
                    continue
                }
                return reply
            }
            // A backend which does not answer in time is likely hung. Kill it
            // so that it is restarted on the next request instead of blocking
            // every following key stroke.
            log.error("no reply to \(message["method"] as? String ?? "?", privacy: .public); stopping backend")
            stopLocked()
            return nil
        }
    }

    public func post(clientId: String, message: [String: Any]) {
        lock.withLock {
            guard let process, process.isRunning else { return }
            _ = send(clientId: clientId, message: message)
        }
    }

    // MARK: - Private

    private func send(clientId: String, message: [String: Any]) -> Bool {
        guard let stdinHandle,
              let json = try? JSONSerialization.data(withJSONObject: message) else { return false }
        var line = Data("\(clientId)|".utf8)
        line.append(json)
        line.append(0x0A)
        do {
            try stdinHandle.write(contentsOf: line)
            return true
        } catch {
            log.error("failed to write to backend: \(error.localizedDescription, privacy: .public)")
            stopLocked()
            return false
        }
    }

    private func ensureRunningLocked() -> Bool {
        if let process, process.isRunning, let channel, !channel.isClosed {
            return true
        }
        stopLocked()
        if let lastStartTime, Date().timeIntervalSince(lastStartTime) < minimumRestartInterval {
            return false
        }
        lastStartTime = Date()

        let process = Process()
        process.executableURL = config.executableURL
        process.arguments = config.arguments
        process.currentDirectoryURL = config.workingDirectory
        process.environment = config.environment
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = openStderrLog() ?? FileHandle.nullDevice

        // Writing to a dead backend must fail with EPIPE instead of killing
        // the whole input method with SIGPIPE.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        do {
            try process.run()
        } catch {
            log.error("failed to start backend: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let channel = LineChannel()
        channel.startReading(stdoutPipe.fileHandleForReading)
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.channel = channel
        generation += 1
        log.info("started backend pid \(process.processIdentifier)")
        return true
    }

    private func stopLocked() {
        if let process, process.isRunning {
            process.terminate()
        }
        try? stdinHandle?.close()
        process = nil
        stdinHandle = nil
        channel = nil
    }

    private func openStderrLog() -> FileHandle? {
        guard let url = config.stderrLogURL else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Start over once the log gets large.
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1 << 20 {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }
}

/// Collects the "PIME_MSG|" lines written to stdout by one backend process.
private final class LineChannel: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var lines: [String] = []
    private var closed = false

    var isClosed: Bool { lock.withLock { closed } }

    func startReading(_ handle: FileHandle) {
        let fd = handle.fileDescriptor
        let thread = Thread { [self] in
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                pending.append(contentsOf: buffer[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let lineData = pending[pending.startIndex..<newline]
                    pending.removeSubrange(pending.startIndex...newline)
                    if let line = String(data: lineData, encoding: .utf8), line.hasPrefix("PIME_MSG|") {
                        push(line)
                    }
                }
            }
            try? handle.close()
            close()
        }
        thread.name = "PIME backend reader"
        thread.start()
    }

    /// Returns the next line, or nil when timed out or the backend exited.
    func pop(until deadline: DispatchTime) -> String? {
        while true {
            lock.lock()
            if !lines.isEmpty {
                let line = lines.removeFirst()
                lock.unlock()
                return line
            }
            let isClosed = closed
            lock.unlock()
            if isClosed || signal.wait(timeout: deadline) == .timedOut {
                return nil
            }
        }
    }

    private func push(_ line: String) {
        lock.withLock { lines.append(line) }
        signal.signal()
    }

    private func close() {
        lock.withLock { closed = true }
        signal.signal()
    }
}
