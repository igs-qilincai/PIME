// Typed access to the JSON replies of PIME backends.
// The reply format is produced by TextService in python/textService.py.
//
// Written with assistance from Claude Code (Claude Opus 5.5).

import Foundation

/// A language bar button (see TextService.addButton()).
public struct ButtonInfo: Equatable, Sendable {
    public var id: String
    public var icon: String?
    public var text: String?
    public var tooltip: String?
    public var commandId: Int?
    public var type: String?  // "button" (default), "menu" or "toggle"
    public var enable: Bool?
    public var toggled: Bool?

    public init(id: String) { self.id = id }

    init?(json: Any) {
        guard let dict = json as? [String: Any], let id = dict["id"] as? String else { return nil }
        self.id = id
        update(from: dict)
    }

    /// Applies the fields present in an addButton/changeButton entry.
    mutating func update(from dict: [String: Any]) {
        if let v = dict["icon"] as? String { icon = v }
        if let v = dict["text"] as? String { text = v }
        if let v = dict["tooltip"] as? String { tooltip = v }
        if let v = dict["commandId"] as? Int { commandId = v }
        if let v = dict["type"] as? String { type = v }
        if let v = dict["enable"] as? Bool { enable = v }
        if let v = dict["toggled"] as? Bool { toggled = v }
    }
}

/// A key which is handled by onPreservedKey() instead of filterKeyDown().
public struct PreservedKey: Equatable, Sendable {
    public var keyCode: Int
    public var modifiers: Int  // TF_MOD_* flags
    public var guid: String
}

/// An item of the menu returned by onMenu().
public struct MenuItemInfo: Equatable, Sendable {
    public var id: Int
    public var text: String
    public var checked: Bool
    public var enabled: Bool
    public var submenu: [MenuItemInfo]?

    public var isSeparator: Bool { id == 0 && text.isEmpty && submenu == nil }

    /// The menu text without Windows accelerator markers, e.g.
    /// "設定新酷音輸入法 (&C)" becomes "設定新酷音輸入法".
    public var displayText: String {
        var s = text.replacingOccurrences(of: #"\s*\(&.\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&&", with: "\u{0}")
        s = s.replacingOccurrences(of: "&", with: "")
        return s.replacingOccurrences(of: "\u{0}", with: "&")
    }

    public static func parseList(_ json: Any?) -> [MenuItemInfo] {
        guard let items = json as? [Any] else { return [] }
        return items.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            return MenuItemInfo(
                id: dict["id"] as? Int ?? 0,
                text: dict["text"] as? String ?? "",
                checked: dict["checked"] as? Bool ?? false,
                enabled: dict["enabled"] as? Bool ?? true,
                submenu: dict["submenu"].map { parseList($0) })
        }
    }
}

/// A reply to one request sent to the backend.
public struct BackendReply: @unchecked Sendable {
    public let raw: [String: Any]

    public init(_ raw: [String: Any]) { self.raw = raw }

    public var success: Bool { raw["success"] as? Bool ?? false }
    /// The "return" value of the method as a boolean (false if absent).
    public var returnBool: Bool { raw["return"] as? Bool ?? false }
    public var returnValue: Any? { raw["return"] }

    public var commitString: String? { raw["commitString"] as? String }
    public var compositionString: String? { raw["compositionString"] as? String }
    public var compositionCursor: Int? { raw["compositionCursor"] as? Int }
    public var candidateList: [String]? { raw["candidateList"] as? [String] }
    public var candidateCursor: Int? { raw["candidateCursor"] as? Int }
    public var showCandidates: Bool? { raw["showCandidates"] as? Bool }
    public var selKeys: String? { raw["setSelKeys"] as? String }

    public var message: (text: String, duration: Double)? {
        guard let info = raw["showMessage"] as? [String: Any],
              let text = info["message"] as? String else { return nil }
        return (text, (info["duration"] as? NSNumber)?.doubleValue ?? 3)
    }

    public var hideMessage: Bool { raw["hideMessage"] as? Bool ?? false }

    public var addedButtons: [ButtonInfo] {
        (raw["addButton"] as? [Any] ?? []).compactMap { ButtonInfo(json: $0) }
    }

    public var removedButtons: [String] { raw["removeButton"] as? [String] ?? [] }

    /// The raw changeButton entries; only the fields present are changed.
    public var changedButtons: [[String: Any]] { raw["changeButton"] as? [[String: Any]] ?? [] }

    public var addedPreservedKeys: [PreservedKey] {
        (raw["addPreservedKey"] as? [[String: Any]] ?? []).compactMap { dict in
            guard let keyCode = dict["keyCode"] as? Int,
                  let modifiers = dict["modifiers"] as? Int,
                  let guid = dict["guid"] as? String else { return nil }
            return PreservedKey(keyCode: keyCode, modifiers: modifiers, guid: guid.lowercased())
        }
    }

    public var removedPreservedKeys: [String] {
        (raw["removePreservedKey"] as? [String] ?? []).map { $0.lowercased() }
    }

    public var openKeyboard: Bool? { raw["openKeyboard"] as? Bool }

    public var customizeUI: [String: Any] { raw["customizeUI"] as? [String: Any] ?? [:] }
}
