import CoastlineCore
import Foundation

extension AppModel {
    /// Machining minutes per operation as generated (the tuner's baseline), with the tool.
    /// Computed once per generation: timing every move through the planner is far too slow to
    /// repeat on each redraw (the panel asks for a dozen estimates while playback runs).
    var tunerBaseline: [(op: Operation, tool: Tool, minutes: Double)] {
        tunerBaselineSided.map { ($0.op, $0.tool, $0.minutes) }
    }

    /// The same with the side each ran on (−1: the prep).
    var tunerBaselineSided: [(op: Operation, tool: Tool, minutes: Double, side: Int)] {
        if let cached = tunerBaselineCache { return cached }
        var out: [(op: Operation, tool: Tool, minutes: Double, side: Int)] = []
        for r in sideResults + prepResults {
            for (k, path) in r.paths.enumerated() where k < r.planned.count {
                out.append((r.planned[k].operation, r.planned[k].tool, TimeEstimate.seconds([path]) / 60, r.side))
            }
        }
        tunerBaselineCache = out
        return out
    }

    /// Minutes for one operation at another tuning: cutting time scales with the feed (and
    /// roughing engagement), 3D finishing also with the stepover the cusp height allows,
    /// roughing with the style's feed × depth (from the feeds engine, for this tool), the hidden
    /// side's 3D finishing with its coarser cusps.
    func scaled(_ minutes: Double, op: Operation, tool: Tool, side: Int, from a: Tuning, to b: Tuning) -> Double {
        let kind = op.kind
        var t = minutes * pow(a.pace / b.pace, kind == .adaptive ? 1.5 : 1)
        if kind.is3D {
            let hid = { (u: Tuning) in u.hiddenSide == side && side >= 0 ? Tuning.hiddenCuspFactor : 1 }
            t *= ((a.cusp * hid(a)) / (b.cusp * hid(b))).squareRoot()  // stepover ∝ √cusp
        }
        if kind == .adaptive, a.roughingStyle != b.roughingStyle, let m = stock?.material {
            let da = FeedsEngine.compute(tool: tool, material: m, kind: .adaptive, roughing: a.roughingStyle)
            let db = FeedsEngine.compute(tool: tool, material: m, kind: .adaptive, roughing: b.roughingStyle)
            // Cutting time ∝ 1 / (feed × depth); links and rapids (~25 %) stay the same.
            let ratio = (da.feed * da.stepdown) / max(db.feed * db.stepdown, 1e-9)
            t = t * 0.25 + t * 0.75 * ratio
        }
        return t
    }

    struct TunerEstimate {
        var minutes: Double
        var toolMinutes: [(Tool, Double)]
        var cost: CostModel.Breakdown?
    }

    func tunerEstimate(_ t: Tuning) -> TunerEstimate? {
        let base = tunerBaselineSided
        guard !base.isEmpty, let stock, let material = stock.material else { return nil }
        var total = 0.0
        var perTool: [UUID: (Tool, Double)] = [:]
        for (op, tool, m, side) in base {
            let s = scaled(m, op: op, tool: tool, side: side, from: generatedTuning, to: t)
            total += s
            perTool[tool.id, default: (tool, 0)].1 += s * 0.85  // ~15 % of program time is rapids and links
        }
        let raw = setup.rawStockSize(stock)
        let setups = 1 + (twoSided ? 1 : 0) + prepPrograms.count
        let cost = costModel.cost(minutes: total, toolMinutes: Array(perTool.values), material: material, pace: t.pace,
                                  stockVolume: raw.x * raw.y * raw.z, setups: setups)
        return TunerEstimate(minutes: total, toolMinutes: Array(perTool.values).sorted { $0.1 > $1.1 }, cost: cost)
    }

    /// Applies the tuner to the operations and regenerates.
    func applyTuning(inventory: Inventory) async {
        operations = tuning.apply(to: operations)
        await generateToolpaths(inventory: inventory)
    }

    static func loadCostModel() -> CostModel {
        guard let d = UserDefaults.standard.data(forKey: "costModel"), let c = try? JSONDecoder().decode(CostModel.self, from: d) else { return CostModel() }
        return c
    }
}

extension AppModel {
    /// The chosen plan's estimate for the enabled operations, minutes (nil: no plan estimate).
    var plannedMinutes: Double? {
        let ms = operations.filter(\.enabled).compactMap { planEstimate[$0.id] }
        return ms.isEmpty ? nil : ms.reduce(0, +)
    }
}
