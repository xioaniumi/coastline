import Foundation
import simd

/// Everything that holds the work (clamps, stops, risers, C-clamps, the table itself) as seen
/// from the spindle: for each cell of the work-frame XY plane, the highest fixture Z (toward the
/// spindle). The tool comes in along −Z, so the tool at (x, y) with its tip at z only touches a
/// fixture whose top within the tool's radius is above z: a drop-cutter test against the
/// fixtures instead of the part.
public struct FixtureField: Sendable {
    public let minX: Double, minY: Double
    public let cell: Double
    public let nx: Int, ny: Int
    /// Highest fixture Z per cell (−∞ where there's none), row-major in Y.
    public private(set) var top: [Float]
    private var dilatedCache: [Int: [Float]] = [:]

    /// - Parameters: triangles: fixture triangles in the work frame, three points each;
    ///   region: the XY area to cover (the stock plus the reach of the tool and collet nut).
    public init(triangles: [SIMD3<Double>], regionMin: SIMD2<Double>, regionMax: SIMD2<Double>, cell: Double = 0.25) {
        self.cell = cell
        minX = regionMin.x
        minY = regionMin.y
        nx = max(Int(((regionMax.x - regionMin.x) / cell).rounded(.up)) + 1, 1)
        ny = max(Int(((regionMax.y - regionMin.y) / cell).rounded(.up)) + 1, 1)
        let (nx, ny, x0, y0) = (self.nx, self.ny, regionMin.x, regionMin.y)
        var top = [Float](repeating: -.infinity, count: nx * ny)
        func put(_ x: Double, _ y: Double, _ z: Double) {
            let i = Int(((x - x0) / cell).rounded()), j = Int(((y - y0) / cell).rounded())
            guard i >= 0, j >= 0, i < nx, j < ny else { return }
            top[j * nx + i] = max(top[j * nx + i], Float(z))
        }
        var t = 0
        while t + 2 < triangles.count {
            let a = triangles[t], b = triangles[t + 1], c = triangles[t + 2]
            t += 3
            // Skip triangles wholly outside the region.
            let lo = simd_min(simd_min(a, b), c), hi = simd_max(simd_max(a, b), c)
            if hi.x < regionMin.x - cell || lo.x > regionMax.x + cell || hi.y < regionMin.y - cell || lo.y > regionMax.y + cell { continue }
            // Sample the triangle at under a cell's spacing (covers steep and vertical faces too).
            let longest = max(simd_length(b - a), simd_length(c - a), simd_length(c - b))
            let n = max(Int((longest / (cell * 0.7)).rounded(.up)), 1)
            for u in 0...n {
                for v in 0...(n - u) {
                    let p = a + (b - a) * (Double(u) / Double(n)) + (c - a) * (Double(v) / Double(n))
                    put(p.x, p.y, p.z)
                }
            }
        }
        self.top = top
    }

    public var isEmpty: Bool { !top.contains { $0 > -.infinity } }

    /// Where fixtures rise above work Z `z`, as rectangles on a `block`-mm grid (runs merged
    /// along X per row): keep-out areas for toolpaths that cut deeper than `z`.
    public func keepOut(above z: Double, block: Double = 1.0) -> [(min: SIMD2<Double>, max: SIMD2<Double>)] {
        let k = max(Int((block / cell).rounded()), 1)
        let bx = (nx + k - 1) / k, by = (ny + k - 1) / k
        var out: [(min: SIMD2<Double>, max: SIMD2<Double>)] = []
        for j in 0..<by {
            var runStart: Int?
            for i in 0...bx {
                var hit = false
                if i < bx {
                    blockLoop: for jj in (j * k)..<min((j + 1) * k, ny) {
                        for ii in (i * k)..<min((i + 1) * k, nx) where Double(top[jj * nx + ii]) > z { hit = true; break blockLoop }
                    }
                }
                if hit, runStart == nil { runStart = i }
                if !hit, let r = runStart {
                    out.append((SIMD2(minX + (Double(r * k) - 0.5) * cell, minY + (Double(j * k) - 0.5) * cell),
                                SIMD2(minX + (Double(min(i * k, nx)) - 0.5) * cell, minY + (Double(min((j + 1) * k, ny)) - 0.5) * cell)))
                    runStart = nil
                }
            }
        }
        return out
    }

    /// The highest fixture Z within `radius` of each cell (a disc max filter, row by row).
    /// Exact disc on the cell centres; a query snaps to the nearest centre, which can add up to
    /// half a cell diagonal (callers allow for it).
    mutating func dilated(radius: Double) -> [Float] {
        let k = max(Int((radius / cell).rounded(.down)), 0)
        let key = Int((radius * 1000).rounded())
        if let d = dilatedCache[key] { return d }
        // Row-wise sliding maxima for each half-width the disc needs.
        var rowMax: [Int: [Float]] = [:]
        func rows(_ w: Int) -> [Float] {
            if let r = rowMax[w] { return r }
            var out = [Float](repeating: -.infinity, count: nx * ny)
            for j in 0..<ny {
                let base = j * nx
                for i in 0..<nx {
                    var m: Float = -.infinity
                    for di in max(i - w, 0)...min(i + w, nx - 1) { m = max(m, top[base + di]) }
                    out[base + i] = m
                }
            }
            rowMax[w] = out
            return out
        }
        var out = [Float](repeating: -.infinity, count: nx * ny)
        for dj in -k...k {
            let w = Int((max(radius * radius - Double(dj * dj) * cell * cell, 0)).squareRoot() / cell)
            let r = rows(w)
            for j in max(-dj, 0)..<min(ny, ny - dj) {
                let src = (j + dj) * nx, dst = j * nx
                for i in 0..<nx where r[src + i] > out[dst + i] { out[dst + i] = r[src + i] }
            }
        }
        dilatedCache[key] = out
        return out
    }

