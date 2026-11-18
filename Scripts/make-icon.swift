// Zeichnet das App-Symbol von PDF to me als PNG mit 1024 × 1024 Pixeln.
// Aufruf: swift Scripts/make-icon.swift <Ziel.png>. build-app.sh macht daraus mit iconutil die AppIcon.icns.
// Das Symbol entsteht beim Bauen, damit keine Binärdatei im Repo liegt. Stil wie Scan to me: Verlauf, weißes Blatt,
// oranges Abzeichen; hier blau mit zwei Seiten (zusammenführen und ordnen). Keine SF Symbols, Apple erlaubt sie
// nicht in App-Symbolen.
import AppKit

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Hintergrund: abgerundetes Quadrat im Raster der macOS-Symbole (824 von 1024), oben hell, unten dunkel.
let background = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: rgb(0x2F7FD0), ending: rgb(0x1A4A86))!.draw(in: background, angle: -90)

// Blatt mit Eselsohr.
let left = 270.0, right = 670.0, top = 744.0, bottom = 204.0, fold = 100.0
let sheet = NSBezierPath()
sheet.move(to: NSPoint(x: left, y: bottom))
sheet.line(to: NSPoint(x: left, y: top))
sheet.line(to: NSPoint(x: right - fold, y: top))
sheet.line(to: NSPoint(x: right, y: top - fold))
sheet.line(to: NSPoint(x: right, y: bottom))
sheet.close()
NSColor.white.setFill()
sheet.fill()
let ear = NSBezierPath()
ear.move(to: NSPoint(x: right - fold, y: top))
ear.line(to: NSPoint(x: right - fold, y: top - fold))
ear.line(to: NSPoint(x: right, y: top - fold))
ear.close()
rgb(0xC9DDF2).setFill()
ear.fill()

// Textzeilen.
rgb(0x9DB6D0).setFill()
for (index, width) in [200.0, 300.0, 300.0, 300.0, 230.0, 300.0].enumerated() {
    let y = top - 90 - Double(index) * 55
    NSBezierPath(roundedRect: NSRect(x: 320, y: y - 12, width: width, height: 24), xRadius: 12, yRadius: 12).fill()
}

// Abzeichen unten rechts: weißer Ring, orange Fläche, zwei versetzte Seiten.
let orange = rgb(0xF08C1E)
let center = NSPoint(x: 680, y: 308), radius = 145.0, ring = 14.0
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: center.x - radius - ring, y: center.y - radius - ring,
                            width: 2 * (radius + ring), height: 2 * (radius + ring))).fill()
orange.setFill()
NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)).fill()

NSColor.white.setStroke()
let back = NSBezierPath(roundedRect: NSRect(x: center.x - 62, y: center.y - 30, width: 90, height: 115),
                        xRadius: 10, yRadius: 10)
back.lineWidth = 16
back.stroke()
let front = NSRect(x: center.x - 28, y: center.y - 85, width: 90, height: 115)
orange.setFill()
NSBezierPath(roundedRect: front.insetBy(dx: -14, dy: -14), xRadius: 18, yRadius: 18).fill()
NSColor.white.setFill()
NSBezierPath(roundedRect: front, xRadius: 10, yRadius: 10).fill()

NSGraphicsContext.restoreGraphicsState()
let url = URL(fileURLWithPath: CommandLine.arguments[1])
try rep.representation(using: .png, properties: [:])!.write(to: url)
