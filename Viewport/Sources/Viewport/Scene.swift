import Metal
import simd

/// One toolpath segment as the GPU sees it (layout matches `LineSegment` in Shaders.swift).
/// A colour alpha below 255 marks the segment as dashed (rapids).
public struct LineSegment: Sendable {
    public var a: (Float, Float, Float)
    public var b: (Float, Float, Float)
    public var colorA: SIMD4<UInt8>
    public var colorB: SIMD4<UInt8>

    public init(_ a: SIMD3<Float>, _ b: SIMD3<Float>, color: SIMD4<UInt8>, colorB: SIMD4<UInt8>? = nil) {
        self.a = (a.x, a.y, a.z)
        self.b = (b.x, b.y, b.z)
        self.colorA = color
        self.colorB = colorB ?? color
    }
}

/// Colours for toolpath move types (sRGB 0–255). Rapids carry alpha 254 = dashed.
public enum PathColor {
    public static let rapid = SIMD4<UInt8>(235, 64, 52, 254)
    public static let cut = SIMD4<UInt8>(46, 160, 255, 255)
    public static let lead = SIMD4<UInt8>(255, 196, 0, 255)
    public static let plunge = SIMD4<UInt8>(255, 120, 200, 255)
    public static let envelope = SIMD4<UInt8>(150, 150, 160, 255)
    public static let axisX = SIMD4<UInt8>(230, 70, 70, 255)
    public static let axisY = SIMD4<UInt8>(80, 200, 90, 255)
    public static let axisZ = SIMD4<UInt8>(70, 120, 240, 255)
}

/// A triangle mesh in the scene (part, stock, fixture, machine).
public final class SceneMesh: Identifiable {
    public let id: String
    public var color: SIMD4<Float>
    /// Surface for realistic shading (the flat view uses `color` only).
    public var material = SurfaceMaterial()
    /// Height-field solids: wall vertices that follow grid vertices' heights (grid, wall).
    public var skirt: [(grid: Int32, vertex: Int32)] = []
    public var transform: simd_float4x4
    public var isVisible = true
    /// Wins (> 0) or loses (< 0) against a face it touches: −1 for fixtures and the machine, +1
    /// for the part.
    public var depthBias: Float = 0
    /// Drawn last, over everything (manipulator handles).
    public var onTop = false
    /// Flat colour, no lighting (manipulator handles, overlays).
    public var unlit = false
    /// Motion group: the scene's transform for this group is applied on top (e.g. "x" = the table).
    public var group: String?
    /// X-ray toolpaths show through this mesh (the stock), not through others (clamps, machine).
    public var xrayThrough = false
    /// Bumped when the vertices are rewritten in place (updateVertices).
    public internal(set) var contentVersion = 0
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    public let boundsMin: SIMD3<Float>
    public let boundsMax: SIMD3<Float>
    /// CPU copies for ray picking (only kept when `pickable`).
    let pickPositions: [SIMD3<Float>]
    let pickIndices: [UInt32]
    public var isPickable: Bool { !pickIndices.isEmpty }
    /// Translucent meshes (alpha < 1) draw after opaque ones without writing depth.
    public var isTranslucent: Bool { color.w < 0.999 }

    /// - Parameters: `positions`/`normals` are xyz-interleaved; `indices` are triangles.
    public init?(device: MTLDevice, id: String, positions: [Float], normals: [Float], indices: [UInt32],
                 color: SIMD4<Float>, transform: simd_float4x4 = matrix_identity_float4x4, pickable: Bool = false) {
        let count = positions.count / 3
        guard count > 0, !indices.isEmpty else { return nil }
        var interleaved = [Float](repeating: 0, count: count * 6)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for i in 0..<count {
            let p = SIMD3(positions[3 * i], positions[3 * i + 1], positions[3 * i + 2])
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
            interleaved[6 * i] = p.x
            interleaved[6 * i + 1] = p.y
            interleaved[6 * i + 2] = p.z
            interleaved[6 * i + 3] = normals[3 * i]
            interleaved[6 * i + 4] = normals[3 * i + 1]
            interleaved[6 * i + 5] = normals[3 * i + 2]
        }
        guard let vb = device.makeBuffer(bytes: interleaved, length: interleaved.count * 4),
              let ib = device.makeBuffer(bytes: indices, length: indices.count * 4) else { return nil }
        self.id = id
        self.color = color
        self.transform = transform
        vertexBuffer = vb
        indexBuffer = ib
        indexCount = indices.count
        boundsMin = lo
        boundsMax = hi
        if pickable {
            pickPositions = (0..<count).map { SIMD3(positions[3 * $0], positions[3 * $0 + 1], positions[3 * $0 + 2]) }
            pickIndices = indices
        } else {
            pickPositions = []
            pickIndices = []
        }
    }

