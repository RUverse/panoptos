// Generates the disk-image assets scripts/release.sh embeds in Panoptos.dmg:
//
//   VolumeIcon.icns    a white folder holding the Panoptos mark, so the mounted
//                      image is distinguishable from the app itself
//   background.png     the Finder window backdrop with a drag arrow between
//   background@2x.png  the app and the Applications alias
//
// Usage: swift scripts/dmg-assets.swift GLYPH_SVG OUTPUT_DIR
//
// GLYPH_SVG is the 1024-point app icon glyph. Rendering it here keeps the
// disk image following the app icon without a second copy of the mark.

import AppKit

// Finder window content size in points and the icon positions the release
// script hands to Finder. The arrow is drawn between the two 128-point icons.
let windowSize = NSSize(width: 660, height: 400)
let appIconCenter = NSPoint(x: 180, y: 190)
let applicationsIconCenter = NSPoint(x: 480, y: 190)
let iconSize: CGFloat = 128

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: dmg-assets.swift GLYPH_SVG OUTPUT_DIR\n".utf8))
    exit(2)
}
let glyphPath = arguments[1]
let outputDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
guard let glyph = NSImage(contentsOfFile: glyphPath) else {
    FileHandle.standardError.write(Data("cannot read glyph \(glyphPath)\n".utf8))
    exit(1)
}
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// Draws into a bitmap of the given pixel size with a top-left origin, so the
/// drawing code reads like the Finder coordinates it mirrors.
func render(pixelSize: NSSize, scale: CGFloat, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(pixelSize.width), pixelsHigh: Int(pixelSize.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    // The context already maps points to pixels from `rep.size`; only flip.
    let cg = context.cgContext
    cg.translateBy(x: 0, y: rep.size.height)
    cg.scaleBy(x: 1, y: -1)
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// The glyph recolored, drawn into `rect` in the current (flipped) context.
func drawGlyph(in rect: CGRect, color: NSColor, context cg: CGContext) {
    cg.saveGState()
    // Undo the flip locally so the image is not drawn upside down.
    cg.translateBy(x: rect.minX, y: rect.maxY)
    cg.scaleBy(x: 1, y: -1)
    let tinted = NSImage(size: glyph.size, flipped: false) { drawRect in
        glyph.draw(in: drawRect)
        color.setFill()
        drawRect.fill(using: .sourceIn)
        return true
    }
    tinted.draw(in: CGRect(origin: .zero, size: rect.size))
    cg.restoreGState()
}

// MARK: - Volume icon

func drawFolderIcon(canvas: CGFloat, context cg: CGContext) {
    let unit = canvas / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x * unit, y: y * unit, width: w * unit, height: h * unit)
    }

    // Back panel with the tab, slightly darker so the folder reads as a folder
    // even against a white Finder background.
    let back = CGMutablePath()
    back.addRoundedRect(in: r(96, 232, 832, 616), cornerWidth: 56 * unit, cornerHeight: 56 * unit)
    back.addRoundedRect(in: r(96, 176, 340, 140), cornerWidth: 48 * unit, cornerHeight: 48 * unit)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12 * unit), blur: 28 * unit,
                 color: NSColor.black.withAlphaComponent(0.22).cgColor)
    cg.addPath(back)
    cg.setFillColor(NSColor(white: 0.84, alpha: 1).cgColor)
    cg.fillPath()
    cg.restoreGState()

    // Front body, white with a faint edge so it stays visible on white.
    let front = CGPath(roundedRect: r(96, 312, 832, 536), cornerWidth: 56 * unit, cornerHeight: 56 * unit, transform: nil)
    cg.saveGState()
    cg.addPath(front)
    cg.clip()
    let colors = [NSColor(white: 1, alpha: 1).cgColor, NSColor(white: 0.955, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 312 * unit), end: CGPoint(x: 0, y: 848 * unit), options: [])
    cg.restoreGState()
    cg.addPath(front)
    cg.setStrokeColor(NSColor(white: 0.78, alpha: 1).cgColor)
    cg.setLineWidth(4 * unit)
    cg.strokePath()

    // The mark, centered on the front body.
    let markSize: CGFloat = 420
    let frontCenter = CGPoint(x: 512, y: 580)
    drawGlyph(in: r(frontCenter.x - markSize / 2, frontCenter.y - markSize / 2, markSize, markSize),
              color: NSColor(white: 0.22, alpha: 1), context: cg)
}

let iconset = outputDirectory.appendingPathComponent("VolumeIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = CGFloat(points * scale)
        let rep = render(pixelSize: NSSize(width: pixels, height: pixels), scale: CGFloat(scale)) { cg in
            drawFolderIcon(canvas: CGFloat(points), context: cg)
        }
        let suffix = scale == 1 ? "" : "@2x"
        try writePNG(rep, to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputDirectory.appendingPathComponent("VolumeIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
try FileManager.default.removeItem(at: iconset)

// MARK: - Window background

func drawBackground(context cg: CGContext) {
    cg.setFillColor(NSColor.white.cgColor)
    cg.fill(CGRect(origin: .zero, size: windowSize))

    let gap: CGFloat = 22
    let start = CGPoint(x: appIconCenter.x + iconSize / 2 + gap, y: appIconCenter.y)
    let end = CGPoint(x: applicationsIconCenter.x - iconSize / 2 - gap, y: applicationsIconCenter.y)
    let headLength: CGFloat = 26
    let headHalfWidth: CGFloat = 18

    cg.setStrokeColor(NSColor(white: 0.72, alpha: 1).cgColor)
    cg.setFillColor(NSColor(white: 0.72, alpha: 1).cgColor)
    cg.setLineWidth(7)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)

    cg.move(to: start)
    cg.addLine(to: CGPoint(x: end.x - headLength + 4, y: end.y))
    cg.strokePath()

    cg.move(to: end)
    cg.addLine(to: CGPoint(x: end.x - headLength, y: end.y - headHalfWidth))
    cg.addLine(to: CGPoint(x: end.x - headLength, y: end.y + headHalfWidth))
    cg.closePath()
    cg.drawPath(using: .fillStroke)
}

for scale in [1, 2] {
    let pixels = NSSize(width: windowSize.width * CGFloat(scale), height: windowSize.height * CGFloat(scale))
    let rep = render(pixelSize: pixels, scale: CGFloat(scale)) { cg in drawBackground(context: cg) }
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try writePNG(rep, to: outputDirectory.appendingPathComponent(name))
}
