import AppKit

// NextGen Envanter uygulama ikonu: sembol/logo kullanılmaz, yalnızca yazı tabanlı "NG" monogramı.
// Kullanım: swift make_icon.swift <çıktı.iconset klasörü>
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
    return base
}

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
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.26)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(calibratedRed: 0.9, green: 0.36, blue: 0.09, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // degrade zemin
    let gradient = NSGradient(colors: [NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.20, alpha: 1),
                                       NSColor(calibratedRed: 0.80, green: 0.22, blue: 0.08, alpha: 1)])!
    gradient.draw(in: path, angle: -90)

    // üstte hafif parlama
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let gloss = NSGradient(colors: [NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0.0)])!
    gloss.draw(in: NSRect(x: box.minX, y: box.midY, width: box.width, height: box.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // "NG" monogramı
    let mono = "NG" as NSString
    let monoAttrs: [NSAttributedString.Key: Any] = [
        .font: roundedFont(size: s * 0.36, weight: .heavy),
        .foregroundColor: NSColor.white,
        .kern: -s * 0.012,
    ]
    let ms = mono.size(withAttributes: monoAttrs)
    let textShadow = NSShadow()
    textShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    textShadow.shadowBlurRadius = s * 0.015
    textShadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    NSGraphicsContext.saveGraphicsState()
    textShadow.set()
    let showCaption = pixels >= 64
    let monoY = (s - ms.height) / 2 + (showCaption ? s * 0.05 : 0)
    mono.draw(at: NSPoint(x: (s - ms.width) / 2, y: monoY), withAttributes: monoAttrs)
    NSGraphicsContext.restoreGraphicsState()

    // alt yazı (küçük boyutlarda okunmayacağı için çizilmez)
    if showCaption {
        let cap = "ENVANTER" as NSString
        let capAttrs: [NSAttributedString.Key: Any] = [
            .font: roundedFont(size: s * 0.075, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88),
            .kern: s * 0.012,
        ]
        let cs = cap.size(withAttributes: capAttrs)
        cap.draw(at: NSPoint(x: (s - cs.width) / 2, y: monoY - cs.height * 0.9), withAttributes: capAttrs)
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
