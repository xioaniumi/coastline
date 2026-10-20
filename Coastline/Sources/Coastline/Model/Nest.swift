import CoastlineCore
import Foundation
import Metal
import simd
import Viewport

/// A printable nest (engine cam/nest.py): the part, already cut free, sits face-down in a cavity
/// shaped like that face, and its other face is machined. Printed on a Formlabs printer; it goes
/// into the universal clamp like stock (the Operator Manual's "custom clamshell").
extension AppModel {
    enum NestFace: String, CaseIterable, Identifiable {
        /// The front (side A's face) in the nest: the back gets machined.
        case front
        /// The back in the nest: the front gets machined.
        case back
        var id: Self { self }
        var title: String { self == .front ? "Front down: machine the back" : "Back down: machine the front" }
    }

    /// The nest for the current part and orientation.
    func makeNest(face: NestFace, clearance: Double, wall: Double) async throws -> EngineClient.Nest? {
        guard let part, let stock else { return nil }
        let s = face == .front ? setup.sideB(partMin: part.boundsMin, partMax: part.boundsMax, stock: stock) : setup
        let t = s.partToWork(partMin: part.boundsMin, partMax: part.boundsMax)
        let engine = try await liveEngine()
        return try await engine.nest(partID: part.partID, transform: t, clearance: clearance, wall: wall,
                                     minHeight: UniversalClamp.onJaw.lowerBound + 0.5)
    }

    /// The nest as a mesh for the preview (its own frame, cavity up).
    static func nestMesh(_ stl: Data, device: MTLDevice) -> SceneMesh? {
        guard stl.count > 84 else { return nil }
        let n = stl.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 80, as: UInt32.self)) }
        guard stl.count >= 84 + n * 50 else { return nil }
        var positions: [Float] = [], normals: [Float] = [], indices: [UInt32] = []
        positions.reserveCapacity(n * 9)
        stl.withUnsafeBytes { raw in
            for k in 0..<n {
                let base = 84 + k * 50
                let nv = (0..<3).map { raw.loadUnaligned(fromByteOffset: base + $0 * 4, as: Float.self) }
                for v in 0..<3 {
                    for c in 0..<3 { positions.append(raw.loadUnaligned(fromByteOffset: base + 12 + v * 12 + c * 4, as: Float.self)) }
                    normals += nv
                    indices.append(UInt32(k * 3 + v))
                }
            }
        }
        let m = SceneMesh(device: device, id: "nest", positions: positions, normals: normals, indices: indices,
                          color: SIMD4(0.78, 0.80, 0.84, 1), pickable: false)
        m?.material = SurfaceMaterial(metallic: 0, roughness: 0.55, edges: 0.4)
        return m
    }
}
