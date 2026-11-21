// Génère Resources/AppIcon.icns : swift Tools/MakeIcon.swift
import AppKit

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    let space = CGColorSpaceCreateDeviceRGB()

    // Fond « squircle » sombre
    let bg = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bgPath = CGPath(roundedRect: bg, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(bgPath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bgPath); ctx.clip()
    let bgGrad = CGGradient(colorsSpace: space, colors: [
        NSColor(calibratedRed: 0.16, green: 0.10, blue: 0.28, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.09, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])

    let c = CGPoint(x: 512, y: 512)
    // Halo vert
    let halo = CGGradient(colorsSpace: space, colors: [
        NSColor(calibratedRed: 0.12, green: 0.85, blue: 0.45, alpha: 0.55).cgColor,
        NSColor(calibratedRed: 0.12, green: 0.85, blue: 0.45, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: c, startRadius: 300, endCenter: c, endRadius: 420, options: [])

    // Onde autour
    let n = 96
    let wave = CGMutablePath()
    for i in 0...n {
        let a = Double(i) / Double(n) * 2 * .pi
        let k = Double(i % (n / 2)) / Double(n / 2)
        let v = 0.5 + 0.5 * sin(a * 6) * cos(a * 3) * (1 - k * 0.3)
        let r = 318 + CGFloat(max(v, 0.05)) * 70
        let p = CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
        i == 0 ? wave.move(to: p) : wave.addLine(to: p)
    }
    wave.closeSubpath()
    ctx.addPath(wave)
    ctx.setFillColor(NSColor(calibratedRed: 0.2, green: 0.95, blue: 0.55, alpha: 0.35).cgColor)
    ctx.fillPath()
    ctx.addPath(wave)
    ctx.setStrokeColor(NSColor(calibratedRed: 0.45, green: 1, blue: 0.7, alpha: 0.9).cgColor)
    ctx.setLineWidth(6); ctx.strokePath()

    // Disque
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.6).cgColor)
    ctx.addEllipse(in: CGRect(x: c.x - 310, y: c.y - 310, width: 620, height: 620))
    ctx.setFillColor(NSColor(white: 0.05, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()
    // Sillons
    var r: CGFloat = 140
    var i = 0
    while r < 300 {
        let alpha = 0.04 + 0.06 * abs(sin(Double(i) * 1.7))
        ctx.setStrokeColor(NSColor(white: 1, alpha: alpha).cgColor)
        ctx.setLineWidth(1.6)
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        r += 5; i += 1
    }
    // Reflets
    for (start, end) in [(0.6, 1.0), (3.75, 4.1)] {
        let p = CGMutablePath()
        p.addArc(center: c, radius: 225, startAngle: start, endAngle: end, clockwise: false)
        ctx.addPath(p)
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.22).cgColor)
        ctx.setLineWidth(150); ctx.strokePath()
    }
    // Étiquette
    let labelRect = CGRect(x: c.x - 130, y: c.y - 130, width: 260, height: 260)
    ctx.saveGState()
    ctx.addEllipse(in: labelRect); ctx.clip()
    let label = CGGradient(colorsSpace: space, colors: [
        NSColor(calibratedRed: 0.13, green: 0.88, blue: 0.47, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.95, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(label, start: CGPoint(x: labelRect.minX, y: labelRect.maxY),
                           end: CGPoint(x: labelRect.maxX, y: labelRect.minY), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(NSColor(white: 0, alpha: 0.35).cgColor); ctx.setLineWidth(6)
    ctx.strokeEllipse(in: labelRect)
    // Trou
    ctx.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - 26, y: c.y - 26, width: 52, height: 52))
    ctx.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26))
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(base * scale).representation(using: .png, properties: [:])!
        try! data.write(to: iconset.appendingPathComponent(name))
    }
}
print(iconset.path)
