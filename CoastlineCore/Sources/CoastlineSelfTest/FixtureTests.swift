import CoastlineCore
import CRCore
import Foundation
import simd

let fixtureTests: [TestCase] = [
    TestCase(name: "clampKitBoltsAcrossBothSlotsAndHoldsTheStockProud") {
        let p = UniversalClamp.place(stock: SIMD3(30, 70, 12), tableTopX: -31.2, frontSlotZ: -13.4, centreY: -112, protrusion: 2)
        try expectEqual(p.clamps.count, 2, "70 mm wide stock: a clamp near each end")
        let m = p.clamps[0]
        // The front and rear bolts sit over the two T-slots (40 mm apart); the base on the table.
        let front = m * SIMD4(UniversalClamp.frontSlotX, 0, 0, 1), rear = m * SIMD4(UniversalClamp.rearSlotX, 0, 0, 1)
        try expect(abs(front.z + 13.4) < 1e-9 && abs(rear.z + 53.4) < 1e-9 && abs(front.x + 31.2) < 1e-9, "\(front) \(rear)")
        let r = simd_double3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z), SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                               SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        try expect(abs(simd_determinant(r) - 1) < 1e-12, "a proper rotation")
        // Face 2 mm past the front of the jaws; 30 mm stock sits on the lower jaw.
        let jaws = m * SIMD4(UniversalClamp.frontX, 0, 30, 1)
        try expect(abs(p.stockFaceZ - (jaws.z + 2)) < 1e-9)
        try expectEqual(p.seat.kind, .jaw)
        try expect(abs(p.stockBottomX - (-31.2 + UniversalClamp.jawTopZ)) < 1e-9)
        try expect(abs(p.parallels - (UniversalClamp.throatDepth - 10)) < 1e-9, "parallels fill the throat behind 10 mm of stock")
        try expect(p.issues.isEmpty, "\(p.issues.map(\.message))")
        try expectEqual(UniversalClamp.place(stock: SIMD3(30, 35, 12), tableTopX: 0, frontSlotZ: 0, centreY: 0, protrusion: 2).clamps.count, 1)
    },
    TestCase(name: "smallStockSuggestsOneClampAndUserCanOverride") {
        let small = UniversalClamp.place(stock: SIMD3(30, 55, 12), tableTopX: 0, frontSlotZ: 0, centreY: 0, protrusion: 2)
        try expectEqual(small.clamps.count, 1, "55 mm stock fits one clamp")
        try expect(small.issues.isEmpty, "\(small.issues.map(\.message))")
        let two = UniversalClamp.place(stock: SIMD3(30, 55, 12), tableTopX: 0, frontSlotZ: 0, centreY: 0, protrusion: 2, count: 2)
        try expectEqual(two.clamps.count, 2)
        // Too narrow for two jaws side by side: one, and a note why.
        let narrow = UniversalClamp.place(stock: SIMD3(30, 35, 12), tableTopX: 0, frontSlotZ: 0, centreY: 0, protrusion: 2, count: 2)
        try expect(narrow.clamps.count == 1 && narrow.issues.contains { $0.severity == .info }, "\(narrow.issues.map(\.message))")
        // One clamp on long stock is allowed, with a warning.
        let long = UniversalClamp.place(stock: SIMD3(30, 120, 12), tableTopX: 0, frontSlotZ: 0, centreY: 0, protrusion: 2, count: 1)
        try expect(long.clamps.count == 1 && long.issues.contains { $0.severity == .warning && $0.message.contains("ring") })
        var setup = Setup()
        setup.kitClampCount = 1
        try expectEqual(try JSONDecoder().decode(Setup.self, from: JSONEncoder().encode(setup)).kitClampCount, 1)
    },
    TestCase(name: "clampKitSeatsFollowTheMeasuredJawTravel") {
        // Measured from the clamp model: the soft jaw's underside runs 42.07…59.04 mm, the jaw at 18.45.
        try expect(abs(UniversalClamp.onJaw.lowerBound - 23.62) < 0.01 && abs(UniversalClamp.onJaw.upperBound - 40.59) < 0.01)
        try expect(abs(UniversalClamp.onSpacer.upperBound - 16.39) < 0.01)
        try expectEqual(UniversalClamp.seat(stockHeight: 30).kind, .jaw)
        try expectEqual(UniversalClamp.seat(stockHeight: 10).kind, .spacer)
        let mid = UniversalClamp.seat(stockHeight: 20)
        try expect(mid.kind == .parallel && 20 + mid.parallel >= UniversalClamp.onJaw.lowerBound, "\(mid)")
        try expectEqual(UniversalClamp.seat(stockHeight: 80).kind, .tooTall)
        let tall = UniversalClamp.place(stock: SIMD3(80, 150, 20), tableTopX: -31.2, frontSlotZ: -13.4, centreY: 0, protrusion: 2)
        try expect(tall.issues.contains { $0.severity == .error && $0.message.contains("mill it down") })
        let thin = UniversalClamp.place(stock: SIMD3(30, 35, 3), tableTopX: -31.2, frontSlotZ: -13.4, centreY: 0, protrusion: 2)
        try expect(thin.issues.contains { $0.severity == .warning }, "3 mm stock barely held")
    },
    TestCase(name: "withoutSoftJawsTheScrewsHoldTallerStockWithANote") {
        // Screw tips travel 47.22…65.44 mm above the bed; the jaw is at 18.45.
        let j = UniversalClamp.onJaw(softJaw: false)
        try expect(abs(j.lowerBound - 28.77) < 0.01 && abs(j.upperBound - 46.99) < 0.01, "\(j)")
        try expectEqual(UniversalClamp.seat(stockHeight: 45, softJaw: true).kind, .tooTall)
        try expectEqual(UniversalClamp.seat(stockHeight: 45, softJaw: false).kind, .jaw)
        let p = UniversalClamp.place(stock: SIMD3(45, 60, 12), tableTopX: -31.2, frontSlotZ: -13.4, centreY: 0, protrusion: 2, softJaw: false)
        // Said once, as information: it is a choice (taller stock), not a problem to fix.
        try expect(p.issues.contains { $0.severity == .info && $0.message.contains("less clamping force") })
        try expect(!p.issues.contains { $0.severity == .error })
    },
    TestCase(name: "stockAdviceTurnsBuysOrMillsDown") {
        // 150 × 80 × 20 stock for a 30 mm disc 5 mm thick: no orientation fits (80 and 150 are too
        // tall for the kit, 20 is shorter than the disc). A 120 × 40 × 10 bar fits with 40 standing up.
        let part = SIMD3(30.0, 30, 5)
        try expect(StockAdvice.turnToFit(stock: StockItem(materialID: "al-6061", sizeX: 150, sizeY: 80, sizeZ: 20),
                                         part: part, margin: 9.35, depth: 6.5) == nil)
        let bar = StockItem(materialID: "al-6061", sizeX: 120, sizeY: 40, sizeZ: 10)
        let axes = try unwrap(StockAdvice.turnToFit(stock: bar, part: part, margin: 9.35, depth: 6.5))
        let e = [120.0, 40, 10]
        try expect(e[axes[0]] == 40 && e[axes[1]] == 120 && e[axes[2]] == 10, "\(axes)")
        // Room for a 1/4" tool around a 30 mm part needs ~49 mm: too tall for the kit; 20 mm tall fits.
        try expectEqual(UniversalClamp.seat(stockHeight: StockAdvice.idealSize(part: part, twoSided: true, topAllowance: 0.5, toolDiameter: 6.35).x).kind, .tooTall)
        let ideal = StockAdvice.idealSize(part: SIMD3(20, 30, 5), twoSided: true, topAllowance: 0.5, toolDiameter: 6.35)
        try expect(UniversalClamp.seat(stockHeight: ideal.x).kind == .jaw && ideal.y >= 48 && ideal.z >= 7, "\(ideal)")
        let est = StockAdvice.downsize(stock: SIMD3(80, 150, 20), target: 40, tool: Tool(name: "1/4", kind: .flatEndMill, diameter: 6.35,
                                       shankDiameter: 6.35, flutes: 3, fluteLength: 19, stickout: 28, overallLength: 63.5),
                                       material: MaterialLibrary.material(id: "al-6061"))
        try expect(abs(est.volume - 40 * 150 * 20) < 1e-6 && (est.minutes ?? 0) > 10, "\(est)")
    },
    TestCase(name: "flatPrepFacesSawnEndsThenMillsTheEdgeInRounds") {
        let al = MaterialLibrary.material(id: "al-6061")!
        let tool = Tool(name: "1/4\" flat end mill", kind: .flatEndMill, diameter: 6.35, shankDiameter: 6.35, flutes: 3,
                        fluteLength: 19, stickout: 28, overallLength: 63.5)
        // 85 × 63.5 × 25.4 bar (the kit's blank), sawn, the part needs 60 mm of it: too long to
        // face on the table, so it's sawn to 63 mm (60 + facing + a saw cut's roughness), both ends faced, then 23.5 mm off the edge in
        // two rounds.
        var m = GuidedJobBuilder.MillDown(raw: SIMD3(63.5, 85, 25.4), target: 40, tool: tool, neededLength: 60)
        let (plan, items) = m.programs(material: al, sawn: true)
        // Coast Runner's way: one end faced, the bar keeps its length.
        try expectEqual(plan.sawLength, nil)
        try expect(plan.faceEnds && abs(plan.cut - 23.5) < 1e-9 && plan.thickness == 25.4 && plan.finalLength == 84.5, "\(plan)")
        try expectEqual(items.map(\.title), ["Face end A", "Edge, round 1 of 2 (to 51.75 mm)", "Edge, round 2 of 2 (to 40 mm)"])
        for it in items { try expect(it.report.passed, "\(it.title): \(it.report.issues.map(\.message))") }
        let edge = items[1]
        let cuts = edge.moves.filter { $0.role == .cut }
        try expect(abs(cuts.map(\.z).min()! + 11.75) < 1e-9, "round depth")
        // Faced in shallow layers (≤ ¼ D) across the whole edge, layer by layer: no fins.
        let levels = Array(Set(cuts.map(\.z))).sorted(by: >)
        try expect(zip([0] + levels, levels).allSatisfy { $0 - $1 <= 0.25 * 6.35 + 1e-9 }, "layers \(levels)")
        try expect(zip(cuts, cuts.dropFirst()).allSatisfy { $1.z <= $0.z + 1e-9 }, "each layer finished before the next")
        try expect(cuts.map(\.x).min()! < -25.4 / 2 && cuts.map(\.x).max()! > 25.4 / 2, "covers the whole edge")
        // The face sticks out past the stop by the cut + clearance; the stop and riser stay behind.
        try expect(abs(edge.placement.stockFaceZ - (m.table.stopNorthZ + 11.75 + FlatPrep.stopClearance)) < 1e-9)
        try expect(edge.placement.riserMax.z < m.table.stopNorthZ)
        // Nothing the clamps are made of overlaps the bar, and every screw presses on it.
        for it in items {
            let p = it.placement, s = it.stage.stock
            let barMin = SIMD3(p.stockBottomX, -s.y / 2, p.stockFaceZ - s.z), barMax = SIMD3(p.stockBottomX + s.x, s.y / 2, p.stockFaceZ)
            for solid in SideClamps.solids(p, table: m.table, centreY: 0) where solid.name != "C-clamp pad" {
                let overlap = solid.max.x > barMin.x + 1e-6 && solid.min.x < barMax.x - 1e-6 && solid.max.y > barMin.y + 1e-6
                    && solid.min.y < barMax.y - 1e-6 && solid.max.z > barMin.z + 1e-6 && solid.min.z < barMax.z - 1e-6
                try expect(!overlap, "\(it.title): \(solid.name) overlaps the bar")
            }
            for c in p.clampPoints {
                if p.clampAngles.contains(where: { $0 != 0 }) {  // angled: pads on the bar near its sides
                    try expect(abs(c.x - barMax.x) < 1e-9 && abs(c.y) < s.y / 2 && c.z > barMin.z + 6 && c.z < barMax.z, "\(it.title) angled pad \(c)")
                } else {
                    try expect(c.z > barMin.z + 6 && c.z < barMax.z - 6 && abs(c.x - barMax.x) < 1e-9, "\(it.title) pad \(c)")
                }
            }
        }
        // A 150 mm bar: no sawing; its end is faced with the bar reaching past the bed's
        // back edge, held by a parallel across it.
        m = GuidedJobBuilder.MillDown(raw: SIMD3(80, 150, 20), target: 40, tool: tool, neededLength: 50)
        let (long, longItems) = m.programs(material: al, sawn: true)
        try expect(long.faceEnds && long.sawLength == nil && long.finalLength == 149.5, "\(long)")
        try expect(longItems[0].placement.clampAngles.allSatisfy { abs(abs($0) - .pi / 4) < 1e-9 }, "end A: clamps turned 45°")
        for it in longItems { try expect(it.report.passed, "\(it.title): \(it.report.issues.map(\.message))") }
    },
    TestCase(name: "fixtureClearanceCatchesACutIntoTheStop") {
        let al = MaterialLibrary.material(id: "al-6061")!
        let tool = Tool(name: "1/4\" flat end mill", kind: .flatEndMill, diameter: 6.35, shankDiameter: 6.35, flutes: 3,
                        fluteLength: 19, stickout: 28, overallLength: 63.5)
        let table = SideClamps.table(topX: -31, frontSlotZ: -13.4)
        // The bar sticks out only 3 mm but the program cuts 10 mm deep along its whole length:
        // the cutter runs through the stop at the bar's end.
        let stage = FlatPrep.Stage(kind: .edge(round: 0, of: 1), title: "Bad", stock: SIMD3(20, 60, 40), cut: 10, protrusion: 3)
        let p = SideClamps.place(stage: stage, table: table, frontSlotZ: -13.4, centreY: 0)
        let moves = FlatPrep.programs(FlatPrep.Plan(thickness: 20, length: 60, width: 40, cut: 10, target: 30, sawLength: nil, faceEnds: false,
                                                    finalLength: 60, stages: [stage], issues: []), tool: tool, material: al)[0].moves
        let hits = GuidedJobBuilder.MillDown.clearance(moves, stage: stage, placement: p, table: table, tool: tool)
        try expect(!hits.isEmpty && hits.contains { $0.position.y < -30 }, "\(hits.prefix(3))")
        // With the right protrusion it's clear.
        var good = stage
        good.protrusion = 10 + FlatPrep.stopClearance
        let q = SideClamps.place(stage: good, table: table, frontSlotZ: -13.4, centreY: 0)
        try expect(GuidedJobBuilder.MillDown.clearance(moves, stage: good, placement: q, table: table, tool: tool).isEmpty)
        // The collet nut counts too: a short stick-out reaching 10 mm deep beside a tall clamp.
        var field = FixtureField(triangles: FixtureField.boxTriangles(min: SIMD3(6, -5, -30), max: SIMD3(30, 5, 5)),
                                 regionMin: SIMD2(-40, -40), regionMax: SIMD2(40, 40))
        var short = tool
        short.stickout = 12
        let nut = FixtureClearance.check([Move(.cut, x: 0, y: 0, z: 3), Move(.cut, x: 0, y: 0, z: -10)], tool: short, field: &field)
        try expect(nut.first?.part == "collet nut", "\(nut)")
    },
    TestCase(name: "bedFixtureAdjustmentsMoveTheClampsAndAreChecked") {
        let table = SideClamps.table(topX: -31, frontSlotZ: -13.4)
        // A bar deep enough for the C-clamps to reach onto (their frame allows ~32 mm at the bed).
        let stage = FlatPrep.Stage(kind: .edge(round: 0, of: 1), title: "Edge", stock: SIMD3(20, 100, 70), cut: 8, protrusion: 10)
        let base = SideClamps.place(stage: stage, table: table, frontSlotZ: -13.4, centreY: 0)
        // No adjustments: the proposal, and it passes its own checks.
        let same = SideClamps.place(stage: stage, table: table, frontSlotZ: -13.4, centreY: 0, override: PrepOverride())
        try expectEqual(same.clampPoints, base.clampPoints)
        try expect(!same.issues.contains { $0.severity == .warning }, "\(same.issues.map(\.message))")
        // The stop slides along the slots and takes the bar and the clamps with it.
        var o = PrepOverride()
        o.stopShiftY = 20
        o.clamps = [ClampOverride(dy: 5, dz: -3, angle: 0.3), ClampOverride()]
        let moved = SideClamps.place(stage: stage, table: table, frontSlotZ: -13.4, centreY: 0, override: o)
        try expect(abs(moved.brick.columns.3.y - base.brick.columns.3.y - 20) < 1e-9, "stop moved")
        try expect(simd_distance(moved.clampPoints[0], base.clampPoints[0] + SIMD3(0, 25, -3)) < 1e-9, "\(moved.clampPoints[0])")
        try expect(abs(moved.clampAngles[0] - 0.3) < 1e-12 && moved.clampAngles[1] == base.clampAngles[1])
        try expect(!moved.issues.contains { $0.severity == .warning }, "\(moved.issues.map(\.message))")
        // A pad pulled into the cut, off the bar, or a frame that can't reach round the bed are flagged.
        o.clamps[0] = ClampOverride(dz: 40)
        let cut = SideClamps.place(stage: stage, table: table, frontSlotZ: -13.4, centreY: 0, override: o)
        try expect(cut.issues.contains { $0.message.contains("where the cutter goes") }, "\(cut.issues.map(\.message))")
        try expect(cut.issues.contains { $0.message.contains("back edge") })
        o.clamps[0] = ClampOverride(dy: 80)
        try expect(SideClamps.place(stage: stage, table: table, frontSlotZ: -13.4, centreY: 0, override: o).issues.contains { $0.message.contains("off the bar") })
        // The adjustments survive a save.
        var setup = Setup()
        setup.prepOverrides = [o]
        setup.onBed = true
        let back = try JSONDecoder().decode(Setup.self, from: JSONEncoder().encode(setup))
        try expectEqual(back.prepOverrides, [o])
        try expect(back.onBed)
        try expect(try JSONDecoder().decode(Setup.self, from: Data("{}".utf8)).prepOverrides.isEmpty, "older files still open")
    },
    TestCase(name: "collisionEngineTellsTouchingFromColliding") {
        let table = Collision.Body.box(name: "Bed", min: SIMD3(-14.7, -100, -65), max: SIMD3(0, 100, 0))
        // Resting on the bed, or beside it: touching, not colliding.
        let onTop = Collision.Body.box(name: "Stop", min: SIMD3(0, -10, -20), max: SIMD3(15, 10, -5))
        let behind = Collision.Body.box(name: "Spine", min: SIMD3(-30, -5, -75), max: SIMD3(20, 5, -65))
        try expect(Collision.check([table, onTop, behind]).isEmpty, "\(Collision.check([table, onTop, behind]))")
        // A clamp frame arm 2 mm into the bed's back edge: found, about 2 mm deep, where it is.
        let arm = Collision.Body.box(name: "Arm", min: SIMD3(-30, -5, -77), max: SIMD3(20, 5, -63))
        let hits = Collision.check([table, arm])
        try expectEqual(hits.count, 1)
        try expect(abs(hits[0].depth - 2) < 0.3 && hits[0].point.z > -65.5 && hits[0].point.z < -62.5, "\(hits)")
        // A thin bar right through a plate (no corner of either inside the other) is found too.
        let rod = Collision.Body.box(name: "Rod", min: SIMD3(-40, -1, -31), max: SIMD3(40, 1, -29))
        try expectEqual(Collision.check([table, rod]).map(\.b), ["Rod"])
        // Parts of one assembly don't count against each other.
        let screw = Collision.Body.box(name: "Screw", group: "Arm", min: SIMD3(-50, -2, -70), max: SIMD3(50, 2, -68))
        try expect(!Collision.check([arm, screw]).contains { $0.a == "Arm" && $0.b == "Screw" })
        // A real mesh: a tessellated cylinder pressed 1 mm into the bed, and one standing on it.
        func cylinder(_ x0: Double, _ x1: Double) -> [SIMD3<Double>] {
            var t: [SIMD3<Double>] = []
            let n = 48
            for k in 0..<n {
                let a = Double(k) / Double(n) * 2 * .pi, b = Double(k + 1) / Double(n) * 2 * .pi
                let p = SIMD3(0, 6 * cos(a), -30 + 6 * sin(a)), q = SIMD3(0, 6 * cos(b), -30 + 6 * sin(b))
                t += [SIMD3(x0, p.y, p.z), SIMD3(x1, p.y, p.z), SIMD3(x1, q.y, q.z), SIMD3(x0, p.y, p.z), SIMD3(x1, q.y, q.z), SIMD3(x0, q.y, q.z)]
                t += [SIMD3(x0, 0, -30), SIMD3(x0, q.y, q.z), SIMD3(x0, p.y, p.z), SIMD3(x1, 0, -30), SIMD3(x1, p.y, p.z), SIMD3(x1, q.y, q.z)]
            }
            return t
        }
        let pressed = Collision.check([table, Collision.Body(name: "Pad", triangles: cylinder(-1, 10))])
        try expect(pressed.count == 1 && abs(pressed[0].depth - 1) < 0.2, "\(pressed)")
        try expect(Collision.check([table, Collision.Body(name: "Foot", triangles: cylinder(0, 10))]).isEmpty)
    },
    TestCase(name: "shouldersMillOnlyTheEndsAndTheKitGripsThem") {
        let al = MaterialLibrary.material(id: "al-6061")!
        let tool = Tool(name: "1/4\" flat end mill", kind: .flatEndMill, diameter: 6.35, shankDiameter: 6.35, flutes: 3,
                        fluteLength: 19, stickout: 28, overallLength: 63.5)
        // 80 mm tall bar, 150 long: shoulders 24 mm long down to 46.5 mm.
        var m = GuidedJobBuilder.MillDown(raw: SIMD3(80, 150, 20), target: 46.5, tool: tool)
        m.shoulderLength = 24
        let (plan, items) = m.programs(material: al, sawn: true)
        let edges = items.filter { $0.stage.isEdge }
        try expect(!edges.isEmpty && edges.allSatisfy { $0.title.hasPrefix("Shoulders") || $0.title.hasPrefix("Mill the shoulders") }, "\(items.map(\.title))")
        for it in edges {
            let L = it.stage.stock.y, r = tool.diameter / 2
            let cuts = it.moves.filter { $0.role == .cut || $0.role == .link }.filter { $0.z < 0 }
            // Never in the middle: the tool's edge stays out of the full-height part.
            try expect(cuts.allSatisfy { abs($0.y) >= L / 2 - 24 + r - 1e-6 }, "\(it.title) cuts into the middle")
            // Both ends are cut, and every layer starts outside the bar (no plunge into it).
            try expect(cuts.contains { $0.y < 0 } && cuts.contains { $0.y > 0 })
            for p in it.moves where p.role == .plunge { try expect(abs(p.y) > L / 2 + r - 1e-6, "plunge at y \(p.y)") }
            try expect(it.report.passed, "\(it.report.issues.map(\.message))")
        }
        try expect(plan.cut > 33 && plan.cut < 34)
        // The stepped stock: full bar minus two corners (volume), and a closed solid.
        var setup = Setup()
        setup.shoulders = .init(height: 46.5, length: 24)
        let s = SIMD3(80.0, 150.0, 20.0)
        let tris = setup.stockTriangles(stockSize: s)
        var vol = 0.0
        for k in stride(from: 0, to: tris.count, by: 3) { vol += simd_dot(tris[k], simd_cross(tris[k + 1], tris[k + 2])) / 6 }
        let want = 80 * 150 * 20 - 2 * (80 - 46.5) * 24 * 20
        try expect(abs(abs(vol) - want) < 1e-6, "volume \(vol) vs \(want)")
        try expect(vol > 0, "outward normals")
        try expectEqual(setup.shoulderCuts(stockSize: s).count, 2)
        // Saved and read back; older files have none.
        let back = try JSONDecoder().decode(Setup.self, from: JSONEncoder().encode(setup))
        try expectEqual(back.shoulders, setup.shoulders)
        try expectEqual(back.prepHeight, 46.5)
    },
    TestCase(name: "universalClampsSlideAlongTheSlotsAndMustGrip") {
        let base = UniversalClamp.place(stock: SIMD3(30, 100, 12), tableTopX: -31.12, frontSlotZ: -13.4, centreY: 0, protrusion: 2)
        let moved = UniversalClamp.place(stock: SIMD3(30, 100, 12), tableTopX: -31.12, frontSlotZ: -13.4, centreY: 0, protrusion: 2, shifts: [10, -5])
        try expect(abs(moved.clamps[0].columns.3.y - base.clamps[0].columns.3.y - 10) < 1e-9)
        try expect(abs(moved.clamps[1].columns.3.y - base.clamps[1].columns.3.y + 5) < 1e-9)
        try expect(!moved.issues.contains { $0.message.contains("Universal clamp") }, "\(moved.issues.map(\.message))")
        // Slid off the end: half a jaw is a warning, missing the stock is an error.
        let half = UniversalClamp.place(stock: SIMD3(30, 100, 12), tableTopX: -31.12, frontSlotZ: -13.4, centreY: 0, protrusion: 2, shifts: [-12])
        try expect(half.issues.contains { $0.severity == .warning && $0.message.contains("Universal clamp 1 only grips") }, "\(half.issues.map(\.message))")
        let off = UniversalClamp.place(stock: SIMD3(30, 100, 12), tableTopX: -31.12, frontSlotZ: -13.4, centreY: 0, protrusion: 2, shifts: [-30])
        try expect(off.issues.contains { $0.severity == .error && $0.message.contains("misses the stock") })
    },
    TestCase(name: "prepStepsCanBeChosenByHand") {
        let auto = FlatPrep.plan(raw: SIMD3(63.5, 85, 25.4), target: 40, sawn: true, neededLength: 60)
        try expect(auto.faceEnds && auto.rounds == 2, "\(auto)")
        let mine = FlatPrep.plan(raw: SIMD3(63.5, 85, 25.4), target: 40, sawn: true, neededLength: 60, faceEnd: false, rounds: 3)
        try expect(!mine.faceEnds && mine.rounds == 3 && !mine.stages.contains { !$0.isEdge }, "\(mine.stages.map(\.title))")
        try expect(!mine.issues.contains { $0.severity == .warning }, "more rounds are fine")
        let greedy = FlatPrep.plan(raw: SIMD3(63.5, 85, 25.4), target: 40, sawn: true, neededLength: 60, rounds: 1)
        try expect(greedy.issues.contains { $0.message.contains("overhanging") }, "one round leaves too much overhang: \(greedy.issues.map(\.message))")
    },
    TestCase(name: "oversizedSawnStockIsSquaredAndSizedFlatOnTheStops") {
        let al = MaterialLibrary.material(id: "al-6061")!
        let tool = Tool(name: "1/4\" flat end mill", kind: .flatEndMill, diameter: 6.35, shankDiameter: 6.35, flutes: 3,
                        fluteLength: 19, stickout: 28, overallLength: 63.5)
        let stock = StockItem(materialID: "al-6061", sizeX: 85, sizeY: 63.5, sizeZ: 25.4)
        let g = FacingProgram.make(width: 38, length: 85, depth: 0.25, tool: tool, data: FeedsEngine.compute(tool: tool, material: al, kind: .facing),
                                   machine: .cr1, title: "T")
        var input = GuidedJobBuilder.Input(partName: "Pendant", material: al, stock: stock, stockSize: SIMD3(40, 84, 25.4),
                                           setupName: "Setup 1", programs: [.init(tool: tool, gcode: g, operationNames: ["Facing"], minutes: 3)],
                                           checkpoints: [], measuring: [], setupImage: nil, squareStockFirst: true)
        input.millDown = .init(raw: SIMD3(63.5, 85, 25.4), target: 40, tool: tool, neededLength: 60)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coastline-\(UUID()).crproj")
        defer { try? FileManager.default.removeItem(at: url) }
        try GuidedJobBuilder.write(input, to: url)
        let project = try CRProject.open(url: url)
        try project.verify()
        try expectEqual(project.jobs.map(\.title), ["Square and Size the Stock", "Setup 1 · Pendant"])
        let steps = project.jobs[0].steps.map(\.title)
        for t in ["Install the Squaring Stop", "Mount · Face end A", "Face end A", "Ready for the Clamp Kit"] {
            try expect(steps.contains(t), "missing \(t): \(steps)")
        }
        let edges = steps.filter { $0.hasPrefix("Edge, round") || $0.hasPrefix("Mill the edge") }
        try expect(edges.count == 2 && steps.firstIndex(of: "Face end A")! < steps.firstIndex(of: edges[0])!, "\(steps)")
        try expect(!steps.contains("Saw to Length") && !steps.contains { $0.hasPrefix("Face end B") }, "\(steps)")
        // Every clamping is followed by edge finding and a touch-off.
        let mounts = steps.filter { $0.hasPrefix("Mount · ") }.count
        try expectEqual(mounts, 3)
        try expectEqual(steps.filter { $0 == "Fit the Edge Finder" }.count, mounts)
        try expectEqual(steps.filter { $0.hasPrefix("Touch Off · ") }.count, mounts)
        // By hand on the bed (nothing insulated); after the first clamping the CR-1 brings the
        // finder near each of the four edges.
        try expect(steps.contains("Finding the Stock on the Bed"), "\(steps)")
        try expectEqual(steps.filter { $0.hasPrefix("Move Near the ") }.count, 4 * (mounts - 1))
        try expectEqual(steps.filter { $0 == "Tool Change Position" }.count, 2 * mounts)
    },
    TestCase(name: "clampingStockIsNeverCut") {
        // A pass across the whole 40 mm tall face at −2 mm: the 3 mm strips along the clamped
        // edges (and the tool's radius + margin) are hopped over at the safe height.
        let tool = Tool(name: "1/8", kind: .flatEndMill, diameter: 3.175, shankDiameter: 3.175, flutes: 2,
                        fluteLength: 9.5, stickout: 20, overallLength: 38)
        let strips = GripZones.strips(stock: SIMD3(40, 60, 10))
        let path = [Move(.rapid, x: -25, y: 0, z: 3), Move(.cut, x: -25, y: 0, z: -2, feed: 300), Move(.cut, x: 25, y: 0, z: -2, feed: 600)]
        let (out, skipped) = GripZones.clip(path, tool: tool, strips: strips, below: -0.05, plungeFeed: 100)
        let cutting = out.filter { $0.role != .rapid && $0.z < -0.05 }
        let reach = 20 - GripZones.grip - tool.diameter / 2 - 0.5
        try expect(cutting.allSatisfy { abs($0.x) <= reach + 0.26 }, "\(cutting.map(\.x).max() ?? 0)")
        try expect(cutting.contains { $0.x > reach - 0.5 } && cutting.contains { $0.x < -reach + 0.5 }, "cuts up to the strips")
        try expect(skipped > 2 * (5 + GripZones.grip + tool.diameter / 2) - 1, "skipped \(skipped)")
        try expect(out.contains { $0.role == .rapid && $0.z >= 3 }, "lifts over")
        // Above the face nothing is clipped.
        try expectEqual(GripZones.clip([Move(.cut, x: -25, y: 0, z: 1), Move(.cut, x: 25, y: 0, z: 1)], tool: tool, strips: strips,
                                       below: -0.05, plungeFeed: 100).skipped, 0)
    },
    TestCase(name: "tabSuggestionsFollowTheMaterialAndSize") {
        let wax = MaterialLibrary.all.first { $0.family == .wax }
        let steel = MaterialLibrary.all.first { $0.family == .steel }
        let w = HoldingTabs.suggested(material: wax, partSize: SIMD3(30, 30, 5))
        let s = HoldingTabs.suggested(material: steel, partSize: SIMD3(80, 30, 5))
        try expect(w.width > s.width && w.height > s.height, "soft material: bigger tabs")
        try expectEqual(w.count, 4)  // two mirrored pairs
        try expectEqual(s.count, 4)
        try expectEqual(HoldingTabs.suggested(material: steel, partSize: SIMD3(150, 40, 5)).count, 6)
    },
    TestCase(name: "guidedJobFlipsReclampsAndCutsTheTabs") {
        let al = MaterialLibrary.material(id: "al-6061")!
        let tool = Tool(name: "1/8\" flat end mill", kind: .flatEndMill, diameter: 3.175, shankDiameter: 3.175, flutes: 2,
                        fluteLength: 9.5, stickout: 20, overallLength: 38)
        let stock = StockItem(materialID: "al-6061", sizeX: 40, sizeY: 60, sizeZ: 10)
        let data = FeedsEngine.compute(tool: tool, material: al, kind: .facing)
        let g = FacingProgram.make(width: 40, length: 60, depth: 0.25, tool: tool, data: data, machine: .cr1, title: "T")
        var input = GuidedJobBuilder.Input(
            partName: "Pendant", material: al, stock: stock, stockSize: SIMD3(40, 60, 10), setupName: "Setup 1",
            programs: [.init(tool: tool, gcode: g, operationNames: ["Facing"], minutes: 3, side: 0),
                       .init(tool: tool, gcode: g, operationNames: ["Contour"], minutes: 3, side: 1)],
            checkpoints: [], measuring: [], setupImage: nil, squareStockFirst: false)
        input.clampCount = 2
        input.parallels = 18
        input.tabs = HoldingTabs(count: 3, width: 2, height: 0.8)
        input.flipImage = Data([0x89, 0x50, 0x4E, 0x47])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coastline-\(UUID()).crproj")
        defer { try? FileManager.default.removeItem(at: url) }
        try GuidedJobBuilder.write(input, to: url)
        let project = try CRProject.open(url: url)
        try project.verify()
        let steps = project.jobs[0].steps
        let mount = try unwrap(steps.first { $0.title == "Mount the Stock" })
        try expect(mount.markdown.contains("rear T-slot") && mount.markdown.contains("parallels"), mount.markdown)
        let flip = try unwrap(steps.firstIndex { $0.title == "Flip the Stock" })
        try expect(steps[flip].markdown.contains("front-to-back") && steps[flip].imagePath == "Image/flip.png")
        try expectEqual(steps[flip + 1].title, "Tool Change Position")
        try expectEqual(steps[flip + 2].title, "Fit the Edge Finder")
        // The 12 and 17 mm wrenches, the collet for the shank, the stick-out.
        try expect(steps[flip + 2].markdown.contains("12 mm wrench") && steps[flip + 2].markdown.contains("17 mm wrench"), steps[flip + 2].markdown)
        // Side B sits where side A did: the CR-1 drives the finder near each edge.
        let near = try unwrap(steps.first { $0.title == "Move Near the Left Edge (Y)" })
        let nearCode = String(decoding: try unwrap(GuidedJobBuilder.build(input).files[near.gcodePath]), as: UTF8.self)
        try expect(nearCode.contains("G53 G0 Z-1") && nearCode.contains("G54 G0 X0 Y-") && nearCode.split(separator: "\n").allSatisfy { $0.count <= 79 }, nearCode)
        // The first clamping is found by hand only.
        try expect(steps.firstIndex { $0.title.hasPrefix("Move Near") }! > flip)
        let done = try unwrap(steps.last)
        try expect(done.markdown.contains("3 small tabs") && done.markdown.contains("saw"), done.markdown)
    },
]
