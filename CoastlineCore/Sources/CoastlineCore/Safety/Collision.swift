import Foundation
import simd

/// Collision engine for the objects on the bed: fixtures, the stock and the machine, as their
/// real triangle meshes. Each body gets a bounding-volume tree; two bodies are tested node
/// against node and, where boxes overlap, triangle against triangle.
///
/// Touching isn't colliding: the bar lies on the riser, the clamp's pad presses on the bar, the
/// stop stands on the bed. A pair of triangles only counts when each one passes through the
/// other's plane by more than `tolerance` on both sides and their crossing segments overlap,
/// which is what two solids sharing volume always produce (and faces in contact never do).
public enum Collision {
    /// One rigid object: a fixture assembly, the stock, the machine. Bodies with the same
    /// `group` are one assembly (a C-clamp's screw goes through its frame) and aren't tested
    /// against each other.
    public struct Body: Sendable {
        public var name: String
        public var group: String
        public var tree: TriangleTree
        public init(name: String, group: String? = nil, tree: TriangleTree) {
            self.name = name
            self.group = group ?? name
            self.tree = tree
        }
        public init(name: String, group: String? = nil, triangles: [SIMD3<Double>]) {
            self.init(name: name, group: group, tree: TriangleTree(triangles))
        }
        /// An axis-aligned box (riser plate, parallels, the stock).
        public static func box(name: String, group: String? = nil, min lo: SIMD3<Double>, max hi: SIMD3<Double>) -> Body {
            Body(name: name, group: group, triangles: boxTriangles(min: lo, max: hi))
        }
    }

    public struct Contact: Equatable, Sendable {
        public var a: String
        public var b: String
        /// How deep they go into each other (mm, estimated from the crossing triangles).
        public var depth: Double
        /// A point in the overlap (model coordinates), the deepest one found.
        public var point: SIMD3<Double>
    }

    /// Every pair of bodies that share volume, deepest first.
    public static func check(_ bodies: [Body], tolerance: Double = 0.05, skip: (Body, Body) -> Bool = { _, _ in false }) -> [Contact] {
        var out: [Contact] = []
        for i in bodies.indices {
            for j in bodies.indices where j > i {
                let a = bodies[i], b = bodies[j]
                guard a.group != b.group, !skip(a, b), let r = a.tree.intersect(b.tree, tolerance: tolerance) else { continue }
                out.append(Contact(a: a.name, b: b.name, depth: r.depth, point: r.point))
            }
        }
        return out.sorted { $0.depth > $1.depth }
    }

    public static func boxTriangles(min a: SIMD3<Double>, max b: SIMD3<Double>) -> [SIMD3<Double>] {
        let c = (0..<8).map { i in SIMD3(i & 1 == 0 ? a.x : b.x, i & 2 == 0 ? a.y : b.y, i & 4 == 0 ? a.z : b.z) }
        let faces = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
        return faces.flatMap { f in [c[f[0]], c[f[1]], c[f[2]], c[f[0]], c[f[2]], c[f[3]]] }
    }

