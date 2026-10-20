import CoastlineCore
import Foundation
import Metal
import Viewport

extension Tool {
    /// The cutter's real shape from its numbers (flutes, helix, tip), for the 3D views.
    var cutterShape: CutterShape {
        let tip: CutterShape.Tip = switch kind {
        case .ballEndMill: .ball
        case .bullNoseEndMill: .bull(cornerRadius: cornerRadius)
        case .chamferMill, .engraver: .cone(halfAngle: angle ?? 45, tipDiameter: tipDiameter)
        case .spotDrill: .cone(halfAngle: (angle ?? 90) / 2, tipDiameter: 0)
        case .drill: .drill(pointAngle: angle ?? 118)
        default: .flat
        }
        // Aluminium cutters run steep helices; 2-flute small tools and drills ~30°.
        let helix: Double = kind == .drill ? 30 : (flutes <= 2 ? 30 : 38)
        return CutterShape(diameter: diameter, fluteLength: max(fluteLength, 0.5), shankDiameter: max(shankDiameter, 0.5),
                           length: stickout + 15, flutes: kind == .drill ? 2 : max(flutes, 1), helix: helix, tip: tip)
    }

    /// Flute colour: the coating (linear RGB), or bare carbide / HSS.
    var fluteColor: SIMD4<Float> {
        switch coating {
        case .tiN: SIMD4(0.78, 0.52, 0.12, 1)
        case .zrN: SIMD4(0.80, 0.68, 0.40, 1)
        case .tiAlN, .alTiN: SIMD4(0.18, 0.15, 0.22, 1)
        case .alCrN: SIMD4(0.30, 0.32, 0.36, 1)
        case .dlc, .diamond: SIMD4(0.10, 0.10, 0.11, 1)
        case .none: toolMaterial == .hss ? SIMD4(0.50, 0.50, 0.52, 1) : SIMD4(0.58, 0.59, 0.62, 1)
        }
    }

    /// Scene meshes for the flutes and the shank (tip at the origin, axis +Z).
    func sceneMeshes(device: MTLDevice, id: String) -> [SceneMesh] {
        if EdgeFinding.isEdgeFinder(self) {
            // Fisher A250: the 0.2" tip on its spring joint, then the 1/4" body.
            var tip = MeshBuilder(), body = MeshBuilder()
            tip.cylinder(radius: Float(diameter / 2), z0: 0, z1: 9)
            body.cylinder(radius: 1.6, z0: 9, z1: 10.5)
            body.cylinder(radius: Float(shankDiameter / 2), z0: 10.5, z1: Float(stickout))
            var out: [SceneMesh] = []
            if let m = tip.mesh(device: device, id: id, color: SIMD4(0.85, 0.86, 0.88, 1)) { m.material = .chrome; out.append(m) }
            if let m = body.mesh(device: device, id: id + ".shank", color: SIMD4(0.75, 0.76, 0.78, 1)) { m.material = .chrome; out.append(m) }
            return out
        }
        let (f, s) = cutterShape.meshes()
        var out: [SceneMesh] = []
        if let m = SceneMesh(device: device, id: id, positions: f.positions, normals: f.normals, indices: f.indices, color: fluteColor) {
            m.material = SurfaceMaterial(metallic: 1, roughness: coating == .none ? 0.22 : 0.3)
            out.append(m)
        }
        if let m = SceneMesh(device: device, id: id + ".shank", positions: s.positions, normals: s.normals, indices: s.indices,
                             color: SIMD4(0.58, 0.59, 0.62, 1)) {
            m.material = SurfaceMaterial(metallic: 1, roughness: 0.14)
            out.append(m)
        }
        return out
    }
}
