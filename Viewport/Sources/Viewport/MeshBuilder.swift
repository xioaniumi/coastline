import Metal
import simd

/// Small procedural meshes: tool assemblies (cutter, shank, collet nut) and grids.
public struct MeshBuilder {
    public var positions: [Float] = []
    public var normals: [Float] = []
    public var indices: [UInt32] = []

    public init() {}

    private mutating func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> UInt32 {
        positions += [p.x, p.y, p.z]
        normals += [n.x, n.y, n.z]
        return UInt32(positions.count / 3 - 1)
    }

    /// A cylinder along +Z from z0 to z1 (open ends unless `caps`).
    public mutating func cylinder(radius r: Float, z0: Float, z1: Float, segments: Int = 32, caps: Bool = true) {
        let base = UInt32(positions.count / 3)
        for i in 0...segments {
            let a = Float(i) / Float(segments) * 2 * .pi
            let n = SIMD3(cos(a), sin(a), 0)
            _ = vertex(SIMD3(r * n.x, r * n.y, z0), n)
            _ = vertex(SIMD3(r * n.x, r * n.y, z1), n)
        }
        for i in 0..<UInt32(segments) {
            let a = base + i * 2
            indices += [a, a + 2, a + 1, a + 1, a + 2, a + 3]
        }
        if caps {
            disc(radius: r, z: z0, normal: -1, segments: segments)
            disc(radius: r, z: z1, normal: 1, segments: segments)
        }
    }

    public mutating func disc(radius r: Float, z: Float, normal s: Float, segments: Int = 32) {
        let c = vertex(SIMD3(0, 0, z), SIMD3(0, 0, s))
        var ring: [UInt32] = []
        for i in 0...segments {
            let a = Float(i) / Float(segments) * 2 * .pi
            ring.append(vertex(SIMD3(r * cos(a), r * sin(a), z), SIMD3(0, 0, s)))
        }
        for i in 0..<segments {
            indices += s > 0 ? [c, ring[i], ring[i + 1]] : [c, ring[i + 1], ring[i]]
        }
    }

    /// A hemisphere (ball end) of radius r with its lowest point at z = tip.
    public mutating func ballEnd(radius r: Float, tip: Float, segments: Int = 24) {
        let rings = segments / 2
        let base = UInt32(positions.count / 3)
        for j in 0...rings {
            let phi = Float(j) / Float(rings) * (.pi / 2)  // 0 = tip, π/2 = equator
            for i in 0...segments {
                let a = Float(i) / Float(segments) * 2 * .pi
                let n = SIMD3(sin(phi) * cos(a), sin(phi) * sin(a), -cos(phi))
                _ = vertex(SIMD3(0, 0, tip + r) + n * r, n)
            }
        }
        let w = UInt32(segments + 1)
        for j in 0..<UInt32(rings) {
            for i in 0..<UInt32(segments) {
                let a = base + j * w + i
                indices += [a, a + 1, a + w, a + 1, a + w + 1, a + w]
            }
        }
    }

    /// A cone frustum along +Z (chamfer mills, drill points).
    public mutating func cone(r0: Float, z0: Float, r1: Float, z1: Float, segments: Int = 32) {
        let base = UInt32(positions.count / 3)
        let slope = (r0 - r1) / max(z1 - z0, 1e-4)
        for i in 0...segments {
            let a = Float(i) / Float(segments) * 2 * .pi
            let n = simd_normalize(SIMD3(cos(a), sin(a), slope))
            _ = vertex(SIMD3(r0 * cos(a), r0 * sin(a), z0), n)
            _ = vertex(SIMD3(r1 * cos(a), r1 * sin(a), z1), n)
        }
        for i in 0..<UInt32(segments) {
            let a = base + i * 2
            indices += [a, a + 2, a + 1, a + 1, a + 2, a + 3]
        }
    }

