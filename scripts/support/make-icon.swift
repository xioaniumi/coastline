// Draws Coastline's app icon (three stacked waves on a blue gradient) at 1024 px, on macOS's
// icon grid (824 px rounded square, transparent margins): `swift make-icon.swift out.png`.
// Deliberately flat, like a classic .icns: an opaque gradient square and solid white waves, no
// baked-in glass, shadows or translucency. macOS 26 makes its tinted and clear Dock looks from
// that (the bright glyph stays, the square turns to glass); an Icon Composer render with glass
// baked in comes out as one tinted blob. resources/icon/Coastline.icon is the same design for an
// Xcode build (actool → Assets.car).
import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size)
// The rounded square, sky cyan at the top to deep ocean blue at the bottom.
let body = NSBezierPath(roundedRect: rect.insetBy(dx: 100, dy: 100), xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(displayP3Red: 0.020, green: 0.290, blue: 0.620, alpha: 1),
                    NSColor(displayP3Red: 0.120, green: 0.620, blue: 0.900, alpha: 1)])!
    .draw(in: body, angle: 90)
// Three waves, two crests each, solid white (as in the Icon Composer file, scaled onto the
// 824 px square).
let x0 = 100 + 236 * 0.8047, x1 = 100 + 788 * 0.8047, amp = 36 * 0.8047, humps = 4
let span = (x1 - x0) / Double(humps)
for yTop in [352.0, 512.0, 672.0] {
    let y = size - (100 + yTop * 0.8047)  // AppKit's y runs up
    let wave = NSBezierPath()
    wave.move(to: NSPoint(x: x0, y: y))
    for h in 0..<humps {
        let s = h % 2 == 0 ? 1.0 : -1.0  // up first
        let xa = x0 + Double(h) * span
        wave.curve(to: NSPoint(x: xa + span, y: y),
                   controlPoint1: NSPoint(x: xa + 0.36 * span, y: y + s * 1.27 * amp),
                   controlPoint2: NSPoint(x: xa + 0.64 * span, y: y + s * 1.27 * amp))
    }
    wave.lineWidth = 66 * 0.8047
    wave.lineCapStyle = .round
    wave.lineJoinStyle = .round
    NSColor.white.setStroke()
    wave.stroke()
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
