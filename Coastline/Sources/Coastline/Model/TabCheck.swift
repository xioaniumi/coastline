import CoastlineCore
import Foundation
import simd

/// Holding tabs that hold. A tab keeps the part only if its far end is in the frame: stock that
/// is still there at the tab's height once both sides are cut and that runs out to the stock's
/// edge. Side A's channel around the part can be much wider than a rule of thumb says (it is
/// cut around the part's widest outline, a bail or a lug included), so side B's tabs are made
/// from side A's simulated result: generation waits for side A's clearing, finds the frame in
/// it (`tabFrame`), and the engine runs every tab out until it's 1.5 mm into it. After
/// generation `checkTabs` checks the finished job the same way; a tab that doesn't hold fails
/// side B's last program (the part would come loose in the cut).
extension AppModel {
    /// A one-sided part in the clamp kit cut free on tabs: the bar at most this much thicker than
    /// the part (the extra comes off the face; thicker bars keep the part on the back of the bar).
    static let throughMaxExcess = 3.0

    /// How much thicker the bar is than the part, when a one-sided job in the clamp kit can cut
    /// the part free on tabs (nil: two-sided, on the bed, or a bar too thick for it).
    var oneSidedThroughExcess: Double? {
        guard !twoSided, !setup.onBed, let part, let stock else { return nil }
        let (lo, hi) = setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        let e = setup.stockSize(stock).z - (hi.z - lo.z)
        guard e >= -0.01 && e <= Self.throughMaxExcess + 1e-9 else { return nil }
        // Nothing may sit behind the cut: a parallel behind the outline (one clamp in the middle
        // of a short bar) would be cut into. Then the part stays on the back of the bar.
        if let k = clampKitLayout(stockSize: setup.stockSize(stock)) {
            let pad = 6.0  // the widest finishing tool's radius and a margin
            let y0 = kitCentreY + setup.partOffsetY - (hi.y - lo.y) / 2 - pad, y1 = kitCentreY + setup.partOffsetY + (hi.y - lo.y) / 2 + pad
            if k.boxes.contains(where: { $0.id.hasPrefix("fixture.parallel") && $0.hi.y > y0 && $0.lo.y < y1 }) { return nil }
        }
        return max(e, 0)
    }

    /// One side, the part at the back of the bar, the outline cut right through, the part held
    /// on tabs (Hold with tabs; off: it stays joined to the back of the bar).
    var cutsThroughWithTabs: Bool { holdWithTabs && oneSidedThroughExcess != nil }

    /// One side, not cut through: how much bar stays behind the part (it's sawn off after).
    var partOnBarBack: Double {
        guard !twoSided, !cutsThroughWithTabs, let part, let stock else { return 0 }
        let (lo, hi) = setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        return max(setup.stockSize(stock).z - setup.topAllowance - (hi.z - lo.z), 0)
    }

    /// The side that cuts through and keeps the tabs (B, or the only one).
    var tabSide: Int { twoSided ? 1 : 0 }

    /// The tabs' Z range on a one-sided job: at the back of the bar, the cut 0.3 mm past it.
    func oneSidedTabRange(stock: StockItem) -> ClosedRange<Double> {
        let at = -setup.stockSize(stock).z
        return (at - Self.throughOvershoot)...(at + tabs.height)
    }

    /// The stock after these toolpaths (each with its tool), simulated.
    nonisolated static func simulate(_ ops: [(paths: [OperationToolpath], tool: Tool)], stockSize size: SIMD3<Double>) -> Heightmap {
        var hm = Heightmap(stockMin: SIMD3(-size.x / 2, -size.y / 2, -size.z), stockMax: SIMD3(size.x / 2, size.y / 2, 0), maxCells: 250_000)
        var pos: SIMD3<Double>?
        for (paths, tool) in ops {
            for p in paths {
                for m in p.moves {
                    hm.apply(m, from: pos ?? m.position, radius: tool.diameter / 2, cornerRadius: tool.cornerRadius)
                    pos = m.position
                }
            }
        }
        return hm
    }