    func value(_ d: [Float], x: Double, y: Double) -> Float {
        let i = Int(((x - minX) / cell).rounded()), j = Int(((y - minY) / cell).rounded())
        guard i >= 0, j >= 0, i < nx, j < ny else { return -.infinity }
        return d[j * nx + i]
    }
}

/// Checks a toolpath against the fixtures with the tool's real shape: the cutter, the shank above
/// the flutes, and the ER-11 collet nut at the stick-out. Every move counts, rapids included.
public enum FixtureClearance {
    /// ER-11 collet nut: Ø16 mm, ~18 mm long in front of the spindle.
    public static let nutRadius = 8.0
    public static let nutLength = 18.0

    public struct Hit: Sendable, Equatable, Codable {
        public var moveIndex: Int
        /// Tool tip, work frame.
        public var position: SIMD3<Double>
        /// "cutter", "shank" or "collet nut".
        public var part: String
        /// How far into the fixture (plus the margin), mm.
        public var depth: Double
    }

    /// Tool sections from the tip: (from, to, radius), mm.
    public static func sections(tool: Tool) -> [(z0: Double, z1: Double, r: Double, name: String)] {
        let flutes = min(tool.fluteLength, tool.stickout)
        return [
            (0, flutes, tool.diameter / 2, "cutter"),
            (flutes, tool.stickout, max(tool.shankDiameter, tool.diameter) / 2, "shank"),
            (tool.stickout, tool.stickout + nutLength, nutRadius, "collet nut"),
        ]
    }

    /// Points along a move from `start`, at most `step` apart (arcs followed in the XY plane).
    public static func samples(from start: SIMD3<Double>, _ m: Move, step: Double) -> [SIMD3<Double>] {
        let end = m.position
        if m.motion == .line {
            let n = max(Int((simd_length(end - start) / step).rounded(.up)), 1)
            return (1...n).map { start + (end - start) * (Double($0) / Double(n)) }
        }
        let c = SIMD2(start.x + m.i, start.y + m.j)
        let r = simd_length(SIMD2(start.x, start.y) - c)
        var a0 = atan2(start.y - c.y, start.x - c.x), a1 = atan2(end.y - c.y, end.x - c.x)
        if m.motion == .arcCCW { while a1 <= a0 + 1e-9 { a1 += 2 * .pi } } else { while a1 >= a0 - 1e-9 { a1 -= 2 * .pi } }
        let n = max(Int((abs(a1 - a0) * r / step).rounded(.up)), 1)
        return (1...n).map { k in
            let f = Double(k) / Double(n), a = a0 + (a1 - a0) * f
            return SIMD3(c.x + r * cos(a), c.y + r * sin(a), start.z + (end.z - start.z) * f)
        }
    }

    /// The first hits (at most `limit`, one per move) where the tool comes within `margin` of a
    /// fixture.
    public static func check(_ moves: [Move], tool: Tool, field: inout FixtureField, margin: Double = 0.5,
                             limit: Int = 50) -> [Hit] {
        guard !field.isEmpty, let first = moves.first else { return [] }
        let secs = sections(tool: tool)
        let snap = field.cell * 0.71  // nearest-centre snapping (half a cell diagonal)
        let maps = secs.map { field.dilated(radius: max($0.r + margin - snap, 0)) }
        var hits: [Hit] = []
        var prev = first.position
        for (k, m) in moves.enumerated() {
            let pts = k == 0 ? [m.position] : samples(from: prev, m, step: field.cell)
            prev = m.position
            sampleLoop: for p in pts {
                for (s, map) in zip(secs, maps) {
                    let f = Double(field.value(map, x: p.x, y: p.y))
                    // The section spans z from p.z + z0 upward; it hits if a fixture rises above
                    // its lower end (minus the margin).
                    let intrusion = f - (p.z + s.z0) + margin
                    if f > -.infinity, intrusion > 0 {
                        hits.append(Hit(moveIndex: k, position: p, part: s.name, depth: intrusion))
                        break sampleLoop
                    }
                }
            }
            if hits.count >= limit { break }
        }
        return hits
    }

    /// How far every fixture would have to move back (away from the spindle) for this path to
    /// keep `margin` from all of them: the deepest intrusion anywhere, 0 when it's clear.
    public static func requiredSetback(_ moves: [Move], tool: Tool, field: inout FixtureField, margin: Double = 0.5) -> Double {
        guard !field.isEmpty, let first = moves.first else { return 0 }
        let secs = sections(tool: tool)
        let snap = field.cell * 0.71
        let maps = secs.map { field.dilated(radius: max($0.r + margin - snap, 0)) }
        var worst = 0.0
        var prev = first.position
        for (k, m) in moves.enumerated() {
            let pts = k == 0 ? [m.position] : samples(from: prev, m, step: field.cell)
            prev = m.position
            for p in pts {
                for (s, map) in zip(secs, maps) {
                    let f = Double(field.value(map, x: p.x, y: p.y))
                    if f > -.infinity { worst = max(worst, f - (p.z + s.z0) + margin) }
                }
            }
        }
        return worst
    }

    /// A sentence for the safety report.
    public static func describe(_ hits: [Hit]) -> String? {
        guard let worst = hits.max(by: { $0.depth < $1.depth }) else { return nil }
        let p = worst.position
        return "The \(worst.part) comes within the safety margin of a clamp or stop (\(hits.count == 1 ? "1 place" : "\(hits.count)+ places"), worst \(Length.mm(worst.depth)) mm in, near X\(Length.mm(p.x)) Y\(Length.mm(p.y)) Z\(Length.mm(p.z)))."
    }
}
