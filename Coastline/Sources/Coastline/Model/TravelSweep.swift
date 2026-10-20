import CoastlineCore
import Foundation
import simd
import Viewport

extension AppModel {
    /// Drives the modelled CR-1 through its whole travel with the bit in the collet: around the
    /// X–Y limits with the spindle retracted, the same fully plunged, and along the four Z
    /// edges. The tool tip's path, drawn on the table, is the real work volume: it must match
    /// the ghosted work-area box, and nothing may pass through the machine on the way.
    func sweepTravel(duration: Double = 9) {
        guard machineLoaded, let pose = modelPose else { return }
        pause()
        flipTask?.cancel(); stockAnimating = false
        if let tool = currentTool { ensureToolMesh(tool) }
        let e = machine.machineEnvelope
        let (x0, x1, y0, y1, z0, z1) = (e.x.lowerBound, e.x.upperBound, e.y.lowerBound, e.y.upperBound, e.z.lowerBound, e.z.upperBound)
        // Home (table down, gantry right, spindle back), round the top face, plunge, round the
        // bottom face, then the remaining Z edges.
        let corners: [SIMD3<Double>] = [
            SIMD3(x0, y1, z1), SIMD3(x0, y0, z1), SIMD3(x1, y0, z1), SIMD3(x1, y1, z1), SIMD3(x0, y1, z1),
            SIMD3(x0, y1, z0), SIMD3(x0, y0, z0), SIMD3(x1, y0, z0), SIMD3(x1, y1, z0), SIMD3(x0, y1, z0),
            SIMD3(x0, y0, z0), SIMD3(x0, y0, z1), SIMD3(x1, y0, z1), SIMD3(x1, y0, z0),
            SIMD3(x1, y1, z0), SIMD3(x1, y1, z1), SIMD3(x0, y1, z1),
        ]
        var lengths: [Double] = [0]
        for k in 1..<corners.count { lengths.append(lengths[k - 1] + simd_length(corners[k] - corners[k - 1])) }
        let total = lengths.last ?? 1
        let tip0 = tipAtModelPose
        // Relative to the table, the tip moves by the full machine displacement from the pose.
        func tipOnTable(_ q: SIMD3<Double>) -> SIMD3<Float> { SIMD3<Float>(tip0 + (q - pose)) }
        renderer.scene.remove(id: "travel.trace")
        status = "Sweeping the CR-1's travel…"
        let start = Date()
        flipTask = Task { @MainActor [weak self] in
            var trace: [SIMD3<Float>] = []
            while !Task.isCancelled, let self {
                let t = min(Date().timeIntervalSince(start) / duration, 1)
                let s = t * total
                let k = max(lengths.lastIndex { $0 <= s } ?? 0, 0)
                let q: SIMD3<Double>
                if k >= corners.count - 1 {
                    q = corners[corners.count - 1]
                } else {
                    let f = (s - lengths[k]) / max(lengths[k + 1] - lengths[k], 1e-9)
                    q = corners[k] + (corners[k + 1] - corners[k]) * f
                }
                self.setMachinePosition(q)
                trace.append(tipOnTable(q))
                var segs: [LineSegment] = []
                for i in 1..<max(trace.count, 1) {
                    segs.append(LineSegment(trace[i - 1], trace[i], color: SIMD4(255, 210, 60, 255)))
                }
                if !segs.isEmpty, let set = SceneLines(device: self.renderer.device, id: "travel.trace", segments: segs) {
                    self.renderer.scene.setLines(set)
                }
                if t >= 1 {
                    self.status = "Travel sweep done: the yellow path is everywhere the tool tip can reach."
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
}
