import CoastlineCore
import SwiftUI

/// A dimensioned side view of a tool hanging in the ER-11 collet: collet nut, shank, flutes and
/// tip shape. Shows what "stick-out" means, which beginners often get wrong.
struct ToolProfileView: View {
    let tool: Tool

    var body: some View {
        Canvas { ctx, size in
            let nutHeight = 16.0, nutWidth = 19.0  // ER-11 hex nut, mm
            let total = nutHeight + tool.stickout
            // Fit the height; the nut may be clipped in width for long tools, never the tool.
            let scale = min((size.height - 30) / total, (size.width * 0.3) / max(tool.diameter, tool.shankDiameter, 1))
            let cx = size.width * 0.5
            var y = 10.0
            let ink = GraphicsContext.Shading.color(.primary)
            let dim = GraphicsContext.Shading.color(.secondary)

            // Collet nut
            let nutDrawWidth = min(nutWidth * scale, size.width * 0.32)
            let nut = CGRect(x: cx - nutDrawWidth / 2, y: y, width: nutDrawWidth, height: nutHeight * scale)
            ctx.fill(Path(roundedRect: nut, cornerRadius: 3), with: .color(.gray.opacity(0.35)))
            ctx.stroke(Path(roundedRect: nut, cornerRadius: 3), with: dim, lineWidth: 1)
            y += nutHeight * scale

            // Shank (below the nut, above the flutes)
            let shankLength = max(tool.stickout - tool.fluteLength, 0)
            let shank = CGRect(x: cx - tool.shankDiameter * scale / 2, y: y, width: tool.shankDiameter * scale, height: shankLength * scale)
            ctx.fill(Path(shank), with: .color(.gray.opacity(0.55)))
            y += shankLength * scale

            // Flutes, with helix hatching
            let fluteLength = min(tool.fluteLength, tool.stickout)
            let w = tool.diameter * scale
            let flutes = CGRect(x: cx - w / 2, y: y, width: w, height: fluteLength * scale)
            var body = Path(flutes)
            let tipY = flutes.maxY
            // Tip shape
            switch tool.kind {
            case .ballEndMill:
                body = Path { p in
                    p.addRect(CGRect(x: flutes.minX, y: flutes.minY, width: w, height: max(flutes.height - w / 2, 0)))
                    p.addArc(center: CGPoint(x: cx, y: max(tipY - w / 2, flutes.minY)), radius: w / 2,
                             startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                }
            case .chamferMill, .engraver, .spotDrill, .drill:
                let half = (tool.angle ?? 45) * (tool.kind == .drill || tool.kind == .spotDrill ? 0.5 : 1)
                let coneHeight = min((w / 2 - tool.tipDiameter * scale / 2) / tan(half * .pi / 180), flutes.height)
                body = Path { p in
                    p.move(to: CGPoint(x: flutes.minX, y: flutes.minY))
                    p.addLine(to: CGPoint(x: flutes.maxX, y: flutes.minY))
                    p.addLine(to: CGPoint(x: flutes.maxX, y: tipY - coneHeight))
                    p.addLine(to: CGPoint(x: cx + tool.tipDiameter * scale / 2, y: tipY))
                    p.addLine(to: CGPoint(x: cx - tool.tipDiameter * scale / 2, y: tipY))
                    p.addLine(to: CGPoint(x: flutes.minX, y: tipY - coneHeight))
                    p.closeSubpath()
                }
            case .bullNoseEndMill:
                body = Path(roundedRect: flutes, cornerSize: CGSize(width: tool.cornerRadius * scale, height: tool.cornerRadius * scale))
            default: break
            }
            ctx.fill(body, with: .color(Theme.accent.opacity(0.55)))
            ctx.stroke(body, with: ink, lineWidth: 1)
            ctx.drawLayer { layer in
                layer.clip(to: body)
                var x = flutes.minX - flutes.height
                while x < flutes.maxX {
                    var hatch = Path()
                    hatch.move(to: CGPoint(x: x, y: flutes.maxY))
                    hatch.addLine(to: CGPoint(x: x + flutes.height * 0.6, y: flutes.minY))
                    layer.stroke(hatch, with: .color(.primary.opacity(0.25)), lineWidth: 1)
                    x += max(w / Double(max(tool.flutes, 1)), 4)
                }
            }

            // Dimensions on the right: stick-out and flute length; diameter below.
            func vDim(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat, _ label: String) {
                var p = Path()
                p.move(to: CGPoint(x: x, y: y0)); p.addLine(to: CGPoint(x: x, y: y1))
                p.move(to: CGPoint(x: x - 4, y: y0)); p.addLine(to: CGPoint(x: x + 4, y: y0))
                p.move(to: CGPoint(x: x - 4, y: y1)); p.addLine(to: CGPoint(x: x + 4, y: y1))
                ctx.stroke(p, with: dim, lineWidth: 1)
                ctx.draw(Text(label).font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: x + 6, y: (y0 + y1) / 2), anchor: .leading)
            }
            let right = cx + max(tool.shankDiameter, tool.diameter) * scale / 2 + 14
            vDim(right, nut.maxY, tipY, "stick-out \(Length.mm(tool.stickout))")
            // Flute length on the left, label pointing left.
            let left = cx - max(tool.shankDiameter, tool.diameter) * scale / 2 - 14
            var p = Path()
            p.move(to: CGPoint(x: left, y: flutes.minY)); p.addLine(to: CGPoint(x: left, y: tipY))
            p.move(to: CGPoint(x: left - 4, y: flutes.minY)); p.addLine(to: CGPoint(x: left + 4, y: flutes.minY))
            p.move(to: CGPoint(x: left - 4, y: tipY)); p.addLine(to: CGPoint(x: left + 4, y: tipY))
            ctx.stroke(p, with: dim, lineWidth: 1)
            ctx.draw(Text("flutes \(Length.mm(tool.fluteLength))").font(.caption2).foregroundStyle(.secondary),
                     at: CGPoint(x: left - 6, y: (flutes.minY + tipY) / 2), anchor: .trailing)
            ctx.draw(Text("⌀ \(Length.describe(tool.diameter))").font(.caption2).foregroundStyle(.secondary),
                     at: CGPoint(x: cx, y: tipY + 4), anchor: .top)
        }
        .frame(height: 190)
        .accessibilityLabel("Side view of the tool in the collet")
    }
}

