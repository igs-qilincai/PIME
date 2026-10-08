// Written with assistance from Claude Code (Claude Opus 5.5).

import Foundation
import Testing
@testable import PIMECore

/// A fake backend speaking the PIME stdin/stdout protocol.
private let fakeServer = #"""
import json, sys
print("debug noise", flush=True)
for line in sys.stdin:
    client_id, text = line.rstrip("\n").split("|", 1)
    msg = json.loads(text)
    method = msg.get("method")
    if method == "close":
        continue
    if method == "hang":
        continue
    if method == "exit":
        sys.exit(0)
    if method == "stale":
        print("PIME_MSG|%s|%s" % (client_id, json.dumps({"seqNum": -1})), flush=True)
    reply = {"seqNum": msg["seqNum"], "success": True, "echo": method, "text": "a|b"}
    print("PIME_MSG|other|{}", flush=True)
    print("PIME_MSG|%s|%s" % (client_id, json.dumps(reply, ensure_ascii=False)), flush=True)
"""#

private func makeBackend() -> BackendProcess {
    let config = BackendProcess.Configuration(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["python3", "-c", fakeServer],
        workingDirectory: FileManager.default.temporaryDirectory,
        environment: ProcessInfo.processInfo.environment)
    let backend = BackendProcess(configuration: config)
    backend.minimumRestartInterval = 0
    return backend
}

@Suite(.serialized) struct BackendProcessTests {
    @Test func requestAndReply() throws {
        let backend = makeBackend()
        let reply = try #require(backend.request(
            clientId: "c1", message: ["method": "init", "seqNum": 1], timeout: 10))
        #expect(reply["echo"] as? String == "init")
        #expect(reply["text"] as? String == "a|b")
        #expect(backend.generation == 1)
    }

    @Test func skipsRepliesOfEarlierRequests() throws {
        let backend = makeBackend()
        let reply = try #require(backend.request(
            clientId: "c1", message: ["method": "stale", "seqNum": 7], timeout: 10))
        #expect(reply["seqNum"] as? Int == 7)
    }

    @Test func restartsAfterExit() throws {
        let backend = makeBackend()
        _ = backend.request(clientId: "c1", message: ["method": "init", "seqNum": 1], timeout: 10)
        let start = Date()
        #expect(backend.request(clientId: "c1", message: ["method": "exit", "seqNum": 2], timeout: 10) == nil)
        // The exit is noticed without waiting for the timeout.
        #expect(Date().timeIntervalSince(start) < 5)
        let reply = backend.request(clientId: "c1", message: ["method": "init", "seqNum": 3], timeout: 10)
        #expect(reply?["echo"] as? String == "init")
        #expect(backend.generation == 2)
    }

    @Test func restartsAfterTimeout() throws {
        let backend = makeBackend()
        _ = backend.request(clientId: "c1", message: ["method": "init", "seqNum": 1], timeout: 10)
        #expect(backend.request(clientId: "c1", message: ["method": "hang", "seqNum": 2], timeout: 0.3) == nil)
        let reply = backend.request(clientId: "c1", message: ["method": "init", "seqNum": 3], timeout: 10)
        #expect(reply?["echo"] as? String == "init")
        #expect(backend.generation == 2)
    }

    @Test func missingExecutable() {
        let config = BackendProcess.Configuration(
            executableURL: URL(fileURLWithPath: "/nonexistent/python3"),
            arguments: [], workingDirectory: FileManager.default.temporaryDirectory,
            environment: [:])
        let backend = BackendProcess(configuration: config)
        #expect(backend.request(clientId: "c1", message: ["method": "init", "seqNum": 1], timeout: 1) == nil)
        #expect(backend.generation == 0)
    }
}
