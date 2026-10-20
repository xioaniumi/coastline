import CoastlineCore
import Foundation
import simd

extension AppModel {
    /// When the stock, as oriented, is too tall for the clamp kit but the part fits in a
    /// smaller bar, plans the prep on the squaring stop: square it and mill one side down to a
    /// height the kit holds. Undone automatically when the stock fits again; a height the user
    /// set by hand is left alone.
    /// There's a prep on the bed (milling down, or shoulders lower than the bar).
    var hasPrep: Bool { prepTarget != nil }

    func autoPlanPrep() {
        guard part != nil, stock != nil else { return }
        let current = stockOptions().first { $0.axes == setup.stockAxes }
        // This orientation only works held by shoulders: plan them (and undo them when it
        // fits another way again, if Coastline put them there).
        if current?.viaShoulders == true, setup.shoulders == nil, !setup.onBed, let sh = shoulderProposal {
            shouldersAuto = true
            var s = setup
            s.shoulders = sh
            s.downsizeHeight = nil
            s.clampSoftJaw = false
            setup = s
            status = sh.height < setup.rawStockSize(stock!).x - 0.01
                ? "Too big for the clamp kit as a whole bar: \(Length.mm(sh.length)) mm shoulders at both ends are milled down to \(Length.mm(sh.height)) mm and the kit grips those."
                : "The kit grips the bar's two ends only, so the part can reach its top and bottom edges."
            return
        }
        if current?.viaShoulders == false, shouldersAuto, setup.shoulders != nil {
            shouldersAuto = false
            setup.shoulders = nil
            return
        }
        guard setup.shoulders == nil else {  // path D: the shoulders are the prep
            if setup.downsizeHeight != nil { setup.downsizeHeight = nil }
            // Coastline's own shoulders: lower the bar until the part's top is in reach.
            if shouldersAuto, let r = reachExcess, r.above > 0, let sh = setup.shoulders, sh.bottom < maxShoulderBottom {
                lowerForReach()
                status = "The part reached above the CR-1's travel: the shoulders' bottom comes off too (\(Length.mm(setup.shoulders?.bottom ?? 0)) mm), so the bar sits that much lower."
                return
            }
            // The shoulders fit the jaw chosen in the clamp kit: the soft jaws take shorter ones,
            // so the ends are milled deeper (Coastline's own: the tallest that grips).
            if var sh = setup.shoulders, let stock {
                let grip = UniversalClamp.onJaw(softJaw: setup.clampSoftJaw)
                let hi = min((grip.upperBound - 0.5).rounded(.down), setup.rawStockSize(stock).x - sh.bottom)
                let want = shouldersAuto ? hi : min(max(sh.height, grip.lowerBound), hi)
                if abs(want - sh.height) > 1e-9 {
                    sh.height = want
                    setup.shoulders = sh
                    status = setup.clampSoftJaw
                        ? "With the soft jaws the shoulders are \(Length.mm(want)) mm: the ends are milled deeper."
                        : "Straight in the kit the shoulders can be \(Length.mm(want)) mm: less to mill."
                    return  // setup's didSet plans again
                }
            }
            syncPrepLength()
            return
        }
        guard !setup.onBed else {  // path B: no prep, the whole job is on the bed
            if setup.downsizeHeight != nil { setup.downsizeHeight = nil }
            return
        }
        let option = stockOptions().first { $0.axes == setup.stockAxes }
        // A proper frame (strips under the jaws, a channel around the part) only fits the kit
        // without the soft jaws: take them off, with the disclaimer.
        if option?.softJawOff == true, setup.clampSoftJaw {
            setup.clampSoftJaw = false
            status = "Soft jaws off so the part gets a proper frame: " + UniversalClamp.noSoftJawDisclaimer
            return  // setup's didSet plans again
        }
        guard let target = option?.prepHeight else {
            if prepAuto {
                prepAuto = false
                if setup.downsizeHeight != nil { setup.downsizeHeight = nil }
                if viewSide == -1 { show(side: 0, stage: 0) }
            }
            syncPrepLength()
            return
        }
        guard setup.downsizeHeight == nil || prepAuto else { syncPrepLength(); return }
        if setup.downsizeHeight != target {
            prepAuto = true
            setup.downsizeHeight = target
            // Start where the job starts: the stock as bought, on the bed.
            show(side: -1, stage: -1)
            status = "The stock is too tall for the clamp kit: it's squared and milled down to \(Length.mm(target)) mm flat on the bed first."
        }
        syncPrepLength()
    }

