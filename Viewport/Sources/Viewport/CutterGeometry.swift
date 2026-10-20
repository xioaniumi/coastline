import Foundation
import simd

/// Realistic cutter geometry from a tool's numbers: helical flutes with lands and gullets,
/// the right tip (flat, ball, bull nose, cone, drill point), the flute run-out, a neck and the
/// shank with its chamfer. Tip at the origin, axis +Z (the CR-1's tool axis, pointing away from
/// the work), so it drops straight into the collet in the scene.
public struct CutterShape: Sendable {
    public enum Tip: Sendable {
        case flat
        case ball
        case bull(cornerRadius: Double)
        /// Chamfer mills, engravers, spot drills: half-angle (degrees) and flat tip diameter.
        case cone(halfAngle: Double, tipDiameter: Double)
        /// Twist drills: point angle (degrees).
        case drill(pointAngle: Double)
    }

    public var diameter: Double
    public var fluteLength: Double
    public var shankDiameter: Double
    /// From the tip to the end of the shank (stick-out plus what's in the collet).
    public var length: Double
    public var flutes: Int
    /// Helix angle, degrees (end mills for aluminium ~35–45°, drills ~30°).
    public var helix: Double
    public var tip: Tip

    public init(diameter: Double, fluteLength: Double, shankDiameter: Double, length: Double, flutes: Int,
                helix: Double = 35, tip: Tip = .flat) {
        self.diameter = diameter
        self.fluteLength = fluteLength
        self.shankDiameter = shankDiameter
        self.length = length
        self.flutes = flutes
        self.helix = helix
        self.tip = tip
    }

    public struct Mesh {
        public var positions: [Float] = []
        public var normals: [Float] = []
        public var indices: [UInt32] = []
    }

