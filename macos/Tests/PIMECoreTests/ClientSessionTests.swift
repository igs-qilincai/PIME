// Written with assistance from Claude Code (Claude Opus 5.5).

import Foundation
import Testing
@testable import PIMECore

/// Records requests and answers them with canned replies.
private final class FakeTransport: BackendTransport {
    var generation = 1
    var requests: [[String: Any]] = []
    var posts: [[String: Any]] = []
    /// Replies by method name; missing methods reply {"success": true}.
    var replies: [String: [String: Any]] = [:]
    var failing: Set<String> = []

    var methods: [String] { requests.compactMap { $0["method"] as? String } }

    func ensureRunning() {}

    func request(clientId: String, message: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        requests.append(message)
        let method = message["method"] as? String ?? ""
        if failing.contains(method) { return nil }
        var reply = replies[method] ?? [:]
        reply["success"] = reply["success"] ?? true
        reply["seqNum"] = message["seqNum"]
        return reply
    }

    func post(clientId: String, message: [String: Any]) {
        posts.append(message)
    }
}

private let guid = "{F80736AA-28DB-423A-92C9-5540F501C939}"

@Suite struct ClientSessionTests {
    private func key(_ macKeyCode: UInt16, _ modifiers: ModifierKeys = []) -> KeyEventData {
        KeyEventData.make(macKeyCode: macKeyCode, modifiers: modifiers, isKeyDown: true)!
    }

    @Test func activationInitializesOnce() {
        let transport = FakeTransport()
        let session = ClientSession(guid: guid, transport: transport)
        _ = session.activate()
        _ = session.activate()
        #expect(transport.methods == ["init", "onActivate"])
        #expect(transport.requests[0]["id"] as? String == guid)
        #expect(transport.requests[0]["isWindows8Above"] as? Bool == true)
        #expect(transport.requests[1]["isKeyboardOpen"] as? Bool == true)
        let seqNums = transport.requests.compactMap { $0["seqNum"] as? Int }
        #expect(seqNums == [1, 2])
    }

    @Test func keyNotFilteredIsPassedToTheApp() {
        let transport = FakeTransport()
        transport.replies["filterKeyDown"] = ["return": false]
        let session = ClientSession(guid: guid, transport: transport)
        _ = session.activate()
        let result = session.keyDown(key(0x00), tfModifiers: 0)
        #expect(!result.handled)
        #expect(transport.methods == ["init", "onActivate", "filterKeyDown"])
    }

    @Test func filteredKeyUpdatesComposition() {
        let transport = FakeTransport()
        transport.replies["filterKeyDown"] = ["return": true]
        transport.replies["onKeyDown"] = [
            "return": true, "compositionString": "ㄒ", "compositionCursor": 1,
        ]
        let session = ClientSession(guid: guid, transport: transport)
        _ = session.activate()
        let result = session.keyDown(key(0x09), tfModifiers: 0)
        #expect(result.handled)
        #expect(result.replies.count == 2)
        #expect(session.state.compositionString == "ㄒ")
        #expect(session.state.isComposing)
    }

    @Test func preservedKeyIsHandledFirst() {
        let transport = FakeTransport()
        transport.replies["onActivate"] = [
            "addPreservedKey": [["keyCode": 0x20, "modifiers": TFModifier.shift, "guid": "{ABC}"]],
        ]
        transport.replies["onPreservedKey"] = ["return": true]
        let session = ClientSession(guid: guid, transport: transport)
        _ = session.activate()
        #expect(session.preservedKeys == [PreservedKey(keyCode: 0x20, modifiers: TFModifier.shift, guid: "{abc}")])

        // Space without Shift is a normal key.
        _ = session.keyDown(key(0x31), tfModifiers: 0)
        #expect(transport.methods.last == "filterKeyDown")

        let result = session.keyDown(key(0x31, .leftShift), tfModifiers: TFModifier.shift)
        #expect(result.handled)
        #expect(transport.methods.last == "onPreservedKey")
        #expect(transport.requests.last?["guid"] as? String == "{abc}")
    }

    @Test func keyUpCallsOnKeyUpOnlyWhenFiltered() {
        let transport = FakeTransport()
        let session = ClientSession(guid: guid, transport: transport)
        _ = session.activate()
        _ = session.keyUp(key(0x38))
        #expect(transport.methods.suffix(1) == ["filterKeyUp"])
        transport.replies["filterKeyUp"] = ["return": true]
        _ = session.keyUp(key(0x38))
        #expect(transport.methods.suffix(2) == ["filterKeyUp", "onKeyUp"])
    }