    /// The part setup uses the bar as the prep leaves it (sawn and faced to length).
    func syncPrepLength() {
        let want = flatPrepPlan.flatMap { $0.sawLength != nil || $0.faceEnds ? $0.finalLength : nil }
        if setup.prepLength != want { setup.prepLength = want }
    }

    /// The work axis the stock's extrusion runs along, as it's oriented in the setup.
    var extrusionWorkAxis: Int? {
        guard let a = stock?.extrusionAxis else { return nil }
        return setup.stockAxes.firstIndex(of: a)
    }

    /// How long a bar the part needs (room for the roughing tool around it).
    var neededBarLength: Double? {
        guard let part, let stock else { return nil }
        let (lo, hi) = setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        let ideal = StockAdvice.idealSize(part: hi - lo, twoSided: twoSided, topAllowance: setup.topAllowance, toolDiameter: 6.35)
        let raw = setup.rawStockSize(stock)
        let alongY = extrusionWorkAxis.map { $0 == 1 } ?? (raw.y >= raw.z)
        return alongY ? ideal.y : ideal.z
    }

    /// The largest uniform scale at which the part fits the stock with a proper frame, when it
    /// doesn't fit at the current scale (nil when it does).
    var scaleToFitStock: Double? {
        guard let part, let stock else { return nil }
        var unit = setup
        unit.partScale = 1
        let (lo, hi) = unit.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        func fits(_ k: Double) -> Bool {
            StockOrientation.options(stock: stock, part: (hi - lo) * k, twoSided: twoSided, topAllowance: setup.topAllowance,
                                     softJaw: true, toolDiameter: 6.35).contains(where: \.workable)
        }
        guard !fits(setup.partScale) else { return nil }
        var a = 0.02, b = setup.partScale
        guard fits(a) else { return nil }
        for _ in 0..<30 { let m = (a + b) / 2; if fits(m) { a = m } else { b = m } }
        return (a * 200).rounded(.down) / 200  // 0.5 % steps
    }

    /// The CR-1's table and the squaring stop's face, from the machine model.
    var prepTable: FlatPrep.Table {
        var t = SideClamps.table(topX: machineModel?.tableTopX ?? -31.12, frontSlotZ: machineModel?.tSlotZ.max() ?? -13.4)
        if let r = cClampFrameAtBed { (t.clampInnerReach, t.clampHalfWidth) = r }
        return t
    }

    /// Path D's shoulders for this part and stock: as tall as the kit grips without the soft
    /// jaws (the most grip), the default length; nil when the bar is too short or too low.
    var shoulderProposal: Setup.Shoulders? {
        guard let part, let stock else { return nil }
        var s = setup
        s.downsizeHeight = nil
        s.shoulders = nil
        let raw = s.rawStockSize(stock)
        let (lo, hi) = s.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        // The kit grips only the ends: the part may reach the bar's top and bottom edges; it
        // keeps out of the jaws at the ends (CoastlineCore Shoulders.fit).
        return Shoulders.fit(raw: raw, part: hi - lo)
    }

    /// The C-clamp frame at the bed's height, measured on its mesh: the screw axis to the
    /// frame's inner face, and half its width (nil until the kit is loaded).
    var cClampFrameAtBed: (Double, Double)? {
        if let c = cClampFrameCache { return c }
        let c = measureCClampFrame()
        if c != nil { cClampFrameCache = c }
        return c
    }