    /// The fluted part and the shank as separate meshes (they're coloured differently: coatings
    /// only cover the flutes).
    public func meshes() -> (flutes: Mesh, shank: Mesh) {
        let R = diameter / 2
        let rs = shankDiameter / 2
        let n = max(flutes, 1)
        let segments = max(24 * n, 72)
        let fl = min(fluteLength, length - 1)
        // Radius of the cutting envelope at height z above the tip.
        func envelope(_ z: Double) -> Double {
            switch tip {
            case .flat: return R
            case .ball: return z >= R ? R : (max(R * R - (R - z) * (R - z), 0)).squareRoot()
            case .bull(let rc0):
                let rc = min(max(rc0, 0.01), R)
                return z >= rc ? R : R - rc + (max(rc * rc - (rc - z) * (rc - z), 0)).squareRoot()
            case .cone(let half, let tipD):
                return min(tipD / 2 + z * tan(half * .pi / 180), R)
            case .drill(let point):
                return min(z * tan(point / 2 * .pi / 180), R)
            }
        }
        // Flute gullet depth (fraction of the radius) at height z: full along the flutes, running
        // out over a bit more than a diameter above them (the grinding wheel's exit).
        let runout = max(diameter * 0.9, 1.0)
        func depth(_ z: Double) -> Double {
            let full = (tip.isDrill ? 0.42 : 0.33)
            if z <= fl { return full }
            return full * max(1 - (z - fl) / runout, 0)
        }
        // Cross-section: lands at the full radius, then a smooth, asymmetric gullet (steep rake
        // face, gentle heel), repeated per flute.
        func profile(_ phi: Double) -> Double {
            let land = 0.16
            let u = phi - floor(phi)
            if u < land { return 0 }
            let t = (u - land) / (1 - land)
            return pow(sin(.pi * pow(t, 0.65)), 1.3)
        }
        let twist = tan(helix * .pi / 180) / max(R, 0.1)

        var flute = Mesh(), shank = Mesh()
        func ring(_ m: inout Mesh, z: Double, radius: (Double) -> Double) {
            for k in 0..<segments {
                let th = 2 * Double.pi * Double(k) / Double(segments)
                let r = radius(th)
                m.positions += [Float(r * cos(th)), Float(r * sin(th)), Float(z)]
                m.normals += [0, 0, 0]
            }
        }
        func connect(_ m: inout Mesh, rings: Int) {
            for i in 0..<(rings - 1) {
                for k in 0..<segments {
                    let a = UInt32(i * segments + k), b = UInt32(i * segments + (k + 1) % segments)
                    let c = b + UInt32(segments), d = a + UInt32(segments)
                    m.indices += [a, b, c, a, c, d]
                }
            }
        }
        // Heights: dense near the tip (balls and points curve fast), then along the flutes and
        // through the run-out.
        var zs: [Double] = [0]
        let tipZone: Double = switch tip {
        case .ball: R
        case .bull(let rc): min(rc, R)
        case .cone(let half, let tipD): (R - tipD / 2) / max(tan(half * .pi / 180), 0.05)
        case .drill(let p): R / max(tan(p / 2 * .pi / 180), 0.05)
        case .flat: 0
        }
        let tipSteps = tipZone > 0 ? 14 : 0
        for i in 1...max(tipSteps, 1) where tipSteps > 0 {
            // Even steps in angle around a ball, even in z for cones.
            let f = Double(i) / Double(tipSteps)
            let z = { if case .ball = tip { return R * (1 - cos(f * .pi / 2)) } else { return tipZone * f } }()
            zs.append(min(z, fl + runout))
        }
        let along = max(Int((fl + runout - (zs.last ?? 0)) / max(diameter / 14, 0.05)), 8)
        let z0 = zs.last ?? 0
        for i in 1...along { zs.append(z0 + (fl + runout - z0) * Double(i) / Double(along)) }
        for z in zs {
            let env = envelope(z)
            let d = depth(z)
            // Above the flutes the body narrows to the shank (or stays at the cutter's size for
            // tools with a larger shank).
            let body = z > fl ? env + (rs - env) * min((z - fl) / runout, 1) : env
            ring(&flute, z: z) { th in
                let phi = (th + z * twist) * Double(n) / (2 * .pi)
                return max(body * (1 - d * profile(phi)), 0.0005)
            }
        }
        connect(&flute, rings: zs.count)
        // Tip: close the bottom (a point for balls and drills, a flat face for flat end mills).
        let centre = UInt32(flute.positions.count / 3)
        flute.positions += [0, 0, 0]
        flute.normals += [0, 0, 0]
        for k in 0..<segments {
            flute.indices += [centre, UInt32((k + 1) % segments), UInt32(k)]
        }
        // Shank: from the end of the run-out to the end, with a 0.3 mm chamfer at the top.
        let zStart = fl + runout
        let zEnd = max(length, zStart + 1)
        let chamfer = min(0.3, rs * 0.2)
        for (z, r) in [(zStart, rs), (zEnd - chamfer, rs), (zEnd, rs - chamfer)] {
            ring(&shank, z: z) { _ in r }
        }
        connect(&shank, rings: 3)
        let top = UInt32(shank.positions.count / 3)
        shank.positions += [0, 0, Float(zEnd)]
        shank.normals += [0, 0, 0]
        for k in 0..<segments {
            shank.indices += [UInt32(2 * segments + k), UInt32(2 * segments + (k + 1) % segments), top]
        }
        smoothNormals(&flute)
        smoothNormals(&shank)
        return (flute, shank)
    }

    private func smoothNormals(_ m: inout Mesh) {
        var acc = [SIMD3<Float>](repeating: .zero, count: m.positions.count / 3)
        func p(_ i: UInt32) -> SIMD3<Float> { SIMD3(m.positions[Int(i) * 3], m.positions[Int(i) * 3 + 1], m.positions[Int(i) * 3 + 2]) }
        for t in stride(from: 0, to: m.indices.count, by: 3) {
            let a = m.indices[t], b = m.indices[t + 1], c = m.indices[t + 2]
            let n = simd_cross(p(b) - p(a), p(c) - p(a))
            acc[Int(a)] += n
            acc[Int(b)] += n
            acc[Int(c)] += n
        }
        for (i, n) in acc.enumerated() {
            let u = simd_length(n) > 1e-12 ? simd_normalize(n) : SIMD3<Float>(0, 0, 1)
            m.normals[i * 3] = u.x
            m.normals[i * 3 + 1] = u.y
            m.normals[i * 3 + 2] = u.z
        }
    }
}

private extension CutterShape.Tip {
    var isDrill: Bool { if case .drill = self { return true } else { return false } }
}