    @Test func bypassedKeyIsOnlyFiltered() {
        let transport = FakeTransport()
        transport.replies["filterKeyDown"] = ["return": true]
        transport.replies["filterKeyUp"] = ["return": true]
        let session = ClientSession(guid: guid, transport: transport)
        _ = session.activate()
        // Command+Shift+P
        let modifiers: ModifierKeys = [.leftCommand, .leftShift]
        let up = KeyEventData.make(macKeyCode: 0x23, modifiers: modifiers, isKeyDown: false)!
        let replies = session.bypassKey(down: key(0x23, modifiers), up: up)
        #expect(transport.methods == ["init", "onActivate", "filterKeyDown", "filterKeyUp"])
        #expect(transport.requests[2]["keyCode"] as? Int == 0x50)
        #expect(replies.count == 2)
    }

    @Test func reinitializesAfterBackendRestart() {
        let transport = FakeTransport()
        transport.replies["onKeyDown"] = ["compositionString": "ㄒ"]
        transport.replies["filterKeyDown"] = ["return": true]
        let session = ClientSession(guid: guid, transport: transport)
        _ = session.activate()
        _ = session.keyDown(key(0x09), tfModifiers: 0)
        #expect(session.state.compositionString == "ㄒ")

        transport.generation += 1
        transport.requests = []
        transport.replies["filterKeyDown"] = ["return": false]
        let result = session.keyDown(key(0x09), tfModifiers: 0)
        #expect(transport.methods == ["init", "onActivate", "filterKeyDown"])
        #expect(result.replies.count == 3)
        #expect(session.state.compositionString == "")
    }

    @Test func failedInitIsRetried() {
        let transport = FakeTransport()
        transport.failing = ["init"]
        let session = ClientSession(guid: guid, transport: transport)
        #expect(session.activate().isEmpty)
        transport.failing = []
        _ = session.activate()
        #expect(transport.methods == ["init", "init", "onActivate"])
    }

    @Test func tracksButtons() {
        let transport = FakeTransport()
        transport.replies["onActivate"] = [
            "addButton": [
                ["id": "switch-lang", "icon": "/x/traC.ico", "commandId": 1, "tooltip": "中英文切換"],
                ["id": "settings", "type": "menu"],
            ],
        ]
        transport.replies["onCommand"] = [
            "changeButton": [["id": "switch-lang", "icon": "/x/eng.ico"]],
            "removeButton": ["settings"],
        ]
        let session = ClientSession(guid: guid, transport: transport)
        _ = session.activate()
        #expect(session.buttons.map(\.id) == ["switch-lang", "settings"])
        _ = session.command(id: 1, type: CommandType.leftClick)
        #expect(session.buttons.count == 1)
        #expect(session.buttons[0].icon == "/x/eng.ico")
        #expect(session.buttons[0].tooltip == "中英文切換")
    }

    @Test func menu() {
        let transport = FakeTransport()
        transport.replies["onMenu"] = [
            "return": [
                ["text": "設定 (&C)", "id": 3],
                [:],
                ["text": "網路辭典 (&D)", "submenu": [["text": "萌典", "id": 13]]],
                ["text": "輸出簡體中文 (&S)", "id": 18, "checked": true, "enabled": false],
            ],
        ]
        let session = ClientSession(guid: guid, transport: transport)
        let items = session.menu(forButton: "settings")
        #expect(transport.requests.last?["id"] as? String == "settings")
        #expect(items.count == 4)
        #expect(items[0].displayText == "設定" && items[0].id == 3)
        #expect(items[1].isSeparator)
        #expect(items[2].submenu?.first?.text == "萌典")
        #expect(items[3].checked && !items[3].enabled)
    }

    @Test func terminateCompositionClearsState() {
        let transport = FakeTransport()
        transport.replies["filterKeyDown"] = ["return": true]
        transport.replies["onKeyDown"] = ["compositionString": "想", "showCandidates": true]
        let session = ClientSession(guid: guid, transport: transport)
        _ = session.keyDown(key(0x09), tfModifiers: 0)
        #expect(session.state.isComposing)
        _ = session.terminateComposition()
        #expect(transport.requests.last?["forced"] as? Bool == true)
        #expect(!session.state.isComposing)
    }

    @Test func closePostsWithoutWaiting() {
        let transport = FakeTransport()
        let session = ClientSession(guid: guid, transport: transport)
        session.close()
        #expect(transport.posts.first?["method"] as? String == "close")
    }

    @Test func compositionCursorInUTF16() {
        var state = CompositionState()
        state.compositionString = "𠀋ㄒ"  // U+2000B needs a surrogate pair
        state.compositionCursor = 1
        #expect(state.compositionCursorUTF16 == 2)
        state.compositionCursor = 5
        #expect(state.compositionCursorUTF16 == 3)
    }
}