    /// Two triangles: do they pass through each other (not just touch)? Depth and a point.
    static func triangles(_ a0: SIMD3<Double>, _ a1: SIMD3<Double>, _ a2: SIMD3<Double>,
                          _ b0: SIMD3<Double>, _ b1: SIMD3<Double>, _ b2: SIMD3<Double>, tol: Double) -> (p: SIMD3<Double>, q: SIMD3<Double>)? {
        let nb = simd_cross(b1 - b0, b2 - b0)
        let lb = simd_length(nb)
        guard lb > 1e-12 else { return nil }
        let ub = nb / lb
        let da = SIMD3(simd_dot(a0 - b0, ub), simd_dot(a1 - b0, ub), simd_dot(a2 - b0, ub))
        let penA = min(da.max(), -da.min())
        guard penA > tol else { return nil }
        let na = simd_cross(a1 - a0, a2 - a0)
        let la = simd_length(na)
        guard la > 1e-12 else { return nil }
        let ua = na / la
        let db = SIMD3(simd_dot(b0 - a0, ua), simd_dot(b1 - a0, ua), simd_dot(b2 - a0, ua))
        let penB = min(db.max(), -db.min())
        guard penB > tol else { return nil }
        // Both cross the other's plane: compare their segments on the planes' common line.
        let dir = simd_cross(ua, ub)
        guard simd_length_squared(dir) > 1e-12 else { return nil }
        func crossing(_ p: [SIMD3<Double>], _ d: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>)? {
            var pts: [SIMD3<Double>] = []
            for (i, j) in [(0, 1), (1, 2), (2, 0)] where (d[i] > 0) != (d[j] > 0) {
                pts.append(p[i] + (p[j] - p[i]) * (d[i] / (d[i] - d[j])))
            }
            return pts.count >= 2 ? (pts[0], pts[1]) : nil
        }
        guard let sa = crossing([a0, a1, a2], da), let sb = crossing([b0, b1, b2], db) else { return nil }
        let ta = (simd_dot(sa.0, dir), simd_dot(sa.1, dir)), tb = (simd_dot(sb.0, dir), simd_dot(sb.1, dir))
        let lo = max(min(ta.0, ta.1), min(tb.0, tb.1)), hi = min(max(ta.0, ta.1), max(tb.0, tb.1))
        let scale = simd_length(dir)
        guard (hi - lo) / scale > tol else { return nil }
        // The overlap's ends, on segment A.
        let span = ta.1 - ta.0
        func at(_ x: Double) -> SIMD3<Double> { sa.0 + (sa.1 - sa.0) * (abs(span) > 1e-12 ? (x - ta.0) / span : 0.5) }
        return (at(lo), at(hi))
    }
}

/// A bounding-volume tree over triangles (model coordinates), for collision queries.
public final class TriangleTree: @unchecked Sendable {
    struct Node {
        var lo: SIMD3<Double>
        var hi: SIMD3<Double>
        /// Leaf: first triangle and count; inner: children at `left` and `left + 1`.
        var left: Int32
        var start: Int32
        var count: Int32
    }

    /// Triangle corners, three per triangle, reordered by the tree.
    let v: [SIMD3<Double>]
    let nodes: [Node]
    public var triangleCount: Int { v.count / 3 }
    public var bounds: (min: SIMD3<Double>, max: SIMD3<Double>)? { nodes.first.map { ($0.lo, $0.hi) } }

    public init(_ triangles: [SIMD3<Double>]) {
        let n = triangles.count / 3
        var order = Array(0..<n)
        var cen = [SIMD3<Double>](repeating: .zero, count: n)
        var tlo = cen, thi = cen
        for t in 0..<n {
            let a = triangles[3 * t], b = triangles[3 * t + 1], c = triangles[3 * t + 2]
            cen[t] = (a + b + c) / 3
            tlo[t] = simd_min(a, simd_min(b, c))
            thi[t] = simd_max(a, simd_max(b, c))
        }
        var nodes: [Node] = []
        nodes.reserveCapacity(max(n / 2, 1))
        func bounds(_ s: Int, _ e: Int) -> Node {
            var lo = SIMD3<Double>(repeating: .infinity), hi = -lo
            for k in s..<e { lo = simd_min(lo, tlo[order[k]]); hi = simd_max(hi, thi[order[k]]) }
            return Node(lo: lo, hi: hi, left: -1, start: Int32(s), count: Int32(e - s))
        }
        // Children are made in pairs, so a node's children always sit at `left` and `left + 1`.
        func split(_ idx: Int) {
            let s = Int(nodes[idx].start), e = s + Int(nodes[idx].count)
            guard e - s > 6 else { return }
            var clo = SIMD3<Double>(repeating: .infinity), chi = -clo
            for k in s..<e { clo = simd_min(clo, cen[order[k]]); chi = simd_max(chi, cen[order[k]]) }
            let ext = chi - clo
            let axis = ext.x >= ext.y && ext.x >= ext.z ? 0 : ext.y >= ext.z ? 1 : 2
            order[s..<e].sort { cen[$0][axis] < cen[$1][axis] }
            let mid = (s + e) / 2
            let l = nodes.count
            nodes.append(bounds(s, mid))
            nodes.append(bounds(mid, e))
            nodes[idx].left = Int32(l)
            split(l)
            split(l + 1)
        }
        if n > 0 {
            nodes.append(bounds(0, n))
            split(0)
        }
        self.nodes = nodes
        var vv = [SIMD3<Double>]()
        vv.reserveCapacity(triangles.count)
        for t in order { vv += [triangles[3 * t], triangles[3 * t + 1], triangles[3 * t + 2]] }
        self.v = vv
    }