    public func mesh(device: MTLDevice, id: String, color: SIMD4<Float>) -> SceneMesh? {
        SceneMesh(device: device, id: id, positions: positions, normals: normals, indices: indices, color: color)
    }
}

extension SceneMesh {
    /// Rewrites vertices in place (interleaved position + normal, 6 floats each). The buffer is
    /// shared memory on Apple Silicon, so the next frame sees the change.
    public func updateVertices(_ body: (UnsafeMutableBufferPointer<Float>) -> Void) {
        let n = vertexBuffer.length / MemoryLayout<Float>.stride
        let p = vertexBuffer.contents().bindMemory(to: Float.self, capacity: n)
        body(UnsafeMutableBufferPointer(start: p, count: n))
        contentVersion &+= 1  // the viewport redraws only when something changed
    }

    /// A regular grid of cols × rows vertices over [x0, x0 + (cols-1)·cell] × [y0, …] at height z.
    /// Writes a height grid into a mesh made by `grid(...)`: the z and normal of every vertex
    /// in rows r0…r1, columns c0…c1 (plus one of margin), and the skirt walls (from `back`, or
    /// `floor`, up to the surface). Cells where `top` is at or below `back` have no material:
    /// their normal is zero, which the shader drops. `values` is the surface drawn (`top`, or
    /// `back` for the downward-facing back surface, `downward`). Here, in the optimised package,
    /// because the app's own code isn't optimised and this runs for every scrub.
    public func updateGrid(values: [Float], top: [Float], back: [Float]?, cols: Int, rows: Int, cell: Float,
                           c0: Int, r0: Int, c1: Int, r1: Int, downward: Bool, floor: Float) {
        let skirt = downward ? [] : self.skirt
        func write(_ v: UnsafeMutableBufferPointer<Float>, _ s: UnsafeBufferPointer<Float>, _ h: UnsafeBufferPointer<Float>,
                   _ b: UnsafeBufferPointer<Float>?) {
            func open(_ i: Int) -> Bool { b.map { h[i] <= $0[i] + 0.005 } ?? false }
            let sign: Float = downward ? -1 : 1
            for r in max(r0 - 1, 0)...min(r1 + 1, rows - 1) {
                let rd = max(r - 1, 0) * cols, ru = min(r + 1, rows - 1) * cols, rc = r * cols
                for c in max(c0 - 1, 0)...min(c1 + 1, cols - 1) {
                    let i = rc + c, o = i * 6
                    v[o + 2] = s[i]
                    if open(i) {
                        v[o + 3] = 0; v[o + 4] = 0; v[o + 5] = 0
                    } else {
                        let n = sign * simd_normalize(SIMD3<Float>(s[rc + max(c - 1, 0)] - s[rc + min(c + 1, cols - 1)],
                                                                   s[rd + c] - s[ru + c], 2 * cell))
                        v[o + 3] = n.x; v[o + 4] = n.y; v[o + 5] = n.z
                    }
                }
            }
            // The outer walls: from the back (or the floor) up to the surface; where both sides
            // cut through there's no wall (it would stand as a thin sliver).
            for (g, w) in skirt {
                let gi = Int(g), tz = Int(w) * 6 + 2, bz = (Int(w) + 1) * 6 + 2
                let lo = b?[gi] ?? floor
                v[tz] = open(gi) ? lo : h[gi]
                v[bz] = lo
            }
        }
        updateVertices { v in
            values.withUnsafeBufferPointer { s in
                top.withUnsafeBufferPointer { h in
                    if let back {
                        back.withUnsafeBufferPointer { b in write(v, s, h, b) }
                    } else {
                        write(v, s, h, nil)
                    }
                }
            }
        }
    }

