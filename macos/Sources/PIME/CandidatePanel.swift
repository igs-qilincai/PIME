// The candidate window and the transient message window.
//
// Written with assistance from Claude Code (Claude Opus 5.5).

import AppKit
import PIMECore

/// A borderless, non-activating floating panel shown next to the caret.
private func makePopupPanel(content: NSView) -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
    panel.level = .popUpMenu
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

    let background = NSVisualEffectView()
    background.material = .menu
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 8
    background.layer?.masksToBounds = true
    background.addSubview(content)
    panel.contentView = background
    return panel
}

/// Puts a panel of `size` below the caret, or above it if there is no room.
private func place(_ panel: NSPanel, size: NSSize, caret: NSRect) {
    var caret = caret
    if caret == .zero {
        // Some apps cannot report the caret position.
        caret = NSRect(origin: NSEvent.mouseLocation, size: .zero)
    }
    let screen = NSScreen.screens.first { $0.frame.contains(caret.origin) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
    var origin = NSPoint(x: caret.minX, y: caret.minY - size.height - 4)
    if origin.y < visible.minY {
        origin.y = caret.maxY + 4
    }
    origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
    origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
    panel.contentView?.frame = NSRect(origin: .zero, size: size)
    panel.setFrame(NSRect(origin: origin, size: size), display: true)
}

final class CandidatePanel {
    static let shared = CandidatePanel()

    private let view = CandidateView()
    private lazy var panel = makePopupPanel(content: view)

    func show(_ state: CompositionState, caret: NSRect) {
        view.update(state)
        place(panel, size: view.frame.size, caret: caret)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

/// Draws the candidates in rows of `candPerRow`, each one labeled with its
/// selection key, highlighting the candidate cursor.
private final class CandidateView: NSView {
    private struct Cell {
        var label: String
        var text: String
        var frame: NSRect
    }

    private static let padding: CGFloat = 6
    private static let cellInset = NSSize(width: 6, height: 3)
    private static let labelGap: CGFloat = 4

    private var cells: [Cell] = []
    private var highlighted: Int?
    private var font = NSFont.systemFont(ofSize: 16)
    private var labelFont = NSFont.systemFont(ofSize: 12)

    override var isFlipped: Bool { true }

    func update(_ state: CompositionState) {
        let size = CGFloat(state.candFontSize)
        font = NSFont.systemFont(ofSize: size)
        labelFont = NSFont.monospacedDigitSystemFont(ofSize: size * 0.75, weight: .regular)
        highlighted = state.candUseCursor ? state.candidateCursor : nil

        let keys = Array(state.selKeys)
        let perRow = max(1, state.candPerRow)
        var sizes: [NSSize] = []
        cells = state.candidates.enumerated().map { index, text in
            let label = index < keys.count ? String(keys[index]) : ""
            let labelWidth = (label as NSString).size(withAttributes: [.font: labelFont]).width
            let textSize = (text as NSString).size(withAttributes: [.font: font])
            sizes.append(NSSize(
                width: labelWidth + Self.labelGap + textSize.width + Self.cellInset.width * 2,
                height: max(textSize.height, font.ascender - font.descender) + Self.cellInset.height * 2))
            return Cell(label: label, text: text, frame: .zero)
        }

        // Align the cells in columns.
        var columnWidths = [CGFloat](repeating: 0, count: min(perRow, max(cells.count, 1)))
        var rowHeight: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            columnWidths[index % perRow] = max(columnWidths[index % perRow], size.width)
            rowHeight = max(rowHeight, size.height)
        }
        for index in cells.indices {
            let column = index % perRow
            let x = Self.padding + columnWidths[..<column].reduce(0, +)
            let y = Self.padding + CGFloat(index / perRow) * rowHeight
            cells[index].frame = NSRect(x: x, y: y, width: columnWidths[column], height: rowHeight)
        }
        let rows = (cells.count + perRow - 1) / perRow
        setFrameSize(NSSize(width: columnWidths.reduce(0, +) + Self.padding * 2,
                            height: CGFloat(rows) * rowHeight + Self.padding * 2))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, cell) in cells.enumerated() {
            let isHighlighted = index == highlighted
            if isHighlighted {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: cell.frame, xRadius: 4, yRadius: 4).fill()
            }
            let textColor: NSColor = isHighlighted ? .alternateSelectedControlTextColor : .labelColor
            let labelColor: NSColor = isHighlighted ? .alternateSelectedControlTextColor : .secondaryLabelColor

            let textTop = cell.frame.minY + (cell.frame.height - (font.ascender - font.descender)) / 2
            let baseline = textTop + font.ascender
            var x = cell.frame.minX + Self.cellInset.width
            (cell.label as NSString).draw(
                at: NSPoint(x: x, y: baseline - labelFont.ascender),
                withAttributes: [.font: labelFont, .foregroundColor: labelColor])
            x += (cell.label as NSString).size(withAttributes: [.font: labelFont]).width + Self.labelGap
            (cell.text as NSString).draw(
                at: NSPoint(x: x, y: textTop),
                withAttributes: [.font: font, .foregroundColor: textColor])
        }
    }
}

/// Shows a short message (TextService.showMessage()) for a while.
final class MessagePanel {
    static let shared = MessagePanel()

    private let label = NSTextField(labelWithString: "")
    private lazy var panel = makePopupPanel(content: label)
    private var hideTimer: Timer?

    func show(_ message: String, duration: TimeInterval, caret: NSRect) {
        label.stringValue = message
        label.font = NSFont.systemFont(ofSize: 14)
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: 8, y: 4))
        let size = NSSize(width: label.frame.width + 16, height: label.frame.height + 8)
        place(panel, size: size, caret: caret)
        panel.orderFrontRegardless()

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: max(duration, 0.5), repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel.orderOut(nil)
    }
}
