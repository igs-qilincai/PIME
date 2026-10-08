// The InputMethodKit controller: one instance per text input client.
// It plays the role of PIMETextService on Windows, forwarding key events to
// the backend through a ClientSession and applying the replies.
//
// Written with assistance from Claude Code (Claude Opus 5.5).

import AppKit
import InputMethodKit
import PIMECore

private let notFound = NSRange(location: NSNotFound, length: NSNotFound)

/// Text shown when the chewing backend changes the icon of a language bar
/// button, which is how it reports mode changes on Windows.
private let modeIconLabels = [
    "traC.ico": "中", "simC.ico": "简", "eng.ico": "英", "capsEng.ico": "A",
    "full.ico": "全形", "half.ico": "半形",
]
private let modeButtonIds: Set<String> = ["windows-mode-icon", "switch-shape"]

@objc(PIMEInputController)
final class InputController: IMKInputController {
    private var session: ClientSession!
    /// The marked text currently shown in the client, if any.
    private var shownComposition: (text: String, cursor: Int)?
    private var modeLabels: [String: String] = [:]

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        session = ClientSession(guid: Backend.textServiceGUID, transport: Backend.shared)
    }

    deinit {
        session?.close()
    }

    // MARK: - IMKStateSetting

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        // The backend keeps the state of each client, so this only does
        // something the first time. Focus changes do not reset the mode.
        apply(session.activate(), client: sender)
    }

    override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
        CandidatePanel.shared.hide()
        MessagePanel.shared.hide()
        super.deactivateServer(sender)
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }

    // MARK: - Key events

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        let modifiers = ModifierKeys(eventFlags: event.modifierFlags.rawValue)
        switch event.type {
        case .keyDown:
            // Command shortcuts belong to the application.
            guard modifiers.isDisjoint(with: .command),
                  let down = KeyEventData.make(macKeyCode: event.keyCode, modifiers: modifiers,
                                               isKeyDown: true, isRepeat: event.isARepeat)
            else { return false }
            let result = session.keyDown(down, tfModifiers: modifiers.tfModifiers)
            apply(result.replies, client: sender)
            // Only key down events are requested from InputMethodKit, but the
            // backends expect a key up for every key down, e.g. to tell a
            // lone Shift press from Shift + letter. Send it right away.
            if let up = KeyEventData.make(macKeyCode: event.keyCode, modifiers: modifiers, isKeyDown: false) {
                apply(session.keyUp(up), client: sender)
            }
            return result.handled
        case .flagsChanged:
            handleModifierKey(event, modifiers: modifiers, client: sender)
            // Never swallow modifier changes.
            return false
        default:
            return false
        }
    }

    /// Turns a flagsChanged event into a key down or up of the modifier key.
    private func handleModifierKey(_ event: NSEvent, modifiers: ModifierKeys, client sender: Any!) {
        guard let changed = macModifierKeys[event.keyCode] else { return }
        // Caps Lock toggles on every press and has no release event.
        let isDown = changed == .capsLock || modifiers.contains(changed)
        if isDown, let down = KeyEventData.make(macKeyCode: event.keyCode, modifiers: modifiers, isKeyDown: true) {
            apply(session.keyDown(down, tfModifiers: modifiers.tfModifiers).replies, client: sender)
        }
        if !isDown || changed == .capsLock,
           let up = KeyEventData.make(macKeyCode: event.keyCode, modifiers: modifiers, isKeyDown: false) {
            apply(session.keyUp(up), client: sender)
        }
    }

    // MARK: - Composition

    /// Called by InputMethodKit when the client wants the composition ended,
    /// e.g. the user clicked elsewhere in the document.
    override func commitComposition(_ sender: Any!) {
        guard session.state.isComposing else { return }
        if let client = textInput(sender), let shown = shownComposition {
            // Keep what the user sees, like TSF does on Windows.
            client.insertText(shown.text, replacementRange: notFound)
        }
        shownComposition = nil
        apply(session.terminateComposition(), client: sender)
    }

    private func textInput(_ sender: Any?) -> IMKTextInput? {
        (sender as? IMKTextInput) ?? client()
    }

    /// Applies backend replies in order, then syncs the marked text and the
    /// candidate window with the session state.
    private func apply(_ replies: [BackendReply], client sender: Any?) {
        guard !replies.isEmpty, let client = textInput(sender) else { return }
        var message: (text: String, duration: Double)?
        for reply in replies {
            if let commit = reply.commitString, !commit.isEmpty {
                client.insertText(commit, replacementRange: notFound)
                // The marked text was replaced by the inserted text.
                shownComposition = nil
            }
            if reply.hideMessage {
                MessagePanel.shared.hide()
            }
            if let m = reply.message {
                message = m
            }
            if let label = modeChangeLabel(reply) {
                message = (label, 1)
            }
        }
        updateComposition(client)
        updateCandidates(client)
        if let message {
            MessagePanel.shared.show(message.text, duration: message.duration, caret: caretRect(client))
        }
    }

    private func updateComposition(_ client: IMKTextInput) {
        let state = session.state
        let text = state.compositionString
        let cursor = state.compositionCursorUTF16
        if let shown = shownComposition, shown.text == text, shown.cursor == cursor { return }
        if shownComposition == nil && text.isEmpty { return }

        let marked = NSAttributedString(string: text, attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .markedClauseSegment: 0,
        ])
        client.setMarkedText(marked, selectionRange: NSRange(location: cursor, length: 0),
                             replacementRange: notFound)
        shownComposition = text.isEmpty ? nil : (text, cursor)
    }

    private func updateCandidates(_ client: IMKTextInput) {
        let state = session.state
        if state.showCandidates && !state.candidates.isEmpty {
            CandidatePanel.shared.show(state, caret: caretRect(client))
        } else {
            CandidatePanel.shared.hide()
        }
    }

    private func caretRect(_ client: IMKTextInput) -> NSRect {
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return rect
    }

    /// Returns the text to show if the reply changes the mode icon.
    private func modeChangeLabel(_ reply: BackendReply) -> String? {
        var changed: String?
        for button in reply.addedButtons where modeButtonIds.contains(button.id) {
            // Remember the initial state without announcing it.
            modeLabels[button.id] = button.icon.flatMap { modeIconLabels[($0 as NSString).lastPathComponent] }
        }
        for change in reply.changedButtons {
            guard let id = change["id"] as? String, modeButtonIds.contains(id),
                  let icon = change["icon"] as? String,
                  let label = modeIconLabels[(icon as NSString).lastPathComponent],
                  modeLabels[id] != label else { continue }
            modeLabels[id] = label
            changed = label
        }
        return changed
    }

    // MARK: - Menu

    /// The input menu: the language bar buttons of the backend followed by
    /// the menu of its settings button.
    override func menu() -> NSMenu! {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var titles = Set<String>()
        for button in session.buttons where button.type != "menu" {
            guard let commandId = button.commandId,
                  let title = button.tooltip ?? button.text,
                  titles.insert(title).inserted else { continue }
            let item = NSMenuItem(title: title, action: #selector(menuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = commandId
            item.representedObject = NSNumber(value: CommandType.leftClick)
            menu.addItem(item)
        }
        if let button = session.buttons.first(where: { $0.type == "menu" }) {
            let items = session.menu(forButton: button.id)
            if !items.isEmpty && menu.numberOfItems > 0 {
                menu.addItem(.separator())
            }
            addMenuItems(items, to: menu)
        }
        return menu
    }

    private func addMenuItems(_ items: [MenuItemInfo], to menu: NSMenu) {
        for info in items {
            if info.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: info.displayText, action: nil, keyEquivalent: "")
            item.isEnabled = info.enabled
            item.state = info.checked ? .on : .off
            if let submenuItems = info.submenu {
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                addMenuItems(submenuItems, to: submenu)
                item.submenu = submenu
            } else {
                item.action = #selector(menuItemSelected(_:))
                item.target = self
                item.tag = info.id
                item.representedObject = NSNumber(value: CommandType.menu)
            }
            menu.addItem(item)
        }
    }

    /// InputMethodKit passes a dictionary holding the menu item as sender.
    @objc private func menuItemSelected(_ sender: Any?) {
        let item = (sender as? NSMenuItem)
            ?? ((sender as? [String: Any])?[kIMKCommandMenuItemName] as? NSMenuItem)
        guard let item else { return }
        let type = (item.representedObject as? NSNumber)?.intValue ?? CommandType.menu
        apply(session.command(id: item.tag, type: type), client: client())
    }
}