    /// The frame at the tabs' height in side B's work frame (side B is side A turned
    /// front-to-back: its (x, y) is side A's (x, −y), its z side A's −T − z): the cells where
    /// side A left material through the tabs' bottom, connected to the stock's edge (what's
    /// left by the part inside the channel isn't frame).
    nonisolated static func tabFrame(sideA a: Heightmap, thickness: Double, tabBottom: Double) -> TabFrame {
        let cols = a.cols, rows = a.rows
        let need = Float(-thickness - tabBottom - 0.05)
        var material = [Bool](repeating: false, count: cols * rows)
        for r in 0..<rows {
            let y = a.origin.y + Double(r) * a.cell
            let ra = min(max(Int(((-y - a.origin.y) / a.cell).rounded()), 0), rows - 1)
            for c in 0..<cols where a.height(col: c, row: ra) >= need { material[r * cols + c] = true }
        }
        // Connected to the edge (4-neighbours).
        var frame = [Bool](repeating: false, count: cols * rows)
        var stack: [Int] = []
        for r in 0..<rows {
            for c in 0..<cols where r == 0 || c == 0 || r == rows - 1 || c == cols - 1 {
                let i = r * cols + c
                if material[i] && !frame[i] { frame[i] = true; stack.append(i) }
            }
        }
        while let i = stack.popLast() {
            let r = i / cols, c = i % cols
            for (dr, dc) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
                let rr = r + dr, cc = c + dc
                guard (0..<rows).contains(rr), (0..<cols).contains(cc) else { continue }
                let j = rr * cols + cc
                if material[j] && !frame[j] { frame[j] = true; stack.append(j) }
            }
        }
        return TabFrame(origin: a.origin, cell: a.cell, cols: cols, rows: rows, frame: frame)
    }

    /// One side: the cells with material at the tabs' middle height (the skin over the bar's
    /// back, the uncut frame), connected to the stock's edge.
    nonisolated static func oneSidedFrame(_ b: Heightmap, level: Double) -> TabFrame {
        let cols = b.cols, rows = b.rows
        var material = [Bool](repeating: false, count: cols * rows)
        for r in 0..<rows { for c in 0..<cols where Double(b.height(col: c, row: r)) >= level { material[r * cols + c] = true } }
        return TabFrame(origin: b.origin, cell: b.cell, cols: cols, rows: rows, frame: connectedToEdge(material, cols: cols, rows: rows))
    }

    nonisolated static func connectedToEdge(_ material: [Bool], cols: Int, rows: Int) -> [Bool] {
        var frame = [Bool](repeating: false, count: cols * rows)
        var stack: [Int] = []
        for r in 0..<rows {
            for c in 0..<cols where r == 0 || c == 0 || r == rows - 1 || c == cols - 1 {
                let i = r * cols + c
                if material[i] && !frame[i] { frame[i] = true; stack.append(i) }
            }
        }
        while let i = stack.popLast() {
            let r = i / cols, c = i % cols
            for (dr, dc) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
                let rr = r + dr, cc = c + dc
                guard (0..<rows).contains(rr), (0..<cols).contains(cc) else { continue }
                let j = rr * cols + cc
                if material[j] && !frame[j] { frame[j] = true; stack.append(j) }
            }
        }
        return frame
    }

    /// Before side B's jobs (tabs only): waits for side A's clearing (everything but its 3D
    /// finishing and engraving, which stay at the part) and puts the frame from it into side B's
    /// tab spec, so every side B job places the same tabs, each long enough.
    func awaitTabFrame(_ run: GenerationRun, side si: Int) async {
        defer { if run.sides[si].tabSpec?.frame != nil || cancelGeneration || stock == nil { run.frameReady = true } }
        guard si > 0, run.sides[si].tabSpec != nil, run.sides[si].tabSpec?.frame == nil, let stock else { return }
        let a = run.sides[0]
        let needed = a.planned.indices.filter { !a.planned[$0].operation.kind.is3D && a.planned[$0].operation.kind != .engrave }
        while !cancelGeneration, !needed.allSatisfy({ k in run.done[0][k] != nil || run.failed.contains { $0.side == 0 && $0.k == k } }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !cancelGeneration, run.sides[si].tabSpec?.frame == nil else { return }
        if let task = run.frameTask {
            let f = await task.value
            run.sides[si].tabSpec?.frame = f
            return
        }
        let ops = needed.compactMap { k in run.done[0][k].map { (paths: $0, tool: a.planned[k].tool) } }
        let size = setup.stockSize(stock), bottom = run.sides[si].tabBottom
        let task = Task.detached(priority: .userInitiated) {
            Self.tabFrame(sideA: Self.simulate(ops, stockSize: size), thickness: size.z, tabBottom: bottom)
        }
        run.frameTask = task
        let f = await task.value
        run.sides[si].tabSpec?.frame = f
    }

    /// For each placed tab: whether it holds, in the finished job (both sides simulated to the
    /// end): material all along it at its height, and its far end in the frame.
    nonisolated static func tabsHold(_ tabs: [PlacedTab], a: Heightmap?, b: Heightmap, thickness: Double,
                                     z: ClosedRange<Double>) -> [Bool] {
        // The frame: two sides, what side A left at the tabs' height; one side, what it didn't
        // cut down to the tabs' top (the uncut frame round the clearing).
        let frame = a.map { tabFrame(sideA: $0, thickness: thickness, tabBottom: z.lowerBound) }
            ?? oneSidedFrame(b, level: (z.lowerBound + z.upperBound) / 2)
        let mid = (z.lowerBound + z.upperBound) / 2
        func surface(_ hm: Heightmap, _ p: SIMD2<Double>) -> Double {
            let c = min(max(Int(((p.x - hm.origin.x) / hm.cell).rounded()), 0), hm.cols - 1)
            let r = min(max(Int(((p.y - hm.origin.y) / hm.cell).rounded()), 0), hm.rows - 1)
            return Double(hm.height(col: c, row: r))
        }
        return tabs.map { t in
            guard let g = t.extent else { return false }
            let n = g.normal, along = SIMD2(-n.y, n.x)
            // Material at the tab's middle height all along it (side B kept it, side A didn't
            // cut through it), from just outside the part to its end.
            var s = 0.6
            while s < g.length - 0.4 {
                let q = t.centre + n * s
                let fromA = a.map { -thickness - surface($0, SIMD2(q.x, -q.y)) } ?? -thickness  // where side A's material starts (B's frame)
                if !(fromA <= mid + 1e-3 && mid <= surface(b, q) + 1e-3) {
                    if ProcessInfo.processInfo.environment["COASTLINE_TAB_DEBUG"] != nil {
                        print("tab \(t.centre) gap at \(s) of \(g.length): A from \(fromA) B to \(surface(b, q)) mid \(mid)")
                    }
                    return false
                }
                s += 0.5
            }
            // Its far end in the frame, across its width.
            let end = t.centre + n * (g.length - 0.75)
            if ProcessInfo.processInfo.environment["COASTLINE_TAB_DEBUG"] != nil {
                print("tab \(t.centre) length \(g.length) end frame \([g.across.lowerBound + 0.25, 0, g.across.upperBound - 0.25].map { frame.isFrame(end + along * $0) })")
            }
            return [g.across.lowerBound + 0.25, (g.across.lowerBound + g.across.upperBound) / 2, g.across.upperBound - 0.25]
                .allSatisfy { frame.isFrame(end + along * $0) }
        }
    }

    /// The tabs' Z range (side B work frame): as generated, else from the split.
    var tabZ: ClosedRange<Double>? {
        if let z = placedTabZ { return z }
        guard let stock else { return nil }
        if cutsThroughWithTabs { return oneSidedTabRange(stock: stock) }
        guard let split = splitZ else { return nil }
        return tabRange(sideB: setupFor(side: 1), stock: stock, split: split)
    }

    /// The finished job's tabs checked (nil: no tabs in this job).
    func tabsHold() async -> [Bool]? {
        guard (twoSided && holdWithTabs) || cutsThroughWithTabs, let stock, let z = tabZ,
              let rb = sideResults.first(where: { $0.side == tabSide }) else { return nil }
        let ra = twoSided ? sideResults.first(where: { $0.side == 0 }) : nil
        if twoSided && ra == nil { return nil }
        let size = setup.stockSize(stock)
        let tabs = placedTabs
        func ops(_ r: SideResult) -> [(paths: [OperationToolpath], tool: Tool)] {
            r.paths.indices.compactMap { k in r.planned.indices.contains(k) ? ([r.paths[k]], r.planned[k].tool) : nil }
        }
        let oa = ra.map(ops), ob = ops(rb)
        return await Task.detached(priority: .userInitiated) {
            let a = oa.map { Self.simulate($0, stockSize: size) }, b = Self.simulate(ob, stockSize: size)
            return Self.tabsHold(tabs, a: a, b: b, thickness: size.z, z: z)
        }.value
    }

    /// Generation's last check: a two-sided job held by tabs fails side B's last program when a
    /// tab doesn't hold, or when there are none (the part would fall into the cut).
    func checkTabs() async {
        guard (twoSided && holdWithTabs) || cutsThroughWithTabs, let pi = programs.lastIndex(where: { $0.side == tabSide }) else { return }
        guard !placedTabs.isEmpty else {
            programs[pi].report.issues.append(Issue(.error, "No holding tab could be placed: the last cut would free the part. \(twoSided ? "Use a full web (Setup ▸ Sides) or larger stock." : "Turn Hold with tabs off (Setup ▸ Sides): the part then stays on the back of the bar.")"))
            return
        }
        guard let held = await tabsHold() else { return }
        let loose = held.indices.filter { !held[$0] }
        guard !loose.isEmpty, programs.indices.contains(pi) else { return }
        programs[pi].report.issues.append(Issue(.error, "Holding tab\(loose.count == 1 ? "" : "s") \(loose.map { String($0 + 1) }.joined(separator: ", ")) \(loose.count == 1 ? "doesn't" : "don't") reach stock that stays: the part would come loose in the last cut. Use a full web (Setup ▸ Sides) or larger stock."))
    }
}

extension PlacedTab {
    /// How far the tab runs out from its centre on the outline, and its sides across (from the
    /// centre); whatever order its corners come in.
    var extent: (normal: SIMD2<Double>, length: Double, across: ClosedRange<Double>)? {
        guard corners.count >= 3, simd_length(normal) > 1e-9 else { return nil }
        let n = simd_normalize(normal), along = SIMD2(-n.y, n.x)
        let out = corners.map { simd_dot($0 - centre, n) }, side = corners.map { simd_dot($0 - centre, along) }
        guard let length = out.max(), let lo = side.min(), let hi = side.max(), hi > lo else { return nil }
        return (n, length, lo...hi)
    }
}