/// An isometric preview of a stock piece in its material colour, with its dimensions.
struct StockPreview: View {
    let stock: StockItem

    var body: some View {
        Canvas { ctx, size in
            let e = stock.envelope
            let color = stock.material?.swatch ?? .gray
            // Isometric projection: x to the right-down, y to the left-down, z up.
            let c30 = cos(Double.pi / 6), s30 = sin(Double.pi / 6)
            let extentW = (e.x + e.y) * c30, extentH = (e.x + e.y) * s30 + e.z
            let scale = min((size.width - 40) / extentW, (size.height - 40) / extentH)
            let origin = CGPoint(x: size.width / 2 + (e.y - e.x) * c30 * scale / 2,
                                 y: size.height / 2 + extentH * scale / 2 - (e.x + e.y) * s30 * scale)
            func p(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
                CGPoint(x: origin.x + (x - y) * c30 * scale, y: origin.y + (x + y) * s30 * scale - z * scale)
            }
            if stock.shape == .roundBar {
                // A bar along y, drawn as a cylinder with elliptical ends.
                let r = e.x / 2
                let a = p(r, 0, r), b = p(r, e.y, r)
                let rx = r * scale * 0.95, ry = r * scale
                var body = Path()
                body.move(to: CGPoint(x: a.x - rx * 0.5, y: a.y - ry)); body.addLine(to: CGPoint(x: b.x - rx * 0.5, y: b.y - ry))
                body.addLine(to: CGPoint(x: b.x + rx * 0.5, y: b.y + ry)); body.addLine(to: CGPoint(x: a.x + rx * 0.5, y: a.y + ry))
                body.closeSubpath()
                ctx.fill(body, with: .color(color.opacity(0.85)))
                let end = Path(ellipseIn: CGRect(x: a.x - rx * 0.5, y: a.y - ry, width: rx, height: ry * 2))
                ctx.fill(end, with: .color(color))
                ctx.stroke(end, with: .color(.primary.opacity(0.4)), lineWidth: 1)
            } else {
                let top = Path { q in
                    q.move(to: p(0, 0, e.z)); q.addLine(to: p(e.x, 0, e.z)); q.addLine(to: p(e.x, e.y, e.z)); q.addLine(to: p(0, e.y, e.z)); q.closeSubpath()
                }
                let left = Path { q in
                    q.move(to: p(0, e.y, 0)); q.addLine(to: p(e.x, e.y, 0)); q.addLine(to: p(e.x, e.y, e.z)); q.addLine(to: p(0, e.y, e.z)); q.closeSubpath()
                }
                let right = Path { q in
                    q.move(to: p(e.x, 0, 0)); q.addLine(to: p(e.x, e.y, 0)); q.addLine(to: p(e.x, e.y, e.z)); q.addLine(to: p(e.x, 0, e.z)); q.closeSubpath()
                }
                ctx.fill(left, with: .color(color.opacity(0.72)))
                ctx.fill(right, with: .color(color.opacity(0.88)))
                ctx.fill(top, with: .color(color))
                for face in [top, left, right] { ctx.stroke(face, with: .color(.primary.opacity(0.35)), lineWidth: 1) }
                func label(_ s: String, _ at: CGPoint) {
                    ctx.draw(Text(s).font(.caption2.monospacedDigit()).foregroundStyle(.secondary), at: at)
                }
                label(Length.mm(e.x), CGPoint(x: (p(0, e.y, 0).x + p(e.x, e.y, 0).x) / 2 - 10, y: (p(0, e.y, 0).y + p(e.x, e.y, 0).y) / 2 + 12))
                label(Length.mm(e.y), CGPoint(x: (p(e.x, 0, 0).x + p(e.x, e.y, 0).x) / 2 + 10, y: (p(e.x, 0, 0).y + p(e.x, e.y, 0).y) / 2 + 12))
                label(Length.mm(e.z), CGPoint(x: p(e.x, 0, e.z / 2).x + 18, y: p(e.x, 0, e.z / 2).y))
            }
        }
        .frame(height: 150)
        .accessibilityLabel("Preview of the stock, \(stock.sizeDescription)")
    }
}