    public static func grid(device: MTLDevice, id: String, x0: Float, y0: Float, cell: Float, cols: Int, rows: Int,
                            z: Float, color: SIMD4<Float>, transform: simd_float4x4 = matrix_identity_float4x4,
                            bottom: Float? = nil, bottomFace: Bool = true, facingDown: Bool = false) -> SceneMesh? {
        var p = [Float](repeating: 0, count: cols * rows * 3)
        var n = [Float](repeating: 0, count: cols * rows * 3)
        for r in 0..<rows {
            for c in 0..<cols {
                let i = (r * cols + c) * 3
                p[i] = x0 + Float(c) * cell
                p[i + 1] = y0 + Float(r) * cell
                p[i + 2] = z
                n[i + 2] = 1
            }
        }
        var t: [UInt32] = []
        t.reserveCapacity((cols - 1) * (rows - 1) * 6)
        for r in 0..<(rows - 1) {
            for c in 0..<(cols - 1) {
                let a = UInt32(r * cols + c), b = a + 1, d = a + UInt32(cols), e = d + 1
                // Counter-clockwise seen from the side it faces: the shader turns normals of
                // back-facing triangles around, so a surface that faces down (the back of a
                // two-sided simulation) is wound the other way.
                t += facingDown ? [a, e, b, a, d, e] : [a, b, e, a, e, d]
            }
        }
        // Closed solid: walls from the surface's edge down to the bottom, and the bottom face, so
        // the simulated stock reads as a block of material, not a sheet.
        var skirt: [(grid: Int32, vertex: Int32)] = []
        if let zb = bottom {
            func vertex(_ x: Float, _ y: Float, _ z: Float, _ nx: Float, _ ny: Float, _ nz: Float) -> UInt32 {
                p += [x, y, z]
                n += [nx, ny, nz]
                return UInt32(p.count / 3 - 1)
            }
            // side: grid indices along the edge, outward normal, and whether the walk runs
            // clockwise seen from outside (then the quads are wound the other way).
            let sides: [([Int], SIMD2<Float>, Bool)] = [
                ((0..<cols).map { $0 }, SIMD2(0, -1), false),
                ((0..<cols).map { (rows - 1) * cols + $0 }, SIMD2(0, 1), true),
                ((0..<rows).map { $0 * cols }, SIMD2(-1, 0), true),
                ((0..<rows).map { $0 * cols + cols - 1 }, SIMD2(1, 0), false),
            ]
            for (edge, nrm, flip) in sides {
                var tops: [UInt32] = [], bots: [UInt32] = []
                for g in edge {
                    let x = p[g * 3], y = p[g * 3 + 1]
                    let top = vertex(x, y, z, nrm.x, nrm.y, 0)
                    skirt.append((Int32(g), Int32(top)))
                    tops.append(top)
                    bots.append(vertex(x, y, zb, nrm.x, nrm.y, 0))
                }
                for k in 0..<(edge.count - 1) {
                    let (b0, b1, t0, t1) = (bots[k], bots[k + 1], tops[k], tops[k + 1])
                    t += flip ? [b1, b0, t0, b1, t0, t1] : [b0, b1, t1, b0, t1, t0]
                }
            }
            if bottomFace {  // (a two-sided simulation draws its own back surface instead)
                let xa = x0, xb = x0 + Float(cols - 1) * cell, ya = y0, yb = y0 + Float(rows - 1) * cell
                let q0 = vertex(xa, ya, zb, 0, 0, -1), q1 = vertex(xb, ya, zb, 0, 0, -1)
                let q2 = vertex(xb, yb, zb, 0, 0, -1), q3 = vertex(xa, yb, zb, 0, 0, -1)
                t += [q0, q2, q1, q0, q3, q2]
            }
        }
        let mesh = SceneMesh(device: device, id: id, positions: p, normals: n, indices: t, color: color, transform: transform)
        mesh?.skirt = skirt
        return mesh
    }
}

extension SceneLines {
    /// Sets how many segments draw (playback cursor).
    public func show(upTo count: Int) { visibleCount = min(max(count, 0), self.count) }
}
