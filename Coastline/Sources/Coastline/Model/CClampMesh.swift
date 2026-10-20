import Foundation
import Metal
import simd
import Viewport

/// A 3" screw C-clamp (the two in the CR-1 Universal Clamp kit): cast-iron C frame, zinc screw
/// with a swivel pad and a T-handle. It reaches over the table's back edge: the pad presses the
/// stock's top, the fixed jaw sits under the table plate; `spineZ` is the frame's inside, just
/// behind the table's back edge. Model coordinates (X up). Matches SideClamps.solids.
enum CClampMesh {
    static func meshes(device: MTLDevice, id: String, clampPoint c: SIMD3<Double>, tableUnderX: Double, spineZ: Double) -> [SceneMesh] {
        let iron = SIMD4<Float>(0.035, 0.035, 0.04, 1), zinc = SIMD4<Float>(0.62, 0.64, 0.66, 1)
        let w = 4.5         // half thickness across (Y)
        let top = c.x + 30, armT = 8.0
        var out: [SceneMesh] = []
        func box(_ name: String, _ lo: SIMD3<Double>, _ hi: SIMD3<Double>, _ col: SIMD4<Float>, _ mat: SurfaceMaterial) {
            if let m = SceneMesh.box(device: device, id: "\(id).\(name)", min: SIMD3<Float>(lo), max: SIMD3<Float>(hi), color: col) {
                m.material = mat
                out.append(m)
            }
        }
        let castIron = SurfaceMaterial(metallic: 0.4, roughness: 0.6)
        // Frame: spine, top arm over the stock, bottom arm under the table.
        box("spine", SIMD3(tableUnderX - armT - 4, c.y - w, spineZ - 9), SIMD3(top + armT, c.y + w, spineZ), iron, castIron)
        box("top", SIMD3(top, c.y - w, spineZ - 9), SIMD3(top + armT, c.y + w, c.z + 7), iron, castIron)
        box("bottom", SIMD3(tableUnderX - armT - 4, c.y - w, spineZ - 9), SIMD3(tableUnderX - 4, c.y + w, c.z + 7), iron, castIron)
        box("jaw", SIMD3(tableUnderX - 4, c.y - 7, c.z - 7), SIMD3(tableUnderX, c.y + 7, c.z + 7), iron, castIron)
        // Screw (along X), swivel pad and T-handle.
        var b = MeshBuilder()
        b.cylinder(radius: 4.5, z0: 3, z1: Float(top + armT + 25 - c.x))
        if let m = b.mesh(device: device, id: "\(id).screw", color: zinc) {
            m.transform = simd_float4x4(translation: SIMD3<Float>(c)) * simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
            m.material = .chrome
            out.append(m)
        }
        var pad = MeshBuilder()
        pad.cylinder(radius: 8, z0: 0, z1: 3)
        if let m = pad.mesh(device: device, id: "\(id).pad", color: zinc) {
            m.transform = simd_float4x4(translation: SIMD3<Float>(c)) * simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
            m.material = .chrome
            out.append(m)
        }
        var handle = MeshBuilder()
        handle.cylinder(radius: 2.5, z0: -35, z1: 35)
        if let m = handle.mesh(device: device, id: "\(id).handle", color: zinc) {
            m.transform = simd_float4x4(translation: SIMD3<Float>(Float(top + armT + 22), Float(c.y), Float(c.z)))
                * simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0)))
            m.material = .chrome
            out.append(m)
        }
        return out
    }
}
