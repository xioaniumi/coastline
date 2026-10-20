import CoastlineCore
import Foundation
import simd

extension AppModel {
    /// Searches the plans the inventory allows (StrategyEngine) and keeps three to choose from.
    func findPlans(inventory: Inventory) async {
        guard let part, let stock, let material = stock.material else { return }
        isFindingPlans = true
        defer { isFindingPlans = false }
        status = "Analysing the part…"
        do {
            let engine = try await liveEngine()
            let m = workTransform(part)
            if features == nil { features = try await engine.features(partID: part.partID, transform: m) }
            if analysis == nil { analysis = try await engine.analyse(partID: part.partID, transform: m) }
        } catch {
            errorMessage = "Couldn't analyse the part: \(error)"
            return
        }
        guard let a = analysis else { return }
        chooseSides(a)  // one or two sides decides how deep each side cuts
        let (lo, hi) = setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        var facts = StrategyEngine.Facts(analysis: a, part: hi - lo, stock: setup.stockSize(stock), faceDepth: 0.25,
                                         holeDiameters: features?.holes.map(\.diameter) ?? [],
                                         hasFloors: !(features?.floorLevels.isEmpty ?? true), material: material)
        // Holes are made by drilling and boring: the narrow "pockets" they are (their own
        // diameter) and the rings of counterbores around them (floors as wide as the step)
        // aren't pockets or floors the end mills must fit.
        let holes = features?.holes ?? []
        var rings: [Double] = []
        for a in holes {
            for b in holes where b.diameter > a.diameter + 0.01 && hypot(a.x - b.x, a.y - b.y) < 0.01 {
                rings.append((b.diameter - a.diameter) / 2)
            }
        }
        func isHole(_ w: Double) -> Bool { holes.contains { abs($0.diameter - w) < 0.06 } }
        facts.pocketWidths = (features?.pocketWidths ?? []).filter { !isHole($0) }
        let floorWidths = features?.floorWidths ?? [], floorDepths = features?.floorDepths ?? []
        let keep = floorWidths.indices.filter { k in !rings.contains { abs($0 - floorWidths[k]) < 0.06 } && !isHole(floorWidths[k]) }
        facts.floorWidths = keep.map { floorWidths[$0] }
        facts.floorDepths = keep.compactMap { floorDepths.indices.contains($0) ? floorDepths[$0] : nil }
        // How deep the tools go on the deeper side. Side A: to the split (+ overlap). Side B first
        // faces its backing to 0.5 mm above the part, then cuts the rest of the part (+ overlap).
        let partZ = hi.z - lo.z
        if let z = splitZ {
            let partAbove = -z - setup.topAllowance
            facts.cutDepth = max(-z + 0.5, partZ - partAbove + 1.0)
        } else {
            facts.cutDepth = setup.topAllowance + partZ
        }
        // Hundreds of plans: off the main thread, so the window (and the button's spinner) stays live.
        status = "Comparing plans…"
        let cal = calibration, f = facts
        let (all, withBuyAll) = await Task.detached(priority: .userInitiated) {
            (StrategyEngine.candidates(facts: f, inventory: inventory, calibration: cal),
             StrategyEngine.candidates(facts: f, inventory: inventory, calibration: cal, includeSuggestions: true))
        }.value
        planCandidates = all
        planOptions = StrategyEngine.recommend(all)
        // The same with the tools Coastline would suggest buying: offered when one is clearly
        // better (finer, less risky) or the only way.
        let withBuy = withBuyAll.filter { !$0.needsTools.isEmpty }
        if ProcessInfo.processInfo.environment["COASTLINE_PLAN_DEBUG"] != nil {
            for c in StrategyEngine.pareto(withBuy).prefix(8) {
                print("buyplan \(Int(c.minutes)) min finish \(c.finish) risk \(c.risk) needs \(c.needsTools.map(\.name)) \(c.reasons.filter { $0.hasPrefix("Risk") || $0.hasPrefix("Unfinished") })")
            }
        }
        let bestOwnedFinish = planOptions.map(\.finish).min() ?? .infinity
        let bestOwnedRisk = planOptions.map(\.risk).min() ?? .infinity
        var extra = StrategyEngine.recommend(withBuy).filter { c in
            planOptions.isEmpty || c.finish < bestOwnedFinish * 0.7 || c.risk < bestOwnedRisk - 0.15
        }
        // The safest first, then the quickest (a machined finish you polish anyway; the finest
        // cusps cost hours): Balanced or Fastest is recommended, Finest stays a choice.
        extra = Array(extra.sorted { ($0.risk, $0.name.hasPrefix("Finest") ? 1 : 0, $0.minutes) < ($1.risk, $1.name.hasPrefix("Finest") ? 1 : 0, $1.minutes) }.prefix(3))
        for k in extra.indices {
            let n = extra[k].needsTools.count
            extra[k].name = "\(extra[k].name), with \(n == 1 ? "a tool" : "\(n) tools") to buy"
        }
        // When your own tools can't do it safely (risk: shanks rubbing, pockets left uncut), the
        // plan with tools to buy is the recommended one, shown first.
        // A shank rubbing the walls is never offered when a longer tool fixes it: those plans
        // go, and the ones with the tool to buy take their place.
        let rubs: (StrategyEngine.Candidate) -> Bool = { $0.reasons.contains { $0.contains("its shank rubs") } }
        if extra.contains(where: { !rubs($0) }) {
            planOptions.removeAll(where: rubs)
        }
        // Nor one that leaves holes out (too small for your tools) when micro tools to buy make them.
        let unfinished: (StrategyEngine.Candidate) -> Bool = { $0.finish >= StrategyEngine.unmadeHoleFinish }
        if extra.contains(where: { !unfinished($0) }) {
            planOptions.removeAll(where: unfinished)
        }
        if let best = extra.first, planOptions.isEmpty || best.risk < bestOwnedRisk - 0.15 {
            planOptions = extra + planOptions
            recommendedPlan = best.name
        } else {
            planOptions += extra
            recommendedPlan = planOptions.min { ($0.risk, $0.minutes) < ($1.risk, $1.minutes) }?.name
        }
        planCandidates += withBuy
        let more = extra.isEmpty ? "" : "; \(extra.count) would be better with a tool you don't have yet"
        status = planOptions.isEmpty ? "No usable plan: add a flat end mill to your inventory." :
            "Compared \(all.count + withBuy.count) plans; \(StrategyEngine.pareto(all).count) are best at something\(more)"
    }

