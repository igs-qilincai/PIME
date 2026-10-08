// Draws the menu bar icon of the input method: a character knocked out of a
// rounded square, in the style of the system input sources. The result is
// a template image (only alpha matters), so macOS tints it for light and
// dark menus. Writes a TIFF with 16x16 (1x) and 32x32 (2x) images.
//
// Usage: make_icon <character> <output.tiff>
//
// Written with assistance from Claude Code (Claude Opus 5.5).

import AppKit
import CoreText

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make_icon <character> <output.tiff>\n".utf8))
    exit(2)
}
let text = arguments[1]
let outputURL = URL(fileURLWithPath: arguments[2])

let canvas: CGFloat = 16  // points
let cornerRadius: CGFloat = 3.5
let maxGlyphSize: CGFloat = 12  // the larger side of the glyph's ink box
let fontName = "PingFangTC-Semibold" as CFString

func makeLine(fontSize: CGFloat) -> CTLine {
    let font = CTFontCreateWithName(fontName, fontSize, nil)
    let string = NSAttributedString(string: text, attributes: [.font: font])
    return CTLineCreateWithAttributedString(string)
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(canvas * scale)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = context.cgContext
    cg.textMatrix = .identity
    let size = canvas * scale

    // Everything is drawn in pixels.
    cg.setFillColor(NSColor.black.cgColor)
    cg.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                      cornerWidth: cornerRadius * scale, cornerHeight: cornerRadius * scale,
                      transform: nil))
    cg.fillPath()

    // Center the glyph by its ink bounds rather than by font metrics.
    let probe = CTLineGetImageBounds(makeLine(fontSize: 100), cg)
    let fontSize = 100 * maxGlyphSize * scale / max(probe.width, probe.height)
    let line = makeLine(fontSize: fontSize)
    let ink = CTLineGetImageBounds(line, cg)
    cg.setBlendMode(.destinationOut)
    cg.textPosition = CGPoint(x: ((size - ink.width) / 2 - ink.minX).rounded(),
                              y: ((size - ink.height) / 2 - ink.minY).rounded())
    CTLineDraw(line, cg)
    context.flushGraphics()

    rep.size = NSSize(width: canvas, height: canvas)
    return rep
}

guard let data = NSBitmapImageRep.tiffRepresentationOfImageReps(in: [render(scale: 1), render(scale: 2)]) else {
    FileHandle.standardError.write(Data("failed to encode the icon\n".utf8))
    exit(1)
}
try data.write(to: outputURL)
