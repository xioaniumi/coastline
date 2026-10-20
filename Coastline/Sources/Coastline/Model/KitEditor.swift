import CoastlineCore
import Foundation
import simd
import Viewport

/// The clamp kit editor (stage 4, R5): press on a universal clamp and slide it along the T-slots,
/// or on the stock and drag it toward the spindle (how far its face stands out past the jaws).
/// The strips the jaws hold (never cut) are drawn on the stock. Moving them keeps the toolpaths
/// (they're relative to the stock face) and checks them again against the clamps.
extension AppModel {
    /// The clamp kit can be edited while stage 4 shows a side in the kit.
    var kitEditable: Bool { stage == .clampKit && !setup.onBed && viewSide >= 0 && stock != nil && !showingStockOnly }

    /// Whether a picked object belongs to what's on screen now.
    func pickValid(_ b: BedObject) -> Bool {
        switch b {
        case .stop, .clamp: bedEditable
        case .kitClamp, .kitStock: kitEditable
        }
    }

    /// How far a universal clamp may slide either way: its jaw stays under the stock.
    var kitClampRange: Double {
        guard let stock else { return 0 }
        return max(setup.stockSize(stock).y / 2 - 12, 0)
    }

    func kitClampShift(_ i: Int) -> Double { i < setup.kitClampShift.count ? setup.kitClampShift[i] : 0 }

    func setKitClampShift(_ i: Int, _ v: Double, from start: Setup? = nil) {
        var s = start ?? setup
        while s.kitClampShift.count <= i { s.kitClampShift.append(0) }
        let r = kitClampRange
        s.kitClampShift[i] = min(max((v * 2).rounded() / 2, -r), r)
        while let last = s.kitClampShift.last, last == 0 { s.kitClampShift.removeLast() }
        if s != setup { setup = s }
    }

    /// The face's stand-out past the jaws, set by hand (the automatic one gives way).
    func setProtrusion(_ v: Double, from start: Setup? = nil) {
        guard let stock else { return }
        var s = start ?? setup
        s.clampProtrusion = min(max((v * 2).rounded() / 2, 0.5), max(setup.stockSize(stock).z - 3, 0.5))
        autoProtrusion = nil
        if s != setup { setup = s }
    }

    // MARK: Clearance follows the clamps

    /// The programs checked again against the clamps where they are now (no regeneration).
    func recheckClearance() {
        guard !programs.isEmpty, let stock, let field = clampKitField(stockSize: setup.stockSize(stock)) else { return }
        clearanceRecheck?.cancel()
        status = "Checking the toolpaths against the clamps…"
        let jobs: [(Int, Tool, [Move])] = programs.enumerated().compactMap { k, p in
            guard p.side >= 0, p.side < sideResults.count else { return nil }
            let r = sideResults[p.side]
            let moves = zip(r.operationProgram, r.paths).filter { $0.0 == p.index }.flatMap { $0.1.moves }
            return (k, p.tool, moves)
        }
        clearanceRecheck = Task { @MainActor in
            let results = await Task.detached(priority: .userInitiated) {
                jobs.map { job -> (Int, [FixtureClearance.Hit]) in
                    var f = field
                    return (job.0, FixtureClearance.check(job.2, tool: job.1, field: &f))
                }
            }.value
            guard !Task.isCancelled else { return }
            for (k, hits) in results where k < programs.count {
                var p = programs[k]
                if let old = FixtureClearance.describe(p.clearanceHits) { p.report.issues.removeAll { $0.message == old } }
                if let text = FixtureClearance.describe(hits) { p.report.issues.append(Issue(.error, text)) }
                p.clearanceHits = hits
                programs[k] = p
            }
            showClearanceHits()
            let n = programs.filter { !$0.clearanceHits.isEmpty }.count
            status = n == 0 ? "Checked again: no tool comes near the clamps." : "\(n) program\(n == 1 ? "" : "s") now come\(n == 1 ? "s" : "") too close to the clamps (red crosses)."
        }
    }

    // MARK: The strips the jaws hold

    /// Orange bands on the stock face where the jaws grip (those strips are never cut).
    func layoutGripStrips() {
        let scene = renderer.scene
        scene.remove(id: "grip.strips")
        guard kitEditable, let size = displayStockSize else { return }
        let o = SIMD3<Float>(workOrigin(stockSize: size)), s = size
        var p: [Float] = [], n: [Float] = [], ix: [UInt32] = []
        for r in shoulderStrips(stockSize: s) {
            // Clipped to the stock's face.
            let x0 = max(r.min.x, -s.x / 2), x1 = min(r.max.x, s.x / 2), y0 = max(r.min.y, -s.y / 2), y1 = min(r.max.y, s.y / 2)
            guard x1 > x0, y1 > y0 else { continue }
            let base = UInt32(p.count / 3)
            for (x, y) in [(x0, y0), (x1, y0), (x1, y1), (x0, y1)] {
                p += [Float(x) + o.x, Float(y) + o.y, o.z + 0.05]
                n += [0, 0, 1]
            }
            ix += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        guard !ix.isEmpty, let m = SceneMesh(device: renderer.device, id: "grip.strips", positions: p, normals: n, indices: ix,
                                             color: SIMD4(1.0, 0.45, 0.05, 0.45)) else { return }
        m.unlit = true
        m.depthBias = 0.002
        scene.setMesh(m)
    }
}