    private func measureCClampFrame() -> (Double, Double)? {
        guard let frame = kitParts.first(where: { $0.kit == "cclamp" && $0.role == "frame" }) else { return nil }
        let v = frame.mesh.vertices
        var inner = Double.infinity, half = 0.0
        for i in stride(from: 0, to: v.count, by: 3) {
            // Kit x = 0 is the bed's underside (the fixed jaw under it), y away from the spindle.
            let x = Double(v[i]), y = Double(v[i + 1]), z = Double(v[i + 2])
            guard x >= 0, x <= FlatPrep.tableThickness + 0.5, y > 10 else { continue }
            inner = min(inner, y)
            half = max(half, abs(z))
        }
        return inner.isFinite ? (inner, half) : nil
    }

    /// The prep as the guided job will run it.
    func prepMillDown(tool: Tool) -> GuidedJobBuilder.MillDown? {
        guard let stock, let h = prepTarget else { return nil }
        let raw = setup.rawStockSize(stock)
        var m = GuidedJobBuilder.MillDown(raw: raw, target: h, tool: tool, neededLength: neededBarLength)
        m.table = prepTable
        m.frontSlotZ = machineModel?.tSlotZ.max() ?? -13.4
        m.extrudedAlong = extrusionWorkAxis
        m.overrides = setup.prepOverrides
        m.faceEnd = setup.prepFaceEnd
        m.rounds = setup.prepRounds
        m.shoulderLength = setup.shoulders?.length
        m.shoulderBottom = setup.shoulders?.bottom ?? 0
        return m
    }

    /// The flat squaring prep for stock too big for the clamp kit (FlatPrep).
    var flatPrepPlan: FlatPrep.Plan? {
        guard let stock, let h = prepTarget else { return nil }
        let raw = setup.rawStockSize(stock)
        return FlatPrep.plan(raw: raw, target: h, sawn: stock.finish == .sawn, neededLength: neededBarLength, table: prepTable,
                             extrudedAlong: extrusionWorkAxis, faceEnd: setup.prepFaceEnd, rounds: setup.prepRounds,
                             shoulderLength: setup.shoulders?.length, shoulderBottom: setup.shoulders?.bottom ?? 0)
    }

    /// What the bed prep leaves at its ends, measured from the bar's bottom (the mill-down
    /// height, or the shoulders' grip plus what's milled off below it), when there is a prep.
    var prepTarget: Double? {
        guard let stock else { return nil }
        let raw = setup.rawStockSize(stock)
        if let sh = setup.shoulders {
            let t = min(sh.height + sh.bottom, raw.x)
            return t < raw.x - 0.01 || sh.bottom > 0.01 ? t : nil
        }
        guard let h = setup.downsizeHeight, h < raw.x else { return nil }
        return h
    }

    /// Path D: the part's top and bottom against the CR-1's X travel (+ above, − below), mm;
    /// positive means it's out of reach by that much.
    var reachExcess: (above: Double, below: Double)? {
        guard let part, let xr = kitWorkXRange else { return nil }
        let (lo, hi) = setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        // The tool finishing the part's edge stands a radius past it (the largest cutter that
        // works the walls, + 0.5 mm): that is what must be in reach, not just the part.
        // (A 1/4" until the job's own tools are known.)
        let margin = max(programs.map { $0.tool.diameter / 2 }.max() ?? 0, 3.175) + 0.5
        let top = setup.partOffsetX + (hi.x - lo.x) / 2 + margin, bottom = setup.partOffsetX - (hi.x - lo.x) / 2 - margin
        // In the kit's own placement (whatever is on screen): work X up, the reach as the
        // tool's centre may go.
        return (top - xr.upperBound, xr.lowerBound - bottom)
    }

    /// The most the shoulders' bottom can come off: the bar's middle hangs below the jaws, and
    /// keeps 1.5 mm above the bed.
    var maxShoulderBottom: Double { (UniversalClamp.jawTopZ - 1.5).rounded(.down) }

    /// Lowers the bar (bottom shoulders) just enough for the part's top to be in reach.
    func lowerForReach() {
        guard var sh = setup.shoulders, let r = reachExcess, r.above > -0.5 else { return }
        // Down by what's out at the top (+ 0.5), never so far the bottom goes out instead.
        let room = max(-r.below - 0.5, 0)
        let down = min(((r.above + 0.5) * 2).rounded(.up) / 2, room)
        sh.bottom = min(max(sh.bottom + down, 0), maxShoulderBottom)
        setup.shoulders = sh
    }