    /// Whether the two meshes pass through each other, and if so how deep: the larger of how
    /// far one's corners sit inside the other, and the smallest extent of the curve where
    /// their surfaces cross (a bar through a plate has no corner inside, but its curve is as
    /// thick as the bar). The point is the middle of that curve.
    public func intersect(_ other: TriangleTree, tolerance: Double) -> (depth: Double, point: SIMD3<Double>)? {
        guard let a = nodes.first, let b = other.nodes.first, overlap(a, b, tolerance) else { return nil }
        var segs: [(SIMD3<Double>, SIMD3<Double>)] = []
        var hits = 0
        var stack: [(Int, Int)] = [(0, 0)]
        while let (i, j) = stack.popLast() {
            let na = nodes[i], nb = other.nodes[j]
            guard overlap(na, nb, tolerance) else { continue }
            if na.left < 0 && nb.left < 0 {
                for ta in Int(na.start)..<Int(na.start + na.count) {
                    let a0 = v[3 * ta], a1 = v[3 * ta + 1], a2 = v[3 * ta + 2]
                    for tb in Int(nb.start)..<Int(nb.start + nb.count) {
                        if let seg = Collision.triangles(a0, a1, a2, other.v[3 * tb], other.v[3 * tb + 1], other.v[3 * tb + 2], tol: tolerance) {
                            segs.append((seg.p, seg.q))
                            hits += 1
                        }
                    }
                }
                if hits > 20000 { break }
            } else if nb.left < 0 || (na.left >= 0 && volume(na) >= volume(nb)) {
                stack.append((Int(na.left), j))
                stack.append((Int(na.left) + 1, j))
            } else {
                stack.append((i, Int(nb.left)))
                stack.append((i, Int(nb.left) + 1))
            }
        }
        guard hits > 0 else { return nil }
        let box = (simd_max(a.lo, b.lo), simd_min(a.hi, b.hi))
        let inA = insideDepth(of: other, within: box), inB = other.insideDepth(of: self, within: box)
        let inside = inA.depth >= inB.depth ? inA : inB
        // Separate contact regions (a stop's two keys in two slots) are measured on their own:
        // segments that touch (within 1 mm) belong together. A region's smallest extent is how
        // deep it goes (an arm into a bed's edge); a flat loop with no corner inside either body
        // is something passing right through, as thick as the loop is narrow.
        var best = (depth: 0.0, point: segs[0].0)
        for c in Self.clusters(segs, link: 1.0) {
            var lo = SIMD3<Double>(repeating: .infinity), hi = -lo
            for k in c { lo = simd_min(lo, simd_min(segs[k].0, segs[k].1)); hi = simd_max(hi, simd_max(segs[k].0, segs[k].1)) }
            let e = [hi.x - lo.x, hi.y - lo.y, hi.z - lo.z].sorted()
            let d = e[0] < 0.05 && inside.depth == 0 ? e[1] : e[0]
            if d >= best.depth { best = (d, (lo + hi) / 2) }
        }
        if inside.depth > best.depth { best = inside }
        return best.depth > tolerance ? best : nil
    }

