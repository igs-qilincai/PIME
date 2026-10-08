// The state of one input method client and the request flow of the PIME
// protocol, following PIMETextService/PIMEClient.cpp on Windows.
//
// Written with assistance from Claude Code (Claude Opus 5.5).

import Foundation

/// The composition and candidate window state reported by the backend.
public struct CompositionState: Equatable, Sendable {
    public var compositionString = ""
    /// Cursor position in Unicode scalars (Python string indexes).
    public var compositionCursor = 0
    public var candidates: [String] = []
    public var candidateCursor = 0
    public var showCandidates = false
    public var selKeys = "1234567890"
    public var candPerRow = 1
    public var candUseCursor = true
    public var candFontSize = 16

    public init() {}

    public var isComposing: Bool { !compositionString.isEmpty || showCandidates }

    /// The composition cursor as a UTF-16 offset, as used by AppKit.
    public var compositionCursorUTF16: Int {
        let scalars = compositionString.unicodeScalars
        let count = min(max(compositionCursor, 0), scalars.count)
        return scalars.prefix(count).reduce(0) { $0 + $1.utf16.count }
    }
}

/// Command types of TextService.onCommand() (textService.py).
public enum CommandType {
    public static let leftClick = 0
    public static let rightClick = 1
    public static let menu = 2
}

public final class ClientSession {
    public let clientId: String
    /// The GUID of the input method in its ime.json.
    public let guid: String
    public private(set) var state = CompositionState()
    /// Language bar buttons in the order they were added.
    public private(set) var buttons: [ButtonInfo] = []
    public private(set) var preservedKeys: [PreservedKey] = []

    private let transport: BackendTransport
    private var nextSeqNum = 0
    private var initializedGeneration: Int?
    private var isActivated = false

    public var requestTimeout: TimeInterval = 2
    /// The first request starts Python and loads the input method.
    public var initTimeout: TimeInterval = 10

    public init(guid: String, transport: BackendTransport, clientId: String = UUID().uuidString) {
        self.guid = guid
        self.transport = transport
        self.clientId = clientId
    }

    /// Activates the input method for this client once.
    /// Returns the replies the UI has to apply, in order.
    public func activate() -> [BackendReply] {
        var replies: [BackendReply] = []
        if !isActivated {
            isActivated = true
            if call("onActivate", ["isKeyboardOpen": true], into: &replies) == nil {
                isActivated = false
            }
        }
        return replies
    }

    public func deactivate() -> [BackendReply] {
        var replies: [BackendReply] = []
        if isActivated {
            _ = call("onDeactivate", [:], into: &replies)
            isActivated = false
        }
        return replies
    }

    /// Handles a key down event. `handled` is false if the key should be
    /// passed to the application.
    public func keyDown(_ key: KeyEventData, tfModifiers: Int) -> (handled: Bool, replies: [BackendReply]) {
        var replies: [BackendReply] = []
        if let preserved = preservedKeys.first(where: {
            $0.keyCode == key.keyCode && $0.modifiers == tfModifiers
        }) {
            if let reply = call("onPreservedKey", ["guid": preserved.guid], into: &replies),
               reply.returnBool {
                return (true, replies)
            }
        }
        guard let filter = call("filterKeyDown", key.requestFields, into: &replies),
              filter.returnBool else {
            return (false, replies)
        }
        let reply = call("onKeyDown", key.requestFields, into: &replies)
        return (reply?.returnBool ?? false, replies)
    }

    public func keyUp(_ key: KeyEventData) -> [BackendReply] {
        var replies: [BackendReply] = []
        if let filter = call("filterKeyUp", key.requestFields, into: &replies), filter.returnBool {
            _ = call("onKeyUp", key.requestFields, into: &replies)
        }
        return replies
    }

    /// Tells the backend the composition was ended by the system, e.g. the
    /// app committed it because the user clicked elsewhere.
    public func terminateComposition() -> [BackendReply] {
        var replies: [BackendReply] = []
        _ = call("onCompositionTerminated", ["forced": true], into: &replies)
        state.compositionString = ""
        state.compositionCursor = 0
        state.showCandidates = false
        state.candidates = []
        return replies
    }

