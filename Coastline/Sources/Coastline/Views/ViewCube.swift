import SwiftUI
import simd
import Viewport

/// The orientation cube, in the style of PreForm's: a cube with bevelled edges and cut corners.
/// The 6 faces (squares with clipped corners), the 12 edge strips (long rectangles) and the 8
/// hexagonal corners are all clickable. Faces give the standard views, edges the views between two
/// faces, corners the isometric views. Faces are named for the CR-1: TOOL is the side the
/// spindle comes from. Clicks ease the camera round (`ViewportRenderer.moveCamera`).
struct ViewCube: View {
    let camera: OrbitCamera
    var onPick: (SIMD3<Float>, OrbitCamera.StandardView?) -> Void
    @State private var hovered: Int?

    struct Facet {
        let normal: SIMD3<Float>
        let corners: [SIMD3<Float>]
        let label: String?
        let view: OrbitCamera.StandardView?
        let kind: Int  // 0 face, 1 edge, 2 corner
    }

    /// Display space: +Z up, +Y toward the spindle (TOOL), −Y the operator (FRONT), +X right.
    /// The solid is the cube |x|,|y|,|z| ≤ 1 cut by the 12 edge planes (±x ± y)·n ≤ edge and the
    /// 8 corner planes (±x ± y ± z)·n ≤ corner. Each facet is its plane clipped by all the others.
    /// With edge planes at 1.6/√2 the faces are 0.6 squares. Corner planes below 2·1.6 − 1 = 2.2
    /// cut into the faces too, so each corner is a hexagon (three sides on the faces, three on
    /// the edge strips) and the edge strips are plain rectangles, as on PreForm's cube.
    static let facets: [Facet] = {
        let edge: Float = 1.6, corner: Float = 2.1
        var planes: [(n: SIMD3<Float>, d: Float, kind: Int)] = []
        for axis in 0..<3 {
            for s: Float in [1, -1] {
                var n = SIMD3<Float>(0, 0, 0)
                n[axis] = s
                planes.append((n, 1, 0))
            }
        }
        for i in 0..<3 {
            for j in (i + 1)..<3 {
                for si: Float in [1, -1] {
                    for sj: Float in [1, -1] {
                        var n = SIMD3<Float>(0, 0, 0)
                        n[i] = si; n[j] = sj
                        planes.append((simd_normalize(n), edge / sqrt(2), 1))
                    }
                }
            }
        }
        for sx: Float in [1, -1] {
            for sy: Float in [1, -1] {
                for sz: Float in [1, -1] {
                    planes.append((simd_normalize(SIMD3(sx, sy, sz)), corner / sqrt(3), 2))
                }
            }
        }
        // A big square in each plane, clipped by every other half-space (Sutherland–Hodgman).
        func polygon(_ k: Int) -> [SIMD3<Float>] {
            let (n, d, _) = planes[k]
            let u = simd_normalize(abs(n.z) < 0.9 ? simd_cross(SIMD3(0, 0, 1), n) : simd_cross(SIMD3(1, 0, 0), n))
            let v = simd_cross(n, u)
            let c = n * d
            var poly = [c - 3 * u - 3 * v, c + 3 * u - 3 * v, c + 3 * u + 3 * v, c - 3 * u + 3 * v]
            for (m, (pn, pd, _)) in planes.enumerated() where m != k {
                var out: [SIMD3<Float>] = []
                for (a, b) in zip(poly, poly.dropFirst() + poly.prefix(1)) {
                    let da = simd_dot(pn, a) - pd, db = simd_dot(pn, b) - pd
                    if da <= 1e-6 { out.append(a) }
                    if (da < -1e-6 && db > 1e-6) || (da > 1e-6 && db < -1e-6) { out.append(a + (b - a) * (da / (da - db))) }
                }
                poly = out
                if poly.isEmpty { break }
            }
            // Drop repeated points left where three planes meet.
            var clean: [SIMD3<Float>] = []
            for p in poly where clean.last.map({ simd_distance($0, p) > 1e-4 }) ?? true { clean.append(p) }
            if let f = clean.first, let l = clean.last, clean.count > 1, simd_distance(f, l) <= 1e-4 { clean.removeLast() }
            return clean
        }
        let names: [Int: (String, OrbitCamera.StandardView?)] = [
            0: ("RIGHT", .right), 1: ("LEFT", .left), 2: ("TOOL", .tool), 3: ("FRONT", .front), 4: ("TOP", .top), 5: ("BOTTOM", nil),
        ]
        return planes.indices.compactMap { k in
            let pts = polygon(k)
            guard pts.count >= 3 else { return nil }
            let (n, _, kind) = planes[k]
            return Facet(normal: n, corners: pts, label: kind == 0 ? names[k]?.0 : nil, view: kind == 0 ? names[k]?.1 : nil, kind: kind)
        }
    }()

    private struct Projected {
        let index: Int
        let points: [CGPoint]
        let facing: Float
        let depth: Float
        let shade: Double
        let axisU: CGVector
        let axisV: CGVector
        let centre: CGPoint
    }

    var body: some View {
        cube
            // VoiceOver: one element, an action per standard view (the cube is drawn, not controls).
            .accessibilityElement()
            .accessibilityLabel("View Cube")
            .accessibilityHint("Turns the 3D view. Use the actions to view from a side.")
            .accessibilityAddTraits(.isButton)
            .modifier(StandardViewActions(onPick: onPick))
    }

