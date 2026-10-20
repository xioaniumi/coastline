import CoastlineCore
import Foundation
import simd

/// Jogging the modelled CR-1 by hand (the Jog panel): machine coordinates across the real
/// travel, with or without a bit, the work coordinates of the current setup, and whether the
/// tool touches a clamp there.
extension AppModel {
    /// Puts the machine at machine coordinates `q`, with the jog tool in the collet (or none).
    func jog(to q: SIMD3<Double>) {
        pause()
        let e = machine.machineEnvelope
        let c = SIMD3(min(max(q.x, e.x.lowerBound), e.x.upperBound), min(max(q.y, e.y.lowerBound), e.y.upperBound),
                      min(max(q.z, e.z.lowerBound), e.z.upperBound))
        currentTool = jogTool
        if let t = jogTool { ensureToolMesh(t) } else {
            renderer.scene.remove(id: "tool")
            renderer.scene.remove(id: "tool.shank")
        }
        setMachinePosition(c)
    }

    /// Stick-out of what's in the collet while jogging (0: the bare spindle nose).
    var jogStickout: Double { jogTool?.stickout ?? 0 }

    /// The work coordinates (setup's frame) of the tool tip, or the spindle nose without a bit.
    var jogWorkPosition: SIMD3<Double>? {
        guard let mm = machineModel, let stock else { return nil }
        let q = machinePosition, m = mm.modelPose
        let o = workOrigin(stockSize: displayStockSize ?? setup.stockSize(stock)), t = tipAtModelPose(stickout: jogStickout)
        return SIMD3(q.x - m.x + t.x - o.x, q.y - m.y - o.y + t.y, q.z - m.z - o.z + t.z)
    }

    /// Whether the jog tool (cutter, shank, collet nut) would touch the clamp kit here.
    var jogTouchesClamp: Bool {
        guard viewSide >= 0, let tool = jogTool, let p = jogWorkPosition, let stock, var field = clampKitField(stockSize: setup.stockSize(stock))
        else { return false }
        return !FixtureClearance.check([Move(.rapid, x: p.x, y: p.y, z: p.z)], tool: tool, field: &field, margin: 0).isEmpty
    }

    /// Named places to jump to: home, the tool-change position, the work zero and the stock's
    /// face corners (2 mm in front of the face).
    var jogPlaces: [(String, SIMD3<Double>)] {
        var out: [(String, SIMD3<Double>)] = [("Home", SIMD3(-0.5, -0.5, -0.5)), ("Tool change", SIMD3(-1, -58, -60))]
        if let stock {
            let s = displayStockSize ?? setup.stockSize(stock)
            let points: [(String, SIMD3<Double>)] = [
                ("Work zero", SIMD3(0, 0, 2)),
                ("Top left corner", SIMD3(s.x / 2, -s.y / 2, 2)), ("Top right corner", SIMD3(s.x / 2, s.y / 2, 2)),
                ("Bottom left corner", SIMD3(-s.x / 2, -s.y / 2, 2)), ("Bottom right corner", SIMD3(-s.x / 2, s.y / 2, 2)),
            ]
            for (name, p) in points {
                if let q = machinePosition(forWork: p, stickout: jogStickout) { out.append((name, q)) }
            }
        }
        return out
    }
}
