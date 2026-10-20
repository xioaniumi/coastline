import CoastlineCore
import Foundation

let triageTests: [TestCase] = [
    TestCase(name: "tooBigNotesAreQuietWhenASmallerToolFollows") {
        func tool(_ d: Double) -> Tool {
            Tool(name: "\(d) flat", kind: .flatEndMill, diameter: d, shankDiameter: 3.175, flutes: 2,
                 fluteLength: 6, stickout: 15, overallLength: 38)
        }
        let al = MaterialLibrary.material(id: "al-6061")!
        func planned(_ kind: OperationKind, _ t: Tool) -> EngineClient.PlannedOperation {
            let op = Operation(kind: kind, toolID: t.id)
            return .init(operation: op, tool: t, data: op.cuttingData(tool: t, material: al))
        }
        let narrow = "58 pockets too narrow to rough with this 3.175 mm tool were left for a smaller one."
        let other = "This strategy found nothing to cut on this part."
        // A 1/16" pocket pass follows the 1/8": the 1/8"'s note is handled.
        let plan = [planned(.adaptive, tool(3.175)), planned(.adaptive, tool(1.5875))]
        let (w, n) = WarningTriage.split([narrow, other], at: 0, in: plan)
        try expectEqual(w, [other])
        try expectEqual(n, [narrow])
        // The last (smallest) tool: nothing smaller follows, so it stays a warning.
        try expectEqual(WarningTriage.split([narrow], at: 1, in: plan).warnings, [narrow])
        // A bigger tool later doesn't help.
        let up = [planned(.adaptive, tool(1.5875)), planned(.adaptive, tool(3.175))]
        try expectEqual(WarningTriage.split([narrow], at: 0, in: up).warnings, [narrow])
    },
]

let prepGeometryTests: [TestCase] = [
    TestCase(name: "prepStepsCutWhatTheyShouldAndAddUp") {
        // The wallet bar: 80 tall, 170 long, 20 thick; shoulders 24 mm long, 46 mm high, 7 mm
        // off the bottom (so 27 mm off the top at each end).
        let ls = 24.0
        let plan = FlatPrep.plan(raw: SIMD3(80, 170, 20), target: 53, sawn: true, shoulderLength: ls, shoulderBottom: 7)
        func vol(_ b: [FlatPrep.Plan.BarBox]) -> Double {
            b.reduce(0) { $0 + ($1.u.upperBound - $1.u.lowerBound) * ($1.v.upperBound - $1.v.lowerBound) } * plan.thickness
        }
        let full = vol(plan.barMaterial(before: -1, shoulderLength: ls))
        try expect(abs(full - 80 * 170 * 20) < 1e-6, "as bought \(full)")
        let cuts = plan.stages.indices.reduce(0.0) { $0 + vol(plan.barCut($1, shoulderLength: ls)) }
        let expected = 0.5 * 80 * 20 + 2 * ls * 27 * 20 + 2 * ls * 7 * 20
        try expect(abs(cuts - expected) < 1e-6, "cuts \(cuts) vs \(expected)")
        let after = vol(plan.barMaterial(before: plan.stages.count, shoulderLength: ls))
        try expect(abs(after - (full - cuts)) < 1e-6, "left \(after)")
        // Each edge step's cut sits right at its face (Z from −cut to 0) and inside the bar.
        for k in plan.stages.indices where plan.stages[k].isEdge {
            let c = plan.frameBoxes(plan.barCut(k, shoulderLength: ls), stage: k)
            try expect(c.allSatisfy { abs($0.max.z) < 1e-9 && abs($0.min.z + plan.stages[k].cut) < 1e-9 }, "step \(k): \(c)")
            let m = plan.frameBoxes(plan.barMaterial(before: k, shoulderLength: ls), stage: k)
            try expect(m.allSatisfy { $0.min.y >= -plan.length / 2 - 1e-9 && $0.max.y <= plan.length / 2 + 1e-9 })
        }
    },
]