    private var cube: some View {
        Group {
            let projected = project()
            Canvas { ctx, _ in
                for f in projected {
                    let facet = Self.facets[f.index]
                    let path = Path { p in
                        p.move(to: f.points[0])
                        f.points.dropFirst().forEach { p.addLine(to: $0) }
                        p.closeSubpath()
                    }
                    let base: Double = facet.kind == 0 ? 0.90 : (facet.kind == 1 ? 0.80 : 0.74)
                    let grey = min(base * f.shade, 0.97)
                    let fill: Color = hovered == f.index ? Theme.accent : Color(white: grey)
                    ctx.fill(path, with: .color(fill))
                    ctx.stroke(path, with: .color(Color(white: 0.45)), lineWidth: 0.8)
                    if let label = facet.label, f.facing > 0.25 {
                        // Print the label on the face: map text space onto the face's projected axes.
                        // Face axes are ~30 px per unit; normalise so the text is set at a real
                        // point size and only foreshortened by the face's tilt.
                        var c = ctx
                        c.translateBy(x: f.centre.x, y: f.centre.y)
                        c.concatenate(CGAffineTransform(a: f.axisU.dx / 30, b: f.axisU.dy / 30,
                                                        c: f.axisV.dx / 30, d: f.axisV.dy / 30, tx: 0, ty: 0))
                        c.draw(Text(label).font(.system(size: label.count > 4 ? 9 : 10, weight: .heavy))
                                   .foregroundStyle(Color(white: 0.28)), at: .zero, anchor: .center)
                    }
                }
            }
            .frame(width: 96, height: 96)
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hovered = hit(p, projected) } else { hovered = nil }
            }
            .onTapGesture { p in
                guard let i = hit(p, projected) else { return }
                let facet = Self.facets[i]
                onPick(facet.normal, facet.view)
            }
        }
        .help("Click a face, edge or corner to view from there")
    }

    private func project() -> [Projected] {
        let view = camera.viewMatrix()
        let rot = simd_float3x3(SIMD3(view.columns.0.x, view.columns.0.y, view.columns.0.z),
                                SIMD3(view.columns.1.x, view.columns.1.y, view.columns.1.z),
                                SIMD3(view.columns.2.x, view.columns.2.y, view.columns.2.z))
        let scale: Float = 30, mid: CGFloat = 48
        func screen(_ p: SIMD3<Float>) -> CGPoint {
            let v = rot * p
            return CGPoint(x: mid + CGFloat(v.x * scale), y: mid - CGFloat(v.y * scale))
        }
        let light = simd_normalize(SIMD3<Float>(-0.3, 0.6, 1))
        return Self.facets.enumerated().compactMap { i, f in
            let n = rot * f.normal
            guard n.z > 0.001 else { return nil }
            let pts = f.corners.map(screen)
            let c = f.corners.reduce(.zero, +) / Float(f.corners.count)
            // Face axes for printing labels: "right" and "down" in the face plane.
            let up: SIMD3<Float> = abs(f.normal.z) > 0.9 ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1)
            let right = simd_normalize(simd_cross(up, f.normal))
            let o = screen(c), r = screen(c + right), d = screen(c - up)
            let shade = 0.75 + 0.3 * Double(max(simd_dot(n, light), 0))
            return Projected(index: i, points: pts, facing: n.z, depth: (rot * c).z, shade: shade,
                             axisU: CGVector(dx: r.x - o.x, dy: r.y - o.y), axisV: CGVector(dx: d.x - o.x, dy: d.y - o.y), centre: o)
        }
        .sorted { $0.depth < $1.depth }
    }

    private func hit(_ p: CGPoint, _ faces: [Projected]) -> Int? {
        for f in faces.reversed() {
            let path = Path { q in
                q.move(to: f.points[0])
                f.points.dropFirst().forEach { q.addLine(to: $0) }
                q.closeSubpath()
            }
            if path.contains(p) { return f.index }
        }
        return nil
    }
}

/// The view cube's VoiceOver actions: one per standard view, and Bottom (which has none).
private struct StandardViewActions: ViewModifier {
    var onPick: (SIMD3<Float>, OrbitCamera.StandardView?) -> Void

    func body(content: Content) -> some View {
        let views: [(String, SIMD3<Float>, OrbitCamera.StandardView?)] = [
            ("Tool", SIMD3<Float>(0, 1, 0), .tool), ("Front", SIMD3<Float>(0, -1, 0), .front),
            ("Top", SIMD3<Float>(0, 0, 1), .top), ("Bottom", SIMD3<Float>(0, 0, -1), nil),
            ("Right", SIMD3<Float>(1, 0, 0), .right), ("Left", SIMD3<Float>(-1, 0, 0), .left),
            ("Iso", simd_normalize(SIMD3<Float>(1, -1, 1)), .iso), ("Tool Iso", simd_normalize(SIMD3<Float>(1, 1, 1)), .toolIso),
        ]
        return content.accessibilityActions {
            ForEach(views, id: \.0) { name, normal, view in
                Button(name) { onPick(normal, view) }
            }
        }
    }
}