    /// The prep stage on screen.
    var currentPrepStage: FlatPrep.Stage? { prepStage(at: prepStage) }

    func prepStage(at k: Int) -> FlatPrep.Stage? {
        guard let plan = flatPrepPlan, !plan.stages.isEmpty else { return nil }
        if k < 0 {
            // The bar as bought, lying on the bed against the stop: where the job starts.
            return FlatPrep.Stage(kind: .edge(round: 0, of: 1), title: "As bought", stock: SIMD3(plan.thickness, plan.length, plan.width),
                                  cut: 0, protrusion: FlatPrep.stopClearance + 1)
        }
        return plan.stages[min(k, plan.stages.count - 1)]
    }

    /// Where the stop, riser and C-clamps sit for a prep stage, and the bar on them, with
    /// The user's adjustments (BedEditor). The bar as bought lies where the first clamping's stop is.
    func prepPlacement(_ stage: FlatPrep.Stage) -> SideClamps.Placement {
        SideClamps.place(stage: stage, table: prepTable, frontSlotZ: machineModel?.tSlotZ.max() ?? -13.4, centreY: travelCentreY,
                         override: prepOverride(at: prepIndex(of: stage)))
    }

    /// The clamping a stage is (the bar as bought counts as the first).
    func prepIndex(of stage: FlatPrep.Stage) -> Int { flatPrepPlan?.stages.firstIndex(of: stage) ?? 0 }

    /// Model Y of the bar's centre in a prep stage (it moves with the stop).
    func prepCentreY(_ stage: FlatPrep.Stage) -> Double { travelCentreY + prepOverride(at: prepIndex(of: stage)).stopShiftY }

    /// One result per prep stage (each its own clamping, simulated on its own), and the
    /// programs, numbered from 1000 in the timeline so they never mix with the part's.
    func generatePrep(base: [EngineClient.PlannedOperation], material: Material, stock: StockItem) {
        prepPrograms = []
        prepResults = []
        guard let tool = base.map(\.tool).filter({ $0.kind == .flatEndMill }).max(by: { $0.diameter < $1.diameter }) else { return }
        generatePrep(tool: tool, material: material, stock: stock)
    }

    func generatePrep(tool: Tool, material: Material, stock: StockItem) {
        prepPrograms = []
        prepResults = []
        guard let m = prepMillDown(tool: tool) else { return }
        // The same prep (bar, steps, fixtures, tool, material) as last time: reuse its programs.
        let key = "\(m)|\(material.id)|\(stock.finish)"
        let items: [GuidedJobBuilder.MillDown.Item]
        if let c = prepProgramCache, c.key == key {
            items = c.items
        } else {
            items = m.programs(material: material, sawn: stock.finish == .sawn).items
            prepProgramCache = (key, items)
        }
        for (k, item) in items.enumerated() {
            let op = Operation(kind: item.stage.isEdge ? .adaptive : .facing, toolID: tool.id)
            let data = FeedsEngine.compute(tool: tool, material: material, kind: op.kind)
            let path = OperationToolpath(operationID: op.id, moves: item.moves)
            let posted = CR1Post.programWithLineMap(
                header: .init(programName: part?.fileName ?? "Prep", setupName: "Prep: flat on the squaring stop", tool: tool,
                              operationNames: [item.title], stockDescription: "\(material.name) \(stock.sizeDescription)"),
                rpm: data.rpm, paths: [path])
            var program = ToolProgram(index: 1000 + k, side: -1, tool: tool, operations: [op], rpm: data.rpm, gcode: posted.text,
                                      report: item.report, seconds: TimeEstimate.seconds([path]), title: item.title)
            program.clearanceHits = item.hits
            prepPrograms.append(program)
            prepResults.append(SideResult(side: -1, setup: setup, planned: [.init(operation: op, tool: tool, data: data)], paths: [path],
                                          operationProgram: [1000 + k], operationLines: posted.lines))
        }
    }
}
