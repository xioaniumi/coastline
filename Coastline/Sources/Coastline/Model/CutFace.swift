import CoastlineCore
import Foundation
import simd
import Viewport

extension AppModel {
    /// Tints the stock face the current or next cut works on, so it's clear which way round the
    /// stock goes at each step: the face toward the spindle for facing and the part's sides, the
    /// top edge while milling the stock down on the side clamps.
    func layoutCutFace() {
        let scene = renderer.scene
        guard showCutFace, let stock, let size = displayStockSize else {
            cutFaceKey = ""
            scene.remove(id: "cutface")
            scene.remove(id: "cutface.edges")
            return
        }
        let edge = false  // every step, prep included, cuts the face toward the spindle
        let key = "\(viewSide)-\(edge)-\(size)-\(stock.id)"
        if cutFaceKey == key { return }
        cutFaceKey = key
        let o = workOrigin(stockSize: size)
        let t: Double = 0.06  // just proud of the surface
        let lo: SIMD3<Double>, hi: SIMD3<Double>
        if edge {
            lo = o + SIMD3(size.x / 2, -size.y / 2, -size.z)
            hi = o + SIMD3(size.x / 2 + t, size.y / 2, 0)
        } else {
            lo = o + SIMD3(-size.x / 2, -size.y / 2, 0)
            hi = o + SIMD3(size.x / 2, size.y / 2, t)
        }
        let tint = SIMD4<Float>(0.10, 0.62, 0.66, 0.30)
        if let m = SceneMesh.box(device: renderer.device, id: "cutface", min: SIMD3<Float>(lo), max: SIMD3<Float>(hi), color: tint) {
            m.material = SurfaceMaterial(metallic: 0, roughness: 0.6, edges: 0)
            scene.setMesh(m)
        }
        if let e = SceneLines(device: renderer.device, id: "cutface.edges",
                              segments: LineSegment.box(min: SIMD3<Float>(lo), max: SIMD3<Float>(hi), color: SIMD4(40, 200, 210, 255))) {
            scene.setLines(e)
        }
    }
}