    /// Returns the menu of a language bar button.
    public func menu(forButton buttonId: String) -> [MenuItemInfo] {
        var replies: [BackendReply] = []
        let reply = call("onMenu", ["id": buttonId], into: &replies)
        return MenuItemInfo.parseList(reply?.returnValue)
    }

    public func command(id: Int, type: Int) -> [BackendReply] {
        var replies: [BackendReply] = []
        _ = call("onCommand", ["id": id, "type": type], into: &replies)
        return replies
    }

    /// Releases the client in the backend.
    public func close() {
        transport.post(clientId: clientId, message: ["method": "close"])
    }

    // MARK: - Private

    /// Sends a request and applies its reply to the state. Initializes the
    /// client first if the backend was (re)started. Every reply, including
    /// those of the initialization, is appended to `replies`.
    private func call(_ method: String, _ fields: [String: Any],
                      into replies: inout [BackendReply]) -> BackendReply? {
        transport.ensureRunning()
        if initializedGeneration != transport.generation {
            guard initialize(into: &replies) else { return nil }
            // onActivate is part of the initialization if it was activated.
            if method == "onActivate" { return replies.last }
        }
        return send(method, fields, timeout: requestTimeout, into: &replies)
    }

    private func initialize(into replies: inout [BackendReply]) -> Bool {
        // A new backend process knows nothing about this client.
        state = CompositionState()
        buttons = []
        preservedKeys = []
        let generation = transport.generation
        let fields: [String: Any] = [
            "id": guid,
            // Take the code paths of modern Windows in the backends.
            "isWindows8Above": true,
            "isMetroApp": false,
            "isUiLess": false,
            "isConsole": false,
        ]
        guard let reply = send("init", fields, timeout: initTimeout, into: &replies), reply.success else {
            return false
        }
        initializedGeneration = generation
        if isActivated {
            return send("onActivate", ["isKeyboardOpen": true], timeout: requestTimeout, into: &replies) != nil
        }
        return true
    }

    private func send(_ method: String, _ fields: [String: Any], timeout: TimeInterval,
                      into replies: inout [BackendReply]) -> BackendReply? {
        nextSeqNum += 1
        var message = fields
        message["method"] = method
        message["seqNum"] = nextSeqNum
        guard let raw = transport.request(clientId: clientId, message: message, timeout: timeout) else {
            return nil
        }
        let reply = BackendReply(raw)
        apply(reply)
        replies.append(reply)
        return reply
    }

    private func apply(_ reply: BackendReply) {
        if let keys = reply.selKeys { state.selKeys = keys }
        if let list = reply.candidateList { state.candidates = list }
        if let show = reply.showCandidates { state.showCandidates = show }
        if let cursor = reply.candidateCursor { state.candidateCursor = cursor }
        if let s = reply.compositionString { state.compositionString = s }
        if let cursor = reply.compositionCursor { state.compositionCursor = cursor }

        for button in reply.addedButtons {
            if let index = buttons.firstIndex(where: { $0.id == button.id }) {
                buttons[index] = button
            } else {
                buttons.append(button)
            }
        }
        let removed = Set(reply.removedButtons)
        buttons.removeAll { removed.contains($0.id) }
        for change in reply.changedButtons {
            if let id = change["id"] as? String, let index = buttons.firstIndex(where: { $0.id == id }) {
                buttons[index].update(from: change)
            }
        }

        let removedKeys = Set(reply.removedPreservedKeys)
        preservedKeys.removeAll { removedKeys.contains($0.guid) }
        for key in reply.addedPreservedKeys {
            preservedKeys.removeAll { $0.guid == key.guid }
            preservedKeys.append(key)
        }

        let ui = reply.customizeUI
        if let v = ui["candPerRow"] as? Int, v > 0 { state.candPerRow = v }
        if let v = ui["candUseCursor"] as? Bool { state.candUseCursor = v }
        if let v = ui["candFontSize"] as? Int, v > 0 { state.candFontSize = v }
    }
}
