import CoastlineCore
import Foundation
import simd
import Viewport

/// How close the simulated result is to the CAD.
struct DeviationStats: Equatable {
    /// Share of the part's cells within ±tolerance.
    var within: Double
    /// Most material left (mm) and deepest gouge (mm, positive) anywhere on the part.
    var maxLeft: Double
    var maxGouge: Double
    var tolerance: Double
}

extension AppModel {
    static let deviationTolerance = 0.02

    /// Colours the simulated stock against the CAD: green within ±20 µm, blue where material
    /// is left (deeper blue = more), red where the simulation cut below the part (a gouge).
    /// Drawn as a dense field of short dashes on the simulated surface.
    func updateDeviation() async {
        renderer.scene.remove(id: "deviation")
        guard showDeviation, let hm = heightmap, let part, let stock else { deviationStats = nil; return }
        let key = "\(viewSide)-\(hm.cols)x\(hm.rows)-\(part.partID)-\(hm.origin)"
        if partHeights?.key != key {
            do {
                let engine = try await liveEngine()
                let t = setupFor(side: twoSided ? viewSide : 0).partToWork(partMin: part.boundsMin, partMax: part.boundsMax)
                let h = try await engine.heightField(partID: part.partID, transform: t, origin: hm.origin, cell: hm.cell,
                                                     cols: hm.cols, rows: hm.rows)
                partHeights = (key, h)
            } catch {
                errorMessage = "Couldn't compare with the CAD: \(error)"
                return
            }
        }
        guard let ref = partHeights?.heights, ref.count == hm.heights.count, let current = heightmap else { return }
        let tol = Self.deviationTolerance
        let origin = SIMD3<Float>(workOrigin(stockSize: setup.stockSize(stock)))
        let stride = max(Int((Double(hm.cols * hm.rows) / 70_000).squareRoot().rounded(.up)), 1)
        var segs: [LineSegment] = []
        var inside = 0, ok = 0
        var maxLeft = 0.0, maxGouge = 0.0
        var gougeAt = "", leftAt = ""
        defer {
            if !gougeAt.isEmpty { print("deviation worst gouge at \(gougeAt)") }
            if !leftAt.isEmpty { print("deviation most left at \(leftAt)") }
        }
        for row in Swift.stride(from: 0, to: hm.rows, by: 1) {
            for col in Swift.stride(from: 0, to: hm.cols, by: 1) {
                let i = row * hm.cols + col
                let p = ref[i]
                guard p.isFinite else { continue }
                // Compare against the range of the part's heights around the cell: on steep
                // walls one cell spans a big height change, which is sampling, not error.
                var lo = p, hi = p, edge = false
                for dr in -1...1 {
                    for dc in -1...1 {
                        let r2 = row + dr, c2 = col + dc
                        guard r2 >= 0, r2 < hm.rows, c2 >= 0, c2 < hm.cols else { edge = true; continue }
                        let q = ref[r2 * hm.cols + c2]
                        if !q.isFinite { edge = true; continue }
                        lo = min(lo, q)
                        hi = max(hi, q)
                    }
                }
                if edge { continue }  // the part's outline: walls, not surfaces
                let s = current.heights[i]
                let d: Double = s > hi ? Double(s - hi) : (s < lo ? Double(s - lo) : 0)
                inside += 1
                if abs(d) <= tol { ok += 1 }
                if d > maxLeft, ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil {
                    leftAt = String(format: "x %.2f y %.2f part %.2f…%.2f sim %.2f", hm.origin.x + Double(col) * hm.cell,
                                    hm.origin.y + Double(row) * hm.cell, lo, hi, s)
                }
                maxLeft = max(maxLeft, d)
                if -d > maxGouge, ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil {
                    gougeAt = String(format: "x %.2f y %.2f part %.2f…%.2f sim %.2f back %.2f", hm.origin.x + Double(col) * hm.cell,
                                     hm.origin.y + Double(row) * hm.cell, lo, hi, s, simBack?[i] ?? -99)
                }
                maxGouge = max(maxGouge, -d)
                guard row % stride == 0 && col % stride == 0 else { continue }
                let c: SIMD4<UInt8>
                if d < -tol {
                    c = SIMD4(235, 60, 50, 255)
                } else if d <= tol {
                    c = SIMD4(70, 200, 110, 255)
                } else {
                    let t = min((d - tol) / 0.3, 1)
                    c = SIMD4(UInt8(90 * (1 - t) + 20 * t), UInt8(170 * (1 - t) + 70 * t), 255, 255)
                }
                let x = Float(hm.origin.x + Double(col) * hm.cell), y = Float(hm.origin.y + Double(row) * hm.cell)
                let z = current.heights[i] + 0.01
                let half = Float(hm.cell) * Float(stride) * 0.45
                segs.append(LineSegment(SIMD3(x - half, y, z) + origin, SIMD3(x + half, y, z) + origin, color: c))
            }
        }
        deviationStats = inside > 0 ? DeviationStats(within: Double(ok) / Double(inside), maxLeft: maxLeft, maxGouge: maxGouge, tolerance: tol) : nil
        if let set = SceneLines(device: renderer.device, id: "deviation", segments: segs) {
            renderer.scene.setLines(set)
        }
    }
}