    /// Groups segments whose ends come within `link` of each other (hash grid + flood fill).
    static func clusters(_ segs: [(SIMD3<Double>, SIMD3<Double>)], link: Double) -> [[Int]] {
        struct Cell: Hashable { var x, y, z: Int }
        func cell(_ p: SIMD3<Double>) -> Cell { Cell(x: Int((p.x / link).rounded(.down)), y: Int((p.y / link).rounded(.down)), z: Int((p.z / link).rounded(.down))) }
        var grid: [Cell: [Int]] = [:]
        for (k, s) in segs.enumerated() {
            // Long segments: register along their length too.
            let n = max(Int(simd_length(s.1 - s.0) / link), 1)
            for i in 0...n { grid[cell(s.0 + (s.1 - s.0) * (Double(i) / Double(n))), default: []].append(k) }
        }
        var label = [Int](repeating: -1, count: segs.count)
        var out: [[Int]] = []
        for start in segs.indices where label[start] < 0 {
            var group = [start]
            label[start] = out.count
            var i = 0
            while i < group.count {
                let s = segs[group[i]]
                i += 1
                let n = max(Int(simd_length(s.1 - s.0) / link), 1)
                var seen = Set<Cell>()
                for j in 0...n {
                    let c = cell(s.0 + (s.1 - s.0) * (Double(j) / Double(n)))
                    for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                        let cc = Cell(x: c.x + dx, y: c.y + dy, z: c.z + dz)
                        guard seen.insert(cc).inserted, let ks = grid[cc] else { continue }
                        for k in ks where label[k] < 0 { label[k] = out.count; group.append(k) }
                    } } }
                }
            }
            out.append(group)
        }
        return out
    }

    /// How far `other`'s corners (those in `box`) are inside this mesh, at most.
    func insideDepth(of other: TriangleTree, within box: (SIMD3<Double>, SIMD3<Double>)) -> (depth: Double, point: SIMD3<Double>) {
        var best = (depth: 0.0, point: SIMD3<Double>.zero)
        var seen = 0
        for p in other.v where all(p .>= box.0) && all(p .<= box.1) {
            seen += 1
            if seen > 3000 { break }  // a large overlap is plenty deep already
            if contains(p) {
                let d = distance(to: p, below: .infinity)
                if d > best.depth { best = (d, p) }
            }
        }
        return best
    }

    /// The nearest hit along a ray (distance), if any.
    public func raycast(_ p: SIMD3<Double>, _ dir: SIMD3<Double>) -> Double? {
        let d = simd_normalize(dir)
        var best = Double.infinity
        var stack = nodes.isEmpty ? [] : [0]
        while let i = stack.popLast() {
            let n = nodes[i]
            var t0 = 0.0, t1 = best
            for k in 0..<3 {
                if abs(d[k]) < 1e-15 {
                    if p[k] < n.lo[k] || p[k] > n.hi[k] { t0 = 1; t1 = 0 }
                    continue
                }
                let inv = 1 / d[k]
                var a = (n.lo[k] - p[k]) * inv, b = (n.hi[k] - p[k]) * inv
                if a > b { swap(&a, &b) }
                t0 = max(t0, a); t1 = min(t1, b)
            }
            guard t0 <= t1 else { continue }
            if n.left >= 0 { stack.append(Int(n.left)); stack.append(Int(n.left) + 1); continue }
            for t in Int(n.start)..<Int(n.start + n.count) {
                let a = v[3 * t], e1 = v[3 * t + 1] - a, e2 = v[3 * t + 2] - a
                let h = simd_cross(d, e2), det = simd_dot(e1, h)
                guard abs(det) > 1e-14 else { continue }
                let f = 1 / det, sv = p - a, u = f * simd_dot(sv, h)
                guard u >= 0, u <= 1 else { continue }
                let q = simd_cross(sv, e1), w = f * simd_dot(d, q)
                guard w >= 0, u + w <= 1 else { continue }
                let t = f * simd_dot(e2, q)
                if t > 1e-9 && t < best { best = t }
            }
        }
        return best.isFinite ? best : nil
    }

    /// Inside the (closed) mesh? Counts crossings of a ray in an odd direction.
    public func contains(_ p: SIMD3<Double>) -> Bool {
        guard let root = nodes.first, all(p .> root.lo), all(p .< root.hi) else { return false }
        let d = simd_normalize(SIMD3(0.5773, 0.5774, 0.5775) + SIMD3(0.013, -0.007, 0.003))
        var crossings = 0
        var stack = [0]
        while let i = stack.popLast() {
            let n = nodes[i]
            // Ray–box slab test.
            var t0 = 0.0, t1 = Double.infinity
            for k in 0..<3 {
                let inv = 1 / d[k]
                var a = (n.lo[k] - p[k]) * inv, b = (n.hi[k] - p[k]) * inv
                if a > b { swap(&a, &b) }
                t0 = max(t0, a); t1 = min(t1, b)
            }
            guard t0 <= t1 else { continue }
            if n.left >= 0 {
                stack.append(Int(n.left)); stack.append(Int(n.left) + 1)
                continue
            }
            for t in Int(n.start)..<Int(n.start + n.count) {
                // Möller–Trumbore.
                let a = v[3 * t], e1 = v[3 * t + 1] - a, e2 = v[3 * t + 2] - a
                let h = simd_cross(d, e2), det = simd_dot(e1, h)
                guard abs(det) > 1e-14 else { continue }
                let f = 1 / det, sv = p - a, u = f * simd_dot(sv, h)
                guard u >= 0, u <= 1 else { continue }
                let q = simd_cross(sv, e1), w = f * simd_dot(d, q)
                guard w >= 0, u + w <= 1 else { continue }
                if f * simd_dot(e2, q) > 1e-9 { crossings += 1 }
            }
        }
        return crossings % 2 == 1
    }

    /// Distance from `p` to the nearest triangle.
    public func distance(to p: SIMD3<Double>, below limit: Double) -> Double {
        var best = limit
        var stack = [0]
        while let i = stack.popLast() {
            let n = nodes[i]
            let gap = simd_max(simd_max(n.lo - p, p - n.hi), .zero)
            guard simd_length(gap) < best else { continue }
            if n.left >= 0 {
                stack.append(Int(n.left)); stack.append(Int(n.left) + 1)
                continue
            }
            for t in Int(n.start)..<Int(n.start + n.count) {
                best = min(best, Self.pointTriangle(p, v[3 * t], v[3 * t + 1], v[3 * t + 2]))
            }
        }
        return best
    }

    /// Point–triangle distance (Ericson, Real-Time Collision Detection 5.1.5).
    static func pointTriangle(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> Double {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return simd_length(ap) }
        let bp = p - b, d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return simd_length(bp) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return simd_length(p - (a + ab * (d1 / (d1 - d3)))) }
        let cp = p - c, d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return simd_length(cp) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return simd_length(p - (a + ac * (d2 / (d2 - d6)))) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            return simd_length(p - (b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))))
        }
        let den = 1 / (va + vb + vc)
        return simd_length(p - (a + ab * (vb * den) + ac * (vc * den)))
    }

    /// Whether this mesh and `other` moved by `offset` pass through each other (beyond
    /// `tolerance`): a moving part (the spindle head) against fixed ones, without building a
    /// tree per position.
    public func touches(_ other: TriangleTree, offset: SIMD3<Double>, tolerance: Double = 0.05) -> Bool {
        guard !nodes.isEmpty, !other.nodes.isEmpty else { return false }
        func moved(_ n: Node) -> Node { var m = n; m.lo += offset; m.hi += offset; return m }
        var stack: [(Int, Int)] = [(0, 0)]
        while let (i, j) = stack.popLast() {
            let na = nodes[i], nb = moved(other.nodes[j])
            guard overlap(na, nb, tolerance) else { continue }
            if na.left < 0 && nb.left < 0 {
                for ta in Int(na.start)..<Int(na.start + na.count) {
                    let a0 = v[3 * ta], a1 = v[3 * ta + 1], a2 = v[3 * ta + 2]
                    for tb in Int(nb.start)..<Int(nb.start + nb.count) {
                        if Collision.triangles(a0, a1, a2, other.v[3 * tb] + offset, other.v[3 * tb + 1] + offset, other.v[3 * tb + 2] + offset,
                                               tol: tolerance) != nil { return true }
                    }
                }
            } else if nb.left < 0 || (na.left >= 0 && volume(na) >= volume(nb)) {
                stack.append((Int(na.left), j))
                stack.append((Int(na.left) + 1, j))
            } else {
                stack.append((i, Int(nb.left)))
                stack.append((i, Int(nb.left) + 1))
            }
        }
        return false
    }

    private func overlap(_ a: Node, _ b: Node, _ tol: Double) -> Bool {
        all(a.lo .<= b.hi - tol) && all(b.lo .<= a.hi - tol)
    }

    private func volume(_ n: Node) -> Double {
        let e = n.hi - n.lo
        return e.x * e.y * e.z
    }
}
