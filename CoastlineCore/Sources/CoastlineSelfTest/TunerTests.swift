import CoastlineCore
import Foundation

private let quarter = Tool(name: "1/4 flat", kind: .flatEndMill, diameter: 6.35, shankDiameter: 6.35, flutes: 3,
                           fluteLength: 12.7, stickout: 28.575, overallLength: 50.8)

let tunerTests: [TestCase] = [
    TestCase(name: "plannerTimeIncludesAcceleration") {
        // 100 mm at 3000 mm/min from rest to rest: 50 mm/s, 0.1 s to accelerate at 500 mm/s²
        // (2.5 mm), so 2 s cruising + 0.1 s ramps ≈ 2.1 s (the naive 2.0 s is too short).
        let line = [(start: SIMD3<Double>(0, 0, 0), move: Move(.cut, x: 100, y: 0, z: 0, feed: 3000))]
        let t = ToolpathTimeline.plannerSeconds(line, machine: .cr1).reduce(0, +)
        try expect(abs(t - 2.1) < 0.02, "got \(t)")
        // The same 100 mm as a zig-zag of 2 mm reversals never reaches the feed.
        var zig: [(start: SIMD3<Double>, move: Move)] = []
        var x = 0.0
        for i in 0..<50 {
            let nx = i % 2 == 0 ? 2.0 : 0.0
            zig.append((SIMD3(x, 0, 0), Move(.cut, x: nx, y: 0, z: 0, feed: 3000)))
            x = nx
        }
        let tz = ToolpathTimeline.plannerSeconds(zig, machine: .cr1).reduce(0, +)
        try expect(tz > t * 1.5, "zig-zag \(tz) vs straight \(t)")
        // Straight segments in line keep their speed through the junction.
        let split = [(start: SIMD3<Double>(0, 0, 0), move: Move(.cut, x: 50, y: 0, z: 0, feed: 3000)),
                     (start: SIMD3<Double>(50, 0, 0), move: Move(.cut, x: 100, y: 0, z: 0, feed: 3000))]
        try expect(abs(ToolpathTimeline.plannerSeconds(split, machine: .cr1).reduce(0, +) - t) < 0.01)
    },
    TestCase(name: "tuningPresetsAndApply") {
        try expectEqual(Tuning.preset(.fine).preset, .fine)
        try expect(Tuning(cusp: 0.005, pace: 1).preset == nil)
        try expect(abs(Tuning.preset(.standard).ra - 2) < 1e-9)
        let ops = [Operation(kind: .adaptive, toolID: quarter.id), Operation(kind: .parallel, toolID: quarter.id)]
        let tuned = Tuning.preset(.mirror).apply(to: ops)
        try expectEqual(tuned[1].scallop, 0.002)
        try expectEqual(tuned[0].scallop, ops[0].scallop)
        try expect(tuned.allSatisfy { $0.feedScale == 0.8 })
        let al = MaterialLibrary.material(id: "al-6061")!
        let base = ops[0].cuttingData(tool: quarter, material: al)
        let slow = tuned[0].cuttingData(tool: quarter, material: al)
        try expect(slow.feed < base.feed && slow.stepover < base.stepover)
        var brisk = ops[0]
        brisk.feedScale = 1.2
        try expect(brisk.cuttingData(tool: quarter, material: al).feed <= MachineProfile.cr1.maxFeedAnyDirection)
    },
    TestCase(name: "toolWearAndCost") {
        let al = MaterialLibrary.material(id: "al-6061")!
        let steel = MaterialLibrary.material(id: "steel-1018")!
        let w = ToolWear.fraction(tool: quarter, material: al, minutes: 90, pace: 1)
        try expect(abs(w - 0.1) < 1e-9)
        try expect(ToolWear.fraction(tool: quarter, material: steel, minutes: 90, pace: 1) > w)
        // 20 % faster costs about twice the tool life.
        try expect(ToolWear.fraction(tool: quarter, material: al, minutes: 90, pace: 1.2) > 2 * w)
        var c = CostModel()
        c.labourPerHour = 30
        let k = c.cost(minutes: 60, toolMinutes: [(quarter, 90)], material: al, pace: 1,
                       stockVolume: 50 * 40 * 20, setups: 2)
        try expect(abs(k.machine - 4) < 1e-9)
        try expect(abs(k.labour - 12) < 1e-9)
        try expect(abs(k.tools - 0.1 * (quarter.unitCost ?? 25)) < 1e-9)
        try expect(k.stock > 0.2 && k.stock < 2, "stock \(k.stock)")
        try expect(abs(k.total - (k.machine + k.tools + k.stock + k.labour)) < 1e-9)
    },
]
