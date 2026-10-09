import AppKit

// Kullanım: swift make_icon.swift <çıktı.iconset klasörü>
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let s = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let margin = s * 0.098
    let box = NSRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let radius = box.width * 0.225
    let path = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)

    // gölge
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(calibratedRed: 0.9, green: 0.36, blue: 0.09, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // degrade
    let gradient = NSGradient(colors: [NSColor(calibratedRed: 1.0, green: 0.60, blue: 0.20, alpha: 1),
                                       NSColor(calibratedRed: 0.86, green: 0.22, blue: 0.10, alpha: 1)])!
    gradient.draw(in: path, angle: -90)

    // üstte hafif parlama
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let gloss = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0.0)])!
    gloss.draw(in: NSRect(x: box.minX, y: box.midY, width: box.width, height: box.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // sembol
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .semibold)
    if let sym = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: sym.size)
        tinted.lockFocus()
        sym.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: sym.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        let r = NSRect(x: (s - sym.size.width) / 2, y: (s - sym.size.height) / 2 - s * 0.01, width: sym.size.width, height: sym.size.height)
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.25)
        sh.shadowBlurRadius = s * 0.02
        sh.shadowOffset = NSSize(width: 0, height: -s * 0.01)
        NSGraphicsContext.saveGraphicsState()
        sh.set()
        tinted.draw(in: r)
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                              ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in sizes {
    try! render(pixels: px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
print("ok")
