import CoastlineCore
import Foundation
import simd
import Viewport

extension AppModel {
    /// The clamp kit, parallels and table plate as triangles in the part setup's work frame
    /// (origin at the stock face's centre), for the fixture clearance check.
    /// Cached per placement: building it transforms every kit triangle (a few seconds).
    func clampKitField(stockSize s: SIMD3<Double>) -> FixtureField? {
        let key = "\(s)|\(setup.onBed)|\(String(describing: bedJobPlacement?.clampPoints))|\(String(describing: bedJobPlacement?.clampAngles))|"
            + "\(String(describing: clampPlacement(stockSize: s).map { ($0.clamps, $0.stockFaceZ, $0.stockBottomX, $0.parallels) }))|\(setup.clampSoftJaw)|\(setup.shoulders.map { "\($0)" } ?? "")"
        if let c = clampFieldCache, c.key == key { return c.field }
        let field = buildClampKitField(stockSize: s)
        clampFieldCache = (key, field)
        return field
    }

    private func buildClampKitField(stockSize s: SIMD3<Double>) -> FixtureField? {
        if setup.onBed {
            // Path B: the stop, riser, C-clamps and table.
            guard let st = bedJobStage, let p = bedJobPlacement else { return nil }
            let origin = SIMD3(p.stockBottomX + s.x / 2, bedJobCentreY, p.stockFaceZ)
            let tris = SideClamps.solids(p, table: prepTable, centreY: bedJobCentreY)
                .flatMap { FixtureField.boxTriangles(min: $0.min - origin, max: $0.max - origin) }
            let pad = FixtureClearance.nutRadius + 15
            return FixtureField(triangles: tris, regionMin: SIMD2(-st.stock.x / 2 - pad, -st.stock.y / 2 - pad),
                                regionMax: SIMD2(st.stock.x / 2 + pad, st.stock.y / 2 + pad))
        }
        guard let mm = machineModel, let k = clampKitLayout(stockSize: s), let p = clampPlacement(stockSize: s) else { return nil }
        let origin = SIMD3(p.stockBottomX + s.x / 2, kitCentreY, p.stockFaceZ)
        var tris: [SIMD3<Double>] = []
        for (kit, _, t) in k.instances {
            for (j, tt) in kitPartTransforms(kit: kit, transform: t) {
                let m = kitParts[j].mesh
                let v = m.vertices
                for idx in m.indices {
                    let i = Int(idx) * 3
                    let w = tt * SIMD4(Double(v[i]), Double(v[i + 1]), Double(v[i + 2]), 1)
                    tris.append(SIMD3(w.x, w.y, w.z) - origin)
                }
            }
        }
        for b in k.boxes { tris += FixtureField.boxTriangles(min: b.lo - origin, max: b.hi - origin) }
        let table = prepTable
        tris += FixtureField.boxTriangles(min: SIMD3(mm.tableTopX - FlatPrep.tableThickness, travelCentreY - 200, table.backZ) - origin,
                                          max: SIMD3(mm.tableTopX, travelCentreY + 200, table.northZ) - origin)
        let pad = FixtureClearance.nutRadius + 15
        return FixtureField(triangles: tris, regionMin: SIMD2(-s.x / 2 - pad, -s.y / 2 - pad), regionMax: SIMD2(s.x / 2 + pad, s.y / 2 + pad))
    }

    /// Red crosses where a tool would come too close to a clamp (shown with the side's paths).
    func showClearanceHits() {
        renderer.scene.remove(id: "clearance")
        guard let stock else { return }
        let hits = (viewSide == -1 ? prepPrograms : programs.filter { $0.side == viewSide }).flatMap(\.clearanceHits)
        guard !hits.isEmpty else { return }
        let o = SIMD3<Float>(workOrigin(stockSize: displayStockSize ?? setup.stockSize(stock)))
        let red = SIMD4<UInt8>(255, 40, 40, 255)
        var segs: [LineSegment] = []
        for h in hits {
            let c = SIMD3<Float>(h.position) + o
            for d in [SIMD3<Float>(1.5, 0, 0), SIMD3(0, 1.5, 0), SIMD3(0, 0, 1.5)] { segs.append(LineSegment(c - d, c + d, color: red)) }
        }
        if let set = SceneLines(device: renderer.device, id: "clearance", segments: segs) { renderer.scene.setLines(set) }
    }
}

extension AppModel {
    /// Where the real fixtures (clamp bodies, jaws, screws, stop, C-clamp pads) rise beside or
    /// over the stock, as rectangles in work XY grown by the clearance check's margin: the
    /// roughing keeps out of them and the other operations lift over them. The nominal grip
    /// strips assume a clamp's middle 12 mm in from each end; this follows the kit as placed
    /// (moved clamps, soft jaws, a bar hanging lower than the jaws).
    func fixtureKeepOut(stockSize s: SIMD3<Double>, margin: Double = 0.6) -> [(min: SIMD2<Double>, max: SIMD2<Double>)] {
        guard let f = clampKitField(stockSize: s) else { return [] }
        let floor = Float(-s.z + 0.05)  // anything rising above the stock's back
        // The footprint on the field's own grid, as row spans merged downward into rectangles:
        // the real shape, not a bounding box (a C-clamp's frame bends round the stock), and no
        // coarser than the clearance check (a riser touching the bar's edge keeps out only the
        // check's 0.5 mm + 0.1).
        let k = 1
        let bx = (f.nx + k - 1) / k, by = (f.ny + k - 1) / k
        var block = [Bool](repeating: false, count: bx * by)
        for i in 0..<(f.nx * f.ny) where f.top[i] > floor {
            block[(i / f.nx / k) * bx + (i % f.nx) / k] = true
        }
        let size = Double(k) * f.cell
        var open: [Int: (y0: Int, x1: Int)] = [:]  // span start x → (first row, end x)
        var out: [(min: SIMD2<Double>, max: SIMD2<Double>)] = []
        func close(_ x0: Int, _ v: (y0: Int, x1: Int), _ y1: Int) {
            out.append((SIMD2(f.minX + Double(x0) * size - margin, f.minY + Double(v.y0) * size - margin),
                        SIMD2(f.minX + Double(v.x1) * size + margin, f.minY + Double(y1) * size + margin)))
        }
        for y in 0...by {
            var spans: [Int: Int] = [:]
            if y < by {
                var x = 0
                while x < bx {
                    guard block[y * bx + x] else { x += 1; continue }
                    let x0 = x
                    while x < bx && block[y * bx + x] { x += 1 }
                    spans[x0] = x
                }
            }
            for (x0, v) in open where spans[x0] != v.x1 { close(x0, v, y); open[x0] = nil }
            for (x0, x1) in spans where open[x0] == nil { open[x0] = (y, x1) }
        }
        return out
    }
}
