import CoastlineCore
import Foundation
import simd
import Viewport

/// The simulated stock is a grid of heights (the top) and, on two-sided jobs, a second grid
/// (the back). Where both sides cut through, the grid's triangles are dropped; these build what
/// closes the solid around those holes, and find the pieces that came loose.
enum SimSurfaces {
    /// Walls along the edge of every hole cut through: from the back (or the bottom) up to the
    /// top, facing into the hole. Positions and normals, flat arrays, grid coordinates.
    static func walls(cols: Int, rows: Int, x0: Float, y0: Float, cell: Float,
                      top h: [Float], back: [Float]?, bottom: Float, open: (Int) -> Bool) -> (p: [Float], n: [Float]) {
        let qc = cols - 1, qr = rows - 1
        guard qc > 0, qr > 0 else { return ([], []) }
        var mat = [Bool](repeating: true, count: cols * rows)
        var anyOpen = false
        for i in mat.indices where open(i) { mat[i] = false; anyOpen = true }
        guard anyOpen else { return ([], []) }
        // Each grid quad (r, c) is two triangles: T1 = (a, b, e), T2 = (a, e, d), with
        // a = (r, c), b = (r, c+1), d = (r+1, c), e = (r+1, c+1). A triangle draws only if
        // all three corners have material.
        var t1 = [Bool](repeating: false, count: qc * qr), t2 = t1
        for r in 0..<qr {
            for c in 0..<qc {
                let a = r * cols + c, b = a + 1, d = a + cols, e = d + 1
                t1[r * qc + c] = mat[a] && mat[b] && mat[e]
                t2[r * qc + c] = mat[a] && mat[e] && mat[d]
            }
        }
        var p: [Float] = [], n: [Float] = []
        func xy(_ i: Int) -> SIMD2<Float> { SIMD2(x0 + Float(i % cols) * cell, y0 + Float(i / cols) * cell) }
        func wall(_ i: Int, _ j: Int, away k: Int) {
            let pi = xy(i), pj = xy(j), pk = xy(k)
            let along = pj - pi
            var out = simd_normalize(SIMD2(along.y, -along.x))
            if simd_dot(out, pk - pi) > 0 { out = -out }  // away from the drawn triangle
            let bi = back?[i] ?? bottom, bj = back?[j] ?? bottom
            var q: [SIMD3<Float>] = [SIMD3(pi, h[i]), SIMD3(pj, h[j]), SIMD3(pj, bj), SIMD3(pi, bi)]
            // Counter-clockwise seen from the hole (the shader turns back faces' normals around).
            if simd_dot(simd_cross(q[1] - q[0], q[2] - q[0]), SIMD3(out, 0)) < 0 { q.reverse() }
            for v in [q[0], q[1], q[2], q[0], q[2], q[3]] {
                p += [v.x, v.y, v.z]
                n += [out.x, out.y, 0]
            }
        }
        for r in 0..<qr {
            for c in 0..<qc {
                let q = r * qc + c
                let a = r * cols + c, b = a + 1, d = a + cols, e = d + 1
                if t1[q] {
                    if r > 0, !t2[(r - 1) * qc + c] { wall(a, b, away: e) }
                    if c + 1 < qc, !t2[r * qc + c + 1] { wall(b, e, away: a) }
                    if !t2[q] { wall(a, e, away: b) }
                }
                if t2[q] {
                    if r + 1 < qr, !t1[(r + 1) * qc + c] { wall(e, d, away: a) }
                    if c > 0, !t1[r * qc + c - 1] { wall(d, a, away: e) }
                    if !t1[q] { wall(a, e, away: d) }
                }
            }
        }
        return (p, n)
    }

    /// Material that hangs together with nothing holding it: grid points with material, in
    /// pieces (4-connected) none of which touches `held` (where the clamps grip). Without any
    /// held point the biggest piece counts as held. Returns a mask and how many pieces.
    static func loose(cols: Int, rows: Int, top h: [Float], back: [Float]?, bottom: Float,
                      open: (Int) -> Bool, held: (Int) -> Bool) -> (mask: [Bool], pieces: Int) {
        let count = cols * rows
        var solid = [Bool](repeating: false, count: count)
        for i in 0..<count where !open(i) && h[i] - (back?[i] ?? bottom) > 0.02 { solid[i] = true }
        var label = [Int32](repeating: -1, count: count)
        var sizes: [Int] = [], anchored: [Bool] = []
        var stack: [Int] = []
        for s in 0..<count where solid[s] && label[s] < 0 {
            let id = Int32(sizes.count)
            var size = 0, holds = false
            label[s] = id
            stack.append(s)
            while let i = stack.popLast() {
                size += 1
                if !holds && held(i) { holds = true }
                let r = i / cols, c = i % cols
                if c > 0, solid[i - 1], label[i - 1] < 0 { label[i - 1] = id; stack.append(i - 1) }
                if c + 1 < cols, solid[i + 1], label[i + 1] < 0 { label[i + 1] = id; stack.append(i + 1) }
                if r > 0, solid[i - cols], label[i - cols] < 0 { label[i - cols] = id; stack.append(i - cols) }
                if r + 1 < rows, solid[i + cols], label[i + cols] < 0 { label[i + cols] = id; stack.append(i + cols) }
            }
            sizes.append(size)
            anchored.append(holds)
        }
        if !anchored.contains(true), let big = sizes.indices.max(by: { sizes[$0] < sizes[$1] }) { anchored[big] = true }
        // Specks of a few cells are rounding at the grid's resolution, not pieces.
        let real = sizes.indices.filter { !anchored[$0] && sizes[$0] >= 6 }
        let realSet = Set(real.map(Int32.init))
        var mask = [Bool](repeating: false, count: count)
        if !realSet.isEmpty { for i in 0..<count where label[i] >= 0 && realSet.contains(label[i]) { mask[i] = true } }
        return (mask, real.count)
    }

    /// Quads just above the top surface over loose material (every grid quad whose corners are
    /// all loose), to colour it.
    static func overlay(cols: Int, rows: Int, x0: Float, y0: Float, cell: Float, top h: [Float], mask: [Bool]) -> (p: [Float], n: [Float]) {
        var p: [Float] = [], n: [Float] = []
        for r in 0..<(rows - 1) {
            for c in 0..<(cols - 1) {
                let a = r * cols + c, b = a + 1, d = a + cols, e = d + 1
                guard mask[a], mask[b], mask[d], mask[e] else { continue }
                func v(_ i: Int) -> SIMD3<Float> { SIMD3(x0 + Float(i % cols) * cell, y0 + Float(i / cols) * cell, h[i] + 0.03) }
                for q in [v(a), v(b), v(e), v(a), v(e), v(d)] {
                    p += [q.x, q.y, q.z]
                    n += [0, 0, 1]
                }
            }
        }
        return (p, n)
    }
}