    /// A risk's fix applied to a plan (and that plan used).
    func applyRemedy(_ r: StrategyEngine.Remedy, to c: StrategyEngine.Candidate) {
        var fixed = c
        fixed.operations = StrategyEngine.apply(r, to: c.operations)
        fixed.remedies.removeAll { $0 == r }
        fixed.reasons.append("Changed: \(r.title).")
        if case .swap(_, let to) = r.change, let t = toolLookup(to), !fixed.tools.contains(where: { $0.id == to }) { fixed.tools.append(t) }
        // Each fix takes roughly one risk step away.
        fixed.risk = max(fixed.risk - 0.2, 0)
        if let k = planOptions.firstIndex(where: { $0.id == c.id }) { planOptions[k] = fixed }
        usePlan(fixed)
        status = "\(r.title): done. Generate to see it."
    }

    /// The tools the current job uses that aren't in the inventory yet (Coastline suggestions):
    /// on the Shopping List, flagged in Machining. The simulation uses them like owned ones.
    var jobToolsToBuy: [Tool] {
        var seen = Set<UUID>()
        return operations.filter(\.enabled).compactMap { $0.toolID.flatMap(toolLookup) }
            .filter { $0.isSuggestion && seen.insert($0.id).inserted }
    }

    func usePlan(_ c: StrategyEngine.Candidate) {
        // Threads and engraving are yours (no plan makes them): they stay, at the end.
        operations = c.operations + operations.filter { [.thread, .engrave].contains($0.kind) }
        planNotes = c.reasons
        planEstimate = c.minutesByOp
        chosenPlan = c.name
    }

    /// After generating: teach the time model what the simulation says each operation takes.
    func learnFromGeneration() {
        guard !planEstimate.isEmpty, !sideResults.isEmpty else { return }
        // Simulated minutes per operation over the whole job: both sides, every depth slice and
        // strip of it.
        var simulated: [UUID: Double] = [:]
        for r in sideResults {
            for (k, path) in r.paths.enumerated() where k < r.planned.count {
                simulated[r.planned[k].operation.id, default: 0] += TimeEstimate.seconds([path]) / 60
            }
        }
        var cal = calibration
        for op in operations {
            guard let est = planEstimate[op.id], let sim = simulated[op.id], sim > 0 else { continue }
            // The estimate already includes the current factor: learn the raw model's error.
            let raw = est / (calibration.factor[op.kind.rawValue] ?? 1)
            cal.learn(op.kind, estimated: raw, simulated: sim)
        }
        calibration = cal
        if let data = try? JSONEncoder().encode(cal) { UserDefaults.standard.set(data, forKey: "strategyCalibration") }
    }

    static func loadCalibration() -> StrategyEngine.Calibration {
        guard let d = UserDefaults.standard.data(forKey: "strategyCalibration"),
              let c = try? JSONDecoder().decode(StrategyEngine.Calibration.self, from: d) else { return StrategyEngine.Calibration() }
        return c
    }
}