    /// Ray–mesh intersection in world space (Möller–Trumbore, brute force with a bounds test).
    /// Returns the distance along the ray and the hit point in mesh-local coordinates.
    func intersect(origin: SIMD3<Float>, direction: SIMD3<Float>) -> (t: Float, local: SIMD3<Float>)? {
        guard isPickable else { return nil }
        let inv = transform.inverse
        let o4 = inv * SIMD4(origin, 1), d4 = inv * SIMD4(direction, 0)
        let o = SIMD3(o4.x, o4.y, o4.z), d = SIMD3(d4.x, d4.y, d4.z)
        // Slab test against the local bounds first.
        var tmin: Float = 0, tmax = Float.greatestFiniteMagnitude
        for a in 0..<3 {
            if abs(d[a]) < 1e-12 {
                if o[a] < boundsMin[a] || o[a] > boundsMax[a] { return nil }
            } else {
                var t0 = (boundsMin[a] - o[a]) / d[a], t1 = (boundsMax[a] - o[a]) / d[a]
                if t0 > t1 { swap(&t0, &t1) }
                tmin = max(tmin, t0)
                tmax = min(tmax, t1)
                if tmin > tmax { return nil }
            }
        }
        var best: Float = .greatestFiniteMagnitude
        var i = 0
        while i + 2 < pickIndices.count {
            let a = pickPositions[Int(pickIndices[i])], b = pickPositions[Int(pickIndices[i + 1])], c = pickPositions[Int(pickIndices[i + 2])]
            i += 3
            let e1 = b - a, e2 = c - a
            let p = simd_cross(d, e2)
            let det = simd_dot(e1, p)
            if abs(det) < 1e-12 { continue }
            let invDet = 1 / det
            let s = o - a
            let u = simd_dot(s, p) * invDet
            if u < 0 || u > 1 { continue }
            let q = simd_cross(s, e1)
            let v = simd_dot(d, q) * invDet
            if v < 0 || u + v > 1 { continue }
            let t = simd_dot(e2, q) * invDet
            if t > 1e-6 && t < best { best = t }
        }
        guard best < .greatestFiniteMagnitude else { return nil }
        return (best, o + d * best)
    }
}

