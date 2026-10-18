// Draws the app icon (1024 × 1024 PNG) with AppKit. Run through scripts/make-icon.sh.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
guard CommandLine.arguments.count > 1 else { fatalError("usage: make-icon.swift <output.png>") }
let output = URL(fileURLWithPath: CommandLine.arguments[1])

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
    guard let context = NSGraphicsContext.current?.cgContext else { return false }

    // macOS icon grid: an 824-point rounded square centered on the 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow under the tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: color(0x000000, 0.35).cgColor)
    context.addPath(tilePath); context.setFillColor(color(0x0B1B33).cgColor); context.fillPath()
    context.restoreGState()

    // Night-blue gradient with a cool glow near the top.
    context.saveGState()
    context.addPath(tilePath); context.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let background = CGGradient(colorsSpace: space, colors: [color(0x16355F).cgColor, color(0x0A1628).cgColor] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [color(0x4FB3FF, 0.35).cgColor, color(0x4FB3FF, 0).cgColor] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 300), startRadius: 0, endCenter: CGPoint(x: 512, y: 300), endRadius: 520, options: [])

    // Airflow: curved streaks fanning out below the unit.
    context.setLineCap(.round)
    let streaks = 7
    for index in 0..<streaks {
        let t = CGFloat(index) / CGFloat(streaks - 1)
        let startX = 300 + 424 * t
        let spread = (t - 0.5) * 230
        let path = CGMutablePath()
        path.move(to: CGPoint(x: startX, y: 505))
        path.addCurve(to: CGPoint(x: startX + spread, y: 760),
                      control1: CGPoint(x: startX + spread * 0.15 + 18, y: 590),
                      control2: CGPoint(x: startX + spread * 0.75 - 18, y: 680))
        context.saveGState()
        context.addPath(path)
        context.setLineWidth(22)
        context.replacePathWithStrokedPath()
        context.clip()
        let fade = CGGradient(colorsSpace: space, colors: [color(0x7FD4FF, 0.95).cgColor, color(0x2E9BFF, 0).cgColor] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(fade, start: CGPoint(x: 0, y: 505), end: CGPoint(x: 0, y: 770), options: [])
        context.restoreGState()
    }

    // The indoor unit.
    let body = CGRect(x: 190, y: 300, width: 644, height: 200)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 58, cornerHeight: 58, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 22), blur: 34, color: color(0x000000, 0.45).cgColor)
    context.addPath(bodyPath); context.setFillColor(color(0xF2F5F8).cgColor); context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(bodyPath); context.clip()
    let shell = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF).cgColor, color(0xC9D2DC).cgColor] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(shell, start: CGPoint(x: 0, y: 300), end: CGPoint(x: 0, y: 500), options: [])
    context.restoreGState()
    // Top highlight.
    context.setFillColor(color(0xFFFFFF, 0.9).cgColor)
    context.addPath(CGPath(roundedRect: CGRect(x: 250, y: 318, width: 524, height: 8), cornerWidth: 4, cornerHeight: 4, transform: nil)); context.fillPath()
    // Louver slot.
    let slot = CGPath(roundedRect: CGRect(x: 280, y: 446, width: 464, height: 24), cornerWidth: 12, cornerHeight: 12, transform: nil)
    context.saveGState()
    context.addPath(slot); context.clip()
    let louver = CGGradient(colorsSpace: space, colors: [color(0x10151C).cgColor, color(0x3A4552).cgColor] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(louver, start: CGPoint(x: 0, y: 446), end: CGPoint(x: 0, y: 470), options: [])
    context.restoreGState()
    // Small display with a cool-blue reading.
    context.setFillColor(color(0x1A222C).cgColor)
    context.addPath(CGPath(roundedRect: CGRect(x: 690, y: 352, width: 96, height: 46), cornerWidth: 12, cornerHeight: 12, transform: nil)); context.fillPath()
    context.setFillColor(color(0x4FC3FF).cgColor)
    for dot in 0..<3 { context.fillEllipse(in: CGRect(x: 706 + CGFloat(dot) * 24, y: 366, width: 16, height: 16)) }

    context.restoreGState()
    return true
}

guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("could not render the icon") }
try png.write(to: output)
print("wrote \(output.path)")
