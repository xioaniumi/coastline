import CoastlineCore
import Foundation
import simd
import Viewport

/// Holding path D: shoulders at both ends of the bar. The bed prep mills only the two ends
/// down to a height the clamp kit grips; the universal clamps sit on them and the full-height
/// middle carries the part above the jaws.
extension AppModel {
    /// The stepped stock's outline (front and back profiles and the edges along Z).
    func shoulderEdges(stockSize s: SIMD3<Double>, origin o: SIMD3<Double>, color: SIMD4<UInt8>) -> [LineSegment] {
        guard let sh = setup.shoulders else { return [] }
        let lo = SIMD3(-s.x / 2, -s.y / 2, -s.z), hi = SIMD3(s.x / 2, s.y / 2, 0.0)
        let xb = lo.x + sh.bottom, xt = min(xb + sh.height, hi.x), y0 = lo.y + sh.length, y1 = hi.y - sh.length
        let poly: [SIMD2<Double>] = [SIMD2(xb, lo.y), SIMD2(xt, lo.y), SIMD2(xt, y0), SIMD2(hi.x, y0), SIMD2(hi.x, y1), SIMD2(xt, y1),
                                     SIMD2(xt, hi.y), SIMD2(xb, hi.y), SIMD2(xb, y1), SIMD2(lo.x, y1), SIMD2(lo.x, y0), SIMD2(xb, y0)]
        var out: [LineSegment] = []
        for k in poly.indices {
            let a = poly[k], b = poly[(k + 1) % poly.count]
            guard simd_distance(a, b) > 1e-9 else { continue }
            for z in [lo.z, hi.z] {
                out.append(LineSegment(SIMD3<Float>(SIMD3(a.x, a.y, z) + o), SIMD3<Float>(SIMD3(b.x, b.y, z) + o), color: color))
            }
            out.append(LineSegment(SIMD3<Float>(SIMD3(a.x, a.y, lo.z) + o), SIMD3<Float>(SIMD3(a.x, a.y, hi.z) + o), color: color))
        }
        return out
    }

    /// Heightmap cells (work XY) with no stock at all: the shoulders' removed corners.
    func shoulderOpen(_ hm: Heightmap, stockSize s: SIMD3<Double>) -> [Bool]? {
        guard showingShoulders, let sh = setup.shoulders, !setup.shoulderCuts(stockSize: s).isEmpty else { return nil }
        var open = [Bool](repeating: false, count: hm.cols * hm.rows)
        let xb = -s.x / 2 + sh.bottom, xt = xb + sh.height, yEdge = s.y / 2 - sh.length
        for r in 0..<hm.rows {
            let y = hm.origin.y + Double(r) * hm.cell
            guard abs(y) > yEdge else { continue }
            for c in 0..<hm.cols {
                let x = hm.origin.x + Double(c) * hm.cell
                if x > xt || x < xb { open[r * hm.cols + c] = true }
            }
        }
        return open
    }

    /// The clamped zones on path D (work XY): the bottom edge along the whole bar (it sits on
    /// the lower jaws) and, at each end, everything above the shoulder's grip line (the clamp's
    /// screws and jaw are there; what's left of the bar there is the shoulder).
    func shoulderStrips(stockSize s: SIMD3<Double>) -> [(min: SIMD2<Double>, max: SIMD2<Double>)] {
        guard let sh = setup.shoulders else { return GripZones.strips(stock: s) }
        let g = GripZones.grip, out = 30.0
        let gripBottom = -s.x / 2 + sh.bottom, gripTop = gripBottom + sh.height
        // Only at the ends, where the jaws are: the shoulder's bottom on the lower jaw and its
        // top under the screws (and the air beyond both). In between, the part may reach the
        // bar's edges.
        let zone = Shoulders.gripZone + 0.5
        return [
            (SIMD2(-s.x / 2 - out, -s.y / 2 - out), SIMD2(gripBottom + g, -s.y / 2 + zone)),
            (SIMD2(-s.x / 2 - out, s.y / 2 - zone), SIMD2(gripBottom + g, s.y / 2 + out)),
            (SIMD2(gripTop - g, -s.y / 2 - out), SIMD2(s.x / 2 + out, -s.y / 2 + zone)),
            (SIMD2(gripTop - g, s.y / 2 - zone), SIMD2(s.x / 2 + out, s.y / 2 + out)),
        ]
    }
}