extension SceneMesh {
    /// An axis-aligned box (flat-shaded: 24 vertices so each face has its own normal).
    public static func box(device: MTLDevice, id: String, min lo: SIMD3<Float>, max hi: SIMD3<Float>,
                           color: SIMD4<Float>, transform: simd_float4x4 = matrix_identity_float4x4) -> SceneMesh? {
        var p: [Float] = [], n: [Float] = [], t: [UInt32] = []
        let faces: [(SIMD3<Float>, [SIMD3<Float>])] = [
            (SIMD3(1, 0, 0), [SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(hi.x, lo.y, hi.z)]),
            (SIMD3(-1, 0, 0), [SIMD3(lo.x, hi.y, lo.z), SIMD3(lo.x, lo.y, lo.z), SIMD3(lo.x, lo.y, hi.z), SIMD3(lo.x, hi.y, hi.z)]),
            (SIMD3(0, 1, 0), [SIMD3(hi.x, hi.y, lo.z), SIMD3(lo.x, hi.y, lo.z), SIMD3(lo.x, hi.y, hi.z), SIMD3(hi.x, hi.y, hi.z)]),
            (SIMD3(0, -1, 0), [SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(lo.x, lo.y, hi.z)]),
            (SIMD3(0, 0, 1), [SIMD3(lo.x, lo.y, hi.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(lo.x, hi.y, hi.z)]),
            (SIMD3(0, 0, -1), [SIMD3(lo.x, hi.y, lo.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(hi.x, lo.y, lo.z), SIMD3(lo.x, lo.y, lo.z)]),
        ]
        for (normal, corners) in faces {
            let base = UInt32(p.count / 3)
            for c in corners { p += [c.x, c.y, c.z]; n += [normal.x, normal.y, normal.z] }
            t += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        return SceneMesh(device: device, id: id, positions: p, normals: n, indices: t, color: color, transform: transform)
    }
}

/// A set of line segments (a toolpath, the envelope box, axes).
public final class SceneLines: Identifiable {
    public let id: String
    public var isVisible = true
    public var group: String?
    /// > 0: also drawn faintly (this opacity) through solid geometry, e.g. toolpaths in the stock.
    public var xray: Float = 0
    /// Playback cursor: only the first `visibleCount` segments draw.
    public var visibleCount: Int
    let buffer: MTLBuffer
    public let count: Int

    public init?(device: MTLDevice, id: String, segments: [LineSegment]) {
        guard !segments.isEmpty,
              let b = device.makeBuffer(bytes: segments, length: segments.count * MemoryLayout<LineSegment>.stride)
        else { return nil }
        self.id = id
        buffer = b
        count = segments.count
        visibleCount = segments.count
    }
}

/// Everything the viewport draws. Mutate on the main thread; the renderer reads it each frame.
@MainActor
public final class ViewportScene {
    public let device: MTLDevice
    public private(set) var meshes: [SceneMesh] = []
    public private(set) var lines: [SceneLines] = []
    /// Section plane (world): normal xyz, offset w. Zero normal = off.
    public var clipPlane = SIMD4<Float>(0, 0, 0, 0)
    /// Live transforms of motion groups (machine axes): meshes and lines with `group` set move
    /// with them.
    public var groupTransforms: [String: simd_float4x4] = [:]

    public func groupTransform(_ g: String?) -> simd_float4x4 {
        g.flatMap { groupTransforms[$0] } ?? matrix_identity_float4x4
    }

    public init(device: MTLDevice) { self.device = device }

    /// Assigns a motion group to new meshes and lines by id (set by the app).
    public var groupForID: (String) -> String? = { _ in nil }

    /// Default depth bias by what a mesh is (see SceneMesh.depthBias).
    public var biasForID: (String) -> Float = { id in
        if id.hasPrefix("fixture.") || id.hasPrefix("machine.") { return -1 }
        if id == "part" || id == "undercuts" || id.hasPrefix("cutface") { return 1 }
        return 0
    }

    public func setMesh(_ mesh: SceneMesh) {
        if mesh.group == nil { mesh.group = groupForID(mesh.id) }
        if mesh.depthBias == 0 { mesh.depthBias = biasForID(mesh.id) }
        meshes.removeAll { $0.id == mesh.id }
        meshes.append(mesh)
    }

    public func setLines(_ set: SceneLines) {
        if set.group == nil { set.group = groupForID(set.id) }
        lines.removeAll { $0.id == set.id }
        lines.append(set)
    }

    public func remove(id: String) {
        meshes.removeAll { $0.id == id }
        lines.removeAll { $0.id == id }
    }

    public func mesh(_ id: String) -> SceneMesh? { meshes.first { $0.id == id } }

    /// Nearest pickable, visible mesh hit by a world-space ray.
    public func pick(origin: SIMD3<Float>, direction: SIMD3<Float>) -> (id: String, world: SIMD3<Float>, local: SIMD3<Float>)? {
        var best: (Float, String, SIMD3<Float>)?
        for m in meshes where m.isVisible && m.isPickable {
            let g = groupTransform(m.group).inverse
            let o4 = g * SIMD4(origin, 1), d4 = g * SIMD4(direction, 0)
            if let hit = m.intersect(origin: SIMD3(o4.x, o4.y, o4.z), direction: SIMD3(d4.x, d4.y, d4.z)),
               hit.t < (best?.0 ?? .greatestFiniteMagnitude) {
                best = (hit.t, m.id, hit.local)
            }
        }
        guard let (t, id, local) = best else { return nil }
        return (id, origin + direction * t, local)
    }
    public func lineSet(_ id: String) -> SceneLines? { lines.first { $0.id == id } }

    /// Bounds of all visible meshes, transformed.
    public func visibleBounds() -> (SIMD3<Float>, SIMD3<Float>)? {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        var any = false
        for m in meshes where m.isVisible {
            for corner in 0..<8 {
                let c = SIMD3<Float>(corner & 1 == 0 ? m.boundsMin.x : m.boundsMax.x,
                                     corner & 2 == 0 ? m.boundsMin.y : m.boundsMax.y,
                                     corner & 4 == 0 ? m.boundsMin.z : m.boundsMax.z)
                let w = groupTransform(m.group) * m.transform * SIMD4(c, 1)
                lo = simd_min(lo, SIMD3(w.x, w.y, w.z))
                hi = simd_max(hi, SIMD3(w.x, w.y, w.z))
                any = true
            }
        }
        return any ? (lo, hi) : nil
    }
}

extension LineSegment {
    /// The 12 edges of an axis-aligned box.
    public static func box(min lo: SIMD3<Float>, max hi: SIMD3<Float>, color: SIMD4<UInt8>) -> [LineSegment] {
        let c = (0..<8).map { i in
            SIMD3<Float>(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z)
        }
        let edges = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        return edges.map { LineSegment(c[$0.0], c[$0.1], color: color) }
    }

    /// RGB axis triad at the origin.
    public static func axes(length: Float) -> [LineSegment] {
        [LineSegment(.zero, SIMD3(length, 0, 0), color: PathColor.axisX),
         LineSegment(.zero, SIMD3(0, length, 0), color: PathColor.axisY),
         LineSegment(.zero, SIMD3(0, 0, length), color: PathColor.axisZ)]
    }
}
