import Foundation

/// Material-removal simulation for 3-axis milling from +Z: a grid of heights over the stock
/// face (work frame). Each cutting move lowers the cells under the swept tool. Exact enough to
/// show stock removal, leftover material and gouges; a tri-dexel model replaces it for
/// multi-setup work.
public struct Heightmap: Sendable {
    public let origin: SIMD2<Double>   // XY of cell (0, 0) centre
    public let cell: Double
    public let cols: Int, rows: Int
    public let top: Double, bottom: Double
    public var heights: [Float]
    /// Bounding box of cells changed since the last `takeDirty()` (col0, row0, col1, row1).
    public private(set) var dirty: (Int, Int, Int, Int)?

    public init(stockMin: SIMD3<Double>, stockMax: SIMD3<Double>, maxCells: Int = 300_000) {
        let w = stockMax.x - stockMin.x, h = stockMax.y - stockMin.y
        let c = max((w * h / Double(maxCells)).squareRoot(), 0.05)
        cell = c
        cols = max(Int((w / c).rounded(.up)), 2)
        rows = max(Int((h / c).rounded(.up)), 2)
        origin = SIMD2(stockMin.x + c / 2, stockMin.y + c / 2)
        top = stockMax.z
        bottom = stockMin.z
        heights = [Float](repeating: Float(stockMax.z), count: cols * rows)
    }

    public func height(col: Int, row: Int) -> Float { heights[row * cols + col] }

    /// Lowers the material under a tool moving from a to b (straight line, any Z).
    /// - Parameters: radius = tool radius; cornerRadius = 0 flat, radius ball, between = bull.
    public mutating func cut(from a: SIMD3<Double>, to b: SIMD3<Double>, radius r: Double, cornerRadius rc: Double) {
        if a.z >= top && b.z >= top { return }
        let minX = min(a.x, b.x) - r, maxX = max(a.x, b.x) + r
        let minY = min(a.y, b.y) - r, maxY = max(a.y, b.y) + r
        let c0 = max(Int(((minX - origin.x) / cell).rounded(.down)), 0)
        let c1 = min(Int(((maxX - origin.x) / cell).rounded(.up)), cols - 1)
        let r0 = max(Int(((minY - origin.y) / cell).rounded(.down)), 0)
        let r1 = min(Int(((maxY - origin.y) / cell).rounded(.up)), rows - 1)
        guard c0 <= c1, r0 <= r1 else { return }
        let d = SIMD2(b.x - a.x, b.y - a.y)
        let len2 = (d * d).sum()
        let rc = min(max(rc, 0), r)
        let flatR = r - rc
        var changed = false
        // Nothing can go lower than the move's lowest tool tip: cells already there are skipped
        // without the distance maths (most of them, once a surface has been cut).
        let floorZ = Float(max(min(a.z, b.z), bottom))
        for row in r0...r1 {
            let y = origin.y + Double(row) * cell
            // Only the stretch of the row the tool sweeps: the part of the segment within r of
            // this row (in Y), widened by r. The whole box for a long diagonal move is mostly air.
            var lo = c0, hi = c1
            if abs(d.y) > 1e-9 {
                let ta = min(max((y - r - a.y) / d.y, 0), 1), tb = min(max((y + r - a.y) / d.y, 0), 1)
                let xa = a.x + d.x * ta, xb = a.x + d.x * tb
                lo = max(c0, Int(((min(xa, xb) - r - origin.x) / cell).rounded(.down)))
                hi = min(c1, Int(((max(xa, xb) + r - origin.x) / cell).rounded(.up)))
                if lo > hi { continue }
            }
            let rowBase = row * cols
            for col in lo...hi {
                if heights[rowBase + col] <= floorZ { continue }
                let x = origin.x + Double(col) * cell
                // Closest point of the segment (in XY) to this cell.
                var t = 0.0
                if len2 > 1e-12 { t = min(max(((x - a.x) * d.x + (y - a.y) * d.y) / len2, 0), 1) }
                let px = a.x + d.x * t, py = a.y + d.y * t
                let dist = ((x - px) * (x - px) + (y - py) * (y - py)).squareRoot()
                guard dist <= r else { continue }
                let zc = a.z + (b.z - a.z) * t
                // Tool bottom profile at this radius: flat core, then the corner radius.
                var z = zc
                if dist > flatR {
                    let u = dist - flatR
                    z += rc - (max(rc * rc - u * u, 0)).squareRoot()
                }
                let i = row * cols + col
                let zf = Float(max(z, bottom))
                if zf < heights[i] {
                    heights[i] = zf
                    changed = true
                }
            }
        }
        if changed {
            if let (a0, b0, a1, b1) = dirty {
                dirty = (min(a0, c0), min(b0, r0), max(a1, c1), max(b1, r1))
            } else {
                dirty = (c0, r0, c1, r1)
            }
        }
    }

    /// Applies one toolpath move (arcs subdivided).
    public mutating func apply(_ m: Move, from start: SIMD3<Double>, radius: Double, cornerRadius: Double) {
        guard m.role != .rapid else { return }
        var p = start
        for q in ToolpathGeometry.points(of: m, from: start, segmentAngle: 0.08) {
            cut(from: p, to: q, radius: radius, cornerRadius: cornerRadius)
            p = q
        }
    }

    /// Marks every cell changed (after restoring a saved state, the mesh redraws all of it).
    public mutating func markAllDirty() { dirty = (0, 0, cols - 1, rows - 1) }

    public mutating func takeDirty() -> (Int, Int, Int, Int)? {
        defer { dirty = nil }
        return dirty
    }

    /// Volume removed so far, mm³.
    public var removedVolume: Double {
        heights.reduce(0) { $0 + (top - Double($1)) } * cell * cell
    }
}
