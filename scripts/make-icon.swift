// Draws the app icon (a teal stepped sparkline and dot on near-black) and writes
// Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // macOS icon grid: 824pt rounded square centred in 1024.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(white: 0.13, alpha: 1), NSColor(white: 0.04, alpha: 1)])!
        .draw(in: shape, angle: -90)
    let teal = NSColor(red: 0.36, green: 0.92, blue: 0.78, alpha: 1)

    // Stepped sparkline with a soft fill underneath.
    let steps: [(CGFloat, CGFloat)] = [(200, 360), (360, 360), (360, 450), (520, 450), (520, 410),
                                       (640, 410), (640, 590), (824, 590)]
    let line = NSBezierPath()
    line.move(to: NSPoint(x: steps[0].0 * s, y: steps[0].1 * s))
    for (x, y) in steps.dropFirst() { line.line(to: NSPoint(x: x * s, y: y * s)) }
    let fill = line.copy() as! NSBezierPath
    fill.line(to: NSPoint(x: 824 * s, y: 250 * s))
    fill.line(to: NSPoint(x: 200 * s, y: 250 * s))
    fill.close()
    NSGradient(colors: [teal.withAlphaComponent(0.35), teal.withAlphaComponent(0)])!.draw(in: fill, angle: -90)
    teal.setStroke()
    line.lineWidth = 34 * s
    line.lineJoinStyle = .round
    line.lineCapStyle = .round
    line.stroke()

    // Live dot, top left, like the panel's title row.
    teal.setFill()
    NSBezierPath(ovalIn: NSRect(x: 215 * s, y: 690 * s, width: 70 * s, height: 70 * s)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        let data = render(CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! data.write(to: iconset.appendingPathComponent(name))
    }
}
