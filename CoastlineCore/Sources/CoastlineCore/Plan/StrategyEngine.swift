import Foundation

/// The smart planner. The way CloudNC- and Fusion-style automated CAM work, without a
/// black box: recognise what the part is made of (analysis), enumerate the sensible plans your
/// inventory allows (strategy templates), cost each one with models of time, finish and risk,
/// keep the Pareto front, and explain every choice. Generated toolpaths feed real times back
/// (`Calibration`), so the time model learns from simulation.
public enum StrategyEngine {
    /// What the planner knows about the job.
    public struct Facts: Sendable {
        public var analysis: PartAnalysis
        /// Part and stock size in the work frame (X up, Y across, Z toward the spindle).
        public var part: SIMD3<Double>
        public var stock: SIMD3<Double>
        public var faceDepth: Double
        public var holeDiameters: [Double]
        public var hasFloors: Bool
        public var material: Material
        /// Pockets in the outline (inscribed widths, mm): lattices, windows, recesses.
        public var pocketWidths: [Double] = []
        /// Flat floors' widths (the widest circle that fits each), mm.
        public var floorWidths: [Double] = []
        public var floorDepths: [Double] = []
        /// The deepest any side cuts below its material top (mm), when known: the tools that go
        /// down narrow pockets need that much reach.
        public var cutDepth: Double?

        public init(analysis: PartAnalysis, part: SIMD3<Double>, stock: SIMD3<Double>, faceDepth: Double = 0.25,
                    holeDiameters: [Double] = [], hasFloors: Bool = false, material: Material) {
            self.analysis = analysis
            self.part = part
            self.stock = stock
            self.faceDepth = faceDepth
            self.holeDiameters = holeDiameters
            self.hasFloors = hasFloors
            self.material = material
        }

        var freeform: Bool { analysis.freeformArea > 1 }
        var steepFraction: Double { analysis.freeformArea > 0 ? min(analysis.steepArea / analysis.freeformArea, 1) : 0 }
        /// Silhouette area (from the roundness and the bounding size).
        var silhouetteArea: Double {
            let r = max(part.x, part.y) / 2
            let disc = analysis.circularity > 0 ? analysis.circularity * .pi * r * r : part.x * part.y * 0.8
            return min(disc, part.x * part.y)
        }
        var perimeter: Double { .pi * (part.x + part.y) / 2 }
    }

    /// Per-kind multipliers that turn the model's minutes into simulated minutes (learned).
    public struct Calibration: Codable, Sendable, Equatable {
        public var factor: [String: Double] = [:]
        public init() {}
        public func apply(_ kind: OperationKind, _ minutes: Double) -> Double { minutes * (factor[kind.rawValue] ?? 1) }
        /// Moves the factor toward the observed ratio (exponential average, so one odd job
        /// doesn't swing it).
        public mutating func learn(_ kind: OperationKind, estimated: Double, simulated: Double) {
            guard estimated > 0.05, simulated > 0 else { return }
            let ratio = min(max(simulated / estimated, 0.25), 4)
            let old = factor[kind.rawValue] ?? 1
            factor[kind.rawValue] = old * 0.6 + ratio * 0.4
        }
    }

    public struct Candidate: Identifiable, Sendable {
        public var id = UUID()
        public var name: String
        public var operations: [Operation]
        /// Estimated machining minutes per operation, and in total.
        public var minutesByOp: [UUID: Double]
        public var minutes: Double
        /// Worst expected cusp on the finished surfaces, µm.
        public var finish: Double
        /// 0 (comfortable) … 1 (asking for trouble): tool deflection, breakage, heavy terraces.
        public var risk: Double
        public var reasons: [String]
        public var tools: [Tool]
        /// Tools it uses that aren't owned (suggestions to buy).
        public var needsTools: [Tool] { tools.filter(\.isSuggestion) }
        /// What lowers each risk, as one-click changes.
        public var remedies: [Remedy] = []
    }

    /// A change that makes a plan less risky.
    public struct Remedy: Sendable, Hashable {
        public enum Change: Sendable, Hashable {
            /// Roughing in 1 mm steps (small terraces for the ball).
            case finerRoughing
            /// One tool's feeds slowed to this pace.
            case slower(toolID: UUID, pace: Double)
            /// One tool swapped for another (bigger, shorter or long-reach; maybe not owned).
            case swap(from: UUID, to: UUID)
        }
        public var title: String
        public var change: Change
    }

    /// Applies a remedy to a plan's operations.
    public static func apply(_ r: Remedy, to ops: [Operation]) -> [Operation] {
        ops.map { op in
            var op = op
            switch r.change {
            case .finerRoughing:
                if op.kind == .adaptive { op.stepdownOverride = 1.0; op.leaveAxial = 0.15 }
            case .slower(let id, let pace):
                if op.toolID == id { op.feedScale = min(op.feedScale, pace) }
            case .swap(let from, let to):
                if op.toolID == from { op.toolID = to }
            }
            return op
        }
    }

    // MARK: Search

    public static func candidates(facts: Facts, inventory: Inventory, calibration: Calibration = Calibration(),
                                  includeSuggestions: Bool = false) -> [Candidate] {
        let tools = OperationPlanner.usableTools(inventory, includeSuggestions: includeSuggestions)
        let flats = tools.filter { $0.kind == .flatEndMill }.sorted { $0.diameter > $1.diameter }
        let roughers = Array(flats.filter { $0.diameter <= 6.36 && $0.diameter >= 1.5 }.prefix(2))
        guard !roughers.isEmpty else { return [] }
        let a = facts.analysis
        let concave = a.minConcaveRadius ?? .infinity
        let balls = tools.filter { $0.kind == .ballEndMill || ($0.kind == .bullNoseEndMill && $0.cornerRadius > 0.2) }
            .sorted { $0.diameter > $1.diameter }
        let fitting = balls.filter { $0.diameter / 2 <= concave + 1e-6 && $0.diameter <= 6.36 }
        // The surfaces with a stiff ball (the tight corners are a rest pass for a smaller one),
        // and the largest ball that fits every corner, when that's a different one.
        var finishers3D: [Tool] = []
        for b in balls.filter({ $0.diameter <= 6.36 && $0.diameter >= 1.5 }).prefix(2) + Array(fitting.prefix(1)) + Array(balls.suffix(1))
            where !finishers3D.contains(where: { abs($0.diameter - b.diameter) < 0.05 }) && finishers3D.count < 2 {
            finishers3D.append(b)
        }

        var strategies: [OperationKind] = [.steepShallow, .scallop, .parallel]
        if a.circularity > 0.65 { strategies.append(.spiral) }
        let cusps = [0.004, 0.008, 0.015]
        let steps: [Double?] = facts.freeform ? [nil, 1.0] : [nil]

        var out: [Candidate] = []
        for rougher in roughers {
            for step in steps {
                if !facts.freeform || finishers3D.isEmpty {
                    out.append(build(facts, tools: tools, rougher: rougher, step: step, finisher3D: nil, strategy: nil,
                                     cusp: 0.008, rest: nil, calibration: calibration))
                    continue
                }
                for ball in finishers3D {
                    let smaller = balls.first { $0.diameter < ball.diameter - 0.4 }
                    for strategy in strategies {
                        for cusp in cusps {
                            let rests: [Tool?] = smaller.map { [nil, $0] } ?? [nil]
                            for rest in rests {
                                out.append(build(facts, tools: tools, rougher: rougher, step: step, finisher3D: ball,
                                                 strategy: strategy, cusp: cusp, rest: rest, calibration: calibration))
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// The candidates no other beats on time, finish and risk together.
    public static func pareto(_ cs: [Candidate]) -> [Candidate] {
        cs.filter { c in
            !cs.contains { o in
                o.id != c.id && o.minutes <= c.minutes && o.finish <= c.finish && o.risk <= c.risk
                    && (o.minutes < c.minutes || o.finish < c.finish || o.risk < c.risk)
            }
        }
    }

    /// Three plans to choose from: the fastest acceptable one, the finest, and the knee of the
    /// front between them (most finish per minute).
    public static func recommend(_ cs: [Candidate]) -> [Candidate] {
        var front = pareto(cs).filter { $0.risk < 0.6 }
        // A plan that leaves holes out isn't offered while another one makes the whole part.
        if front.contains(where: { $0.finish < unmadeHoleFinish }) { front.removeAll { $0.finish >= unmadeHoleFinish } }
        guard !front.isEmpty else {
            // Nothing safe: the quickest, named for what it is.
            return cs.min { $0.minutes < $1.minutes }.map { var c = $0; c.name = "Quickest (risky)"; return [c] } ?? []
        }
        let tMin = front.map(\.minutes).min()!, tMax = front.map(\.minutes).max()!
        let fMin = front.map(\.finish).min()!, fMax = front.map(\.finish).max()!
        func norm(_ v: Double, _ lo: Double, _ hi: Double) -> Double { hi - lo < 1e-9 ? 0 : (v - lo) / (hi - lo) }
        // Risk weighs in: a minute quicker isn't worth a tool that may deflect or break.
        let fastest = front.filter { $0.finish <= 20 }.min { $0.minutes * (1 + $0.risk) < $1.minutes * (1 + $1.risk) }
            ?? front.min { $0.minutes * (1 + $0.risk) < $1.minutes * (1 + $1.risk) }!
        let finest = front.min { ($0.finish, $0.risk, $0.minutes) < ($1.finish, $1.risk, $1.minutes) }!
        let balanced = front.min { a, b in
            (norm(a.minutes, tMin, tMax) + norm(a.finish, fMin, fMax) + a.risk * 0.5)
                < (norm(b.minutes, tMin, tMax) + norm(b.finish, fMin, fMax) + b.risk * 0.5)
        }!
        var picks: [Candidate] = []
        for c in [fastest, balanced, finest] where !picks.contains(where: { $0.operations.map(\.kind) == c.operations.map(\.kind) && abs($0.minutes - c.minutes) < 0.5 && $0.finish == c.finish }) {
            picks.append(c)
        }
        // Named by what they are, in order: the quickest is "Fastest", the finest "Finest", the
        // one between "Balanced" (the knee can be quicker than the fastest with a finish ≤ 20 µm,
        // and a plan called Balanced must never beat the one called Fastest on time).
        picks.sort { ($0.minutes, $1.finish) < ($1.minutes, $0.finish) }
        for k in picks.indices { picks[k].name = "Balanced" }
        if picks.count > 1 {
            picks[0].name = "Fastest"
            if let f = picks.indices.dropFirst().min(by: { (picks[$0].finish, picks[$0].minutes) < (picks[$1].finish, picks[$1].minutes) }) {
                picks[f].name = "Finest"
            }
        }
        return picks
    }

    // MARK: One candidate

    static func build(_ f: Facts, tools: [Tool], rougher: Tool, step: Double?, finisher3D: Tool?, strategy: OperationKind?,
                      cusp: Double, rest: Tool?, calibration: Calibration) -> Candidate {
        let a = f.analysis, m = f.material
        var ops: [Operation] = []
        var minutes: [UUID: Double] = [:]
        var reasons: [String] = []
        var remedies: [Remedy] = []
        var risk = 0.0
        var finish = 0.0
        func add(_ op: Operation, _ tool: Tool, _ est: Double) {
            ops.append(op)
            minutes[op.id] = calibration.apply(op.kind, est)
        }
        let depth = max(f.part.z + f.faceDepth, 0.5)
        // Small tools go all the way down narrow pockets: they need the reach. A same-size tool
        // that reaches (owned first) is used instead; if there's none, it's a risk with the
        // long-reach one to buy as the remedy.
        var reachChecked: [UUID: Tool] = [:]
        func reaching(_ t: Tool) -> Tool {
            if let r = reachChecked[t.id] { return r }
            guard let cd = f.cutDepth, t.fluteLength < cd - 0.05 else { reachChecked[t.id] = t; return t }
            let same = tools.filter { $0.kind == t.kind && abs($0.diameter - t.diameter) < 0.05 && $0.fluteLength >= cd - 0.05 }
            if let r = same.sorted(by: { ($0.isSuggestion ? 1 : 0, $0.fluteLength) < ($1.isSuggestion ? 1 : 0, $1.fluteLength) }).first {
                reasons.append("The cuts go \(Length.mm(cd)) mm deep on a side: the \(r.name) reaches that far\(r.isSuggestion ? " (to buy)" : "").")
                reachChecked[t.id] = r
                return r
            }
            risk += 0.2
            reasons.append("Risk: the cuts go \(Length.mm(cd)) mm deep on a side, the \(t.name) has \(Length.mm(t.fluteLength)) mm of flute: its shank rubs the walls.")
            if let buy = ToolCatalog.suggestions.first(where: { $0.kind == t.kind && abs($0.diameter - t.diameter) < 0.05 && $0.fluteLength >= cd - 0.05 }) {
                remedies.append(Remedy(title: "Use the \(buy.name) (not owned): it reaches \(Length.mm(buy.fluteLength)) mm", change: .swap(from: t.id, to: buy.id)))
            }
            reachChecked[t.id] = t
            return t
        }

        let rougher = reaching(rougher)  // its flutes reach the depth too (no shank rubbing)

        // Facing.
        let face = Operation(kind: .facing, toolID: rougher.id, faceDepth: f.faceDepth)
        let fd = face.cuttingData(tool: rougher, material: m)
        let passes = max(1, (f.faceDepth / max(fd.stepdown, 0.05)).rounded(.up))
        add(face, rougher, f.stock.x * f.stock.y / max(fd.stepover, 0.1) * passes / max(fd.feed, 1) * 1.1)

        // Roughing: the band around the part plus what's above its curved top.
        var rough = Operation(kind: .adaptive, toolID: rougher.id, leaveRadial: 0.2, leaveAxial: step == nil ? 0.1 : 0.15)
        rough.stepdownOverride = step
        let rd = rough.cuttingData(tool: rougher, material: m)
        let band = f.perimeter * (rougher.diameter + 1)
        let above = max(f.silhouetteArea * f.part.z - a.volume, 0)
        let volume = band * depth + above
        let ap = min(rd.stepdown, depth)
        add(rough, rougher, volume / max(rd.feed * rd.stepover * ap, 1) * 1.35 + depth / ap * 0.15)
        reasons.append("Roughing with the \(rougher.name)\(rougher.diameter >= 6 ? ": the largest end mill you can hold, so the fastest and stiffest" : ""), \(step == nil ? "deep steps (\(Length.mm(ap)) mm) along the flute" : "1 mm steps so the ball finisher meets small terraces").")
        if f.freeform && step == nil, let b = finisher3D, b.diameter < 3.5 {
            risk += 0.25
            reasons.append("Risk: deep roughing steps leave terraces up to \(Length.mm(ap)) mm high for a \(Length.mm(b.diameter)) mm ball to clean.")
            remedies.append(Remedy(title: "Rough in 1 mm steps (small terraces, a little slower)", change: .finerRoughing))
        }

        // Pockets too narrow for the rougher (lattices, windows): roughed with smaller end mills,
        // each taking the pockets the one before couldn't (the smallest takes all it fits).
        let flats = tools.filter { $0.kind == .flatEndMill }.sorted { $0.diameter > $1.diameter }
        var left = f.pocketWidths.filter { $0 < Operation.defaultMinPocket * rougher.diameter }
        var pocketTools: [Tool] = []
        for candidate in flats where candidate.diameter < (pocketTools.last ?? rougher).diameter - 0.5 && candidate.diameter >= 0.75 && !left.isEmpty {
            let fits = left.filter { $0 >= 1.3 * candidate.diameter }
            guard !fits.isEmpty else { continue }
            let t = reaching(candidate)
            let last = left.filter { $0 >= 1.3 * t.diameter }.count == left.count || candidate.id == flats.last?.id
            var op = Operation(kind: .adaptive, toolID: t.id, leaveRadial: 0.15, leaveAxial: 0.1)
            op.pocketsOnly = true
            op.minPocket = last ? 1.2 : Operation.defaultMinPocket
            let d = op.cuttingData(tool: t, material: m)
            let area = fits.reduce(0) { $0 + .pi * $1 * $1 / 4 }
            add(op, t, area * depth / max(d.feed * d.stepover * min(d.stepdown, depth), 1) * 1.6)
            pocketTools.append(t)
            left.removeAll { $0 >= 1.3 * t.diameter && (last || $0 < Operation.defaultMinPocket * t.diameter) }
        }
        if !pocketTools.isEmpty {
            reasons.append("\(f.pocketWidths.filter { $0 < Operation.defaultMinPocket * rougher.diameter }.count) pockets are too narrow for the \(rougher.name): roughed with the \(pocketTools.map(\.name).joined(separator: ", then the ")).")
        }
        if !left.isEmpty, let narrowest = left.min() {
            risk += 0.3
            reasons.append("Risk: \(left.count) pocket\(left.count == 1 ? "" : "s") down to \(Length.mm(narrowest)) mm wide fit none of these end mills: they'd stay uncut.")
        }

        // Walls and floors: the finisher must fit the tightest corners and pockets.
        let corner = a.minConcaveRadius ?? .infinity
        let narrowPocket = f.pocketWidths.min() ?? .infinity
        let wallTool = tools.filter { $0.kind == .flatEndMill && $0.diameter < rougher.diameter - 0.5 && $0.diameter >= 0.75
            && $0.diameter < narrowPocket / 1.2 && ($0.diameter >= 2.9 || corner < 1.6) }
            .max { $0.diameter < $1.diameter }.map { f.pocketWidths.isEmpty && f.holeDiameters.isEmpty ? $0 : reaching($0) } ?? rougher  // holes are enclosed walls too
        if a.wallArea > 1 {
            let wall = Operation(kind: .contour, toolID: wallTool.id, springPass: true)
            let wd = wall.cuttingData(tool: wallTool, material: m)
            add(wall, wallTool, a.wallArea / max(wd.stepdown, 0.1) * 2 / max(wd.feed, 1) * 1.2)
        }
        if f.hasFloors {
            let floor = Operation(kind: .floor, toolID: wallTool.id)
            let fl = floor.cuttingData(tool: wallTool, material: m)
            add(floor, wallTool, a.flatArea / max(fl.stepover, 0.1) / max(fl.feed, 1) * 1.2)
            // Floors narrower than that tool: a second pass with one that fits (a tool to buy
            // when none of yours does), so no floor is left unfinished.
            let narrowIdx = f.floorWidths.indices.filter { f.floorWidths[$0] < wallTool.diameter + 0.1 }
            let narrow = narrowIdx.map { f.floorWidths[$0] }
            let deepest = narrowIdx.compactMap { f.floorDepths.indices.contains($0) ? f.floorDepths[$0] : nil }.max() ?? (f.cutDepth ?? depth)
            if let w = narrow.min() {
                // Small enough to fit, and its flutes reach those floors (not the whole side).
                let fits = tools.filter { $0.kind == .flatEndMill && $0.diameter < w - 0.2 && $0.diameter >= 0.45 }
                let reachesFloors = fits.filter { $0.fluteLength >= deepest + 0.3 }
                if let small = (reachesFloors.isEmpty ? fits : reachesFloors).max(by: { ($0.isSuggestion ? 0 : 1, $0.diameter) < ($1.isSuggestion ? 0 : 1, $1.diameter) }) {
                    var op2 = Operation(kind: .floor, toolID: small.id)
                    op2.floorMaxWidth = wallTool.diameter + 0.1  // only those the first pass couldn't do
                    let fd = op2.cuttingData(tool: small, material: m)
                    add(op2, small, a.flatArea * 0.1 / max(fd.stepover, 0.05) / max(fd.feed, 1) * 1.3)
                    reasons.append("\(narrow.count) floor\(narrow.count == 1 ? " is" : "s are") narrower than the \(wallTool.name) (down to \(Length.mm(w)) mm): the \(small.name)\(small.isSuggestion ? " (to buy)" : "") finishes \(narrow.count == 1 ? "it" : "them").")
                } else {
                    risk += 0.2
                    reasons.append("Risk: \(narrow.count) floor\(narrow.count == 1 ? "" : "s") down to \(Length.mm(w)) mm wide fit none of these end mills: they stay unfinished.")
                }
            }
        }

        // 3D finishing.
        if let ball0 = finisher3D, let strategy {
            let ball = reaching(ball0)
            var op = Operation(kind: strategy, toolID: ball.id)
            op.scallop = cusp
            let d = op.cuttingData(tool: ball, material: m)
            let link: Double = switch strategy {
            case .spiral: 1.03
            case .parallel: 1.15
            case .scallop: 1.15
            case .steepShallow: 1.22
            case .radial: 1.3
            default: 1.2
            }
            add(op, ball, a.freeformArea / max(d.stepover, 0.01) * link / max(d.feed, 1))
            // Finish: parallel passes spread out on steep walls; spiral is even only on round parts.
            var h = cusp * 1000
            switch strategy {
            case .parallel: h *= 1 + 3 * f.steepFraction
            case .spiral where a.circularity < 0.8: h *= 1.4
            case .radial: h *= 1.3
            default: break
            }
            finish = max(finish, h)
            reasons.append(explain(strategy, f) + " With the \(ball.name), \(Length.mm(d.stepover)) mm stepover for ~\(Int((cusp * 1000).rounded())) µm cusps.")
            // Corners tighter than the ball: left for the rest pass, or left on the part.
            if let r = a.minConcaveRadius, ball.diameter / 2 > r + 1e-6 {
                if rest == nil { finish = max(finish, (ball.diameter / 2 - r) * 1000 * 0.3); reasons.append("Corners tighter than the ball (R\(Length.mm(r))) keep a little material.") }
            }
            // Stick-out: only as much as the depth needs (+3 mm), which also keeps it stiff.
            let need = max(f.part.z + 3, ball.fluteLength)
            if ball.stickout > need + 4 {
                reasons.append("Stick the \(ball.name) out only ~\(Length.mm(need.rounded(.up))) mm (not \(Length.mm(ball.stickout))): stiffer, finer finish, less chatter.")
            }
            if need / ball.diameter > 6 {
                risk += 0.2
                reasons.append("Risk: the depth needs the \(ball.name) \(Int(need / ball.diameter))× its diameter out; it can deflect.")
                // A stiffer ball that still fits the corners, else a long-reach one, else slower.
                let corner = a.minConcaveRadius ?? .infinity
                if let stiffer = tools.filter({ $0.kind == .ballEndMill && $0.diameter > ball.diameter + 0.3 && $0.diameter / 2 <= corner + 1e-6
                    && need / $0.diameter <= 6 }).min(by: { $0.diameter < $1.diameter }) {
                    remedies.append(Remedy(title: "Use the \(stiffer.name)\(stiffer.isSuggestion ? " (not owned)" : ""): stiffer, still fits the corners", change: .swap(from: ball.id, to: stiffer.id)))
                } else if let reach = tools.filter({ $0.kind == .ballEndMill && abs($0.diameter - ball.diameter) < 0.05 && $0.id != ball.id && $0.fluteLength >= need }).first {
                    remedies.append(Remedy(title: "Use the \(reach.name)\(reach.isSuggestion ? " (not owned)" : ""): its neck clears the walls", change: .swap(from: ball.id, to: reach.id)))
                }
                remedies.append(Remedy(title: "Slow the \(ball.name) to 75 % (less deflection, longer)", change: .slower(toolID: ball.id, pace: 0.75)))
            }
            if let rest0 = rest {
                let rest = reaching(rest0)
                var r = Operation(kind: .rest, toolID: rest.id)
                r.scallop = cusp
                let rd2 = r.cuttingData(tool: rest, material: m)
                add(r, rest, (a.freeformArea * 0.08 + a.wallArea * 0.05) * 2 / max(rd2.stepover, 0.01) / max(rd2.feed, 1) * 1.3)
                reasons.append("Then the \(rest.name) cleans the creases and inside corners the bigger ball can't reach.")
                if rest.diameter < 1 && m.difficulty >= .moderate {
                    risk += 0.2
                    reasons.append("Risk: a sub-millimetre ball in \(m.name) breaks easily; keep the feeds conservative.")
                    remedies.append(Remedy(title: "Slow the \(rest.name) to 70 %", change: .slower(toolID: rest.id, pace: 0.7)))
                }
            }
        } else if f.freeform {
            finish = 40
            reasons.append("No ball end mill: curved surfaces keep the roughing terraces (~\(Length.mm(ap)) mm steps). Buy a 1/8\" ball for a smooth finish.")
        } else {
            finish = 2  // 2.5D walls and floors finish to size
        }

        // Holes. One this plan's tools can't make is left out of the part: that's not a finish
        // the plan may claim, so it scores as unfinished (a plan that makes it, with a tool to
        // buy, then wins).
        let drills = tools.filter { $0.kind == .drill }
        var unmade: [Double] = []
        for d in Set(f.holeDiameters.map { ($0 * 100).rounded() / 100 }).sorted() {
            if let drill = drills.first(where: { abs($0.diameter - d) <= 0.05 }) {
                add(Operation(kind: .drill, toolID: drill.id), drill, 1.0)
                if drill.isSuggestion { reasons.append("⌀\(Length.mm(d)) holes: drilled with the \(drill.name) (to buy).") }
            } else if let fit = tools.filter({ $0.kind == .flatEndMill && $0.diameter <= d * 0.8 && $0.diameter >= d * 0.3 }).max(by: { $0.diameter < $1.diameter }) {
                // Bored the whole depth: a shank wider than the cutter would stop it part way
                // (or rub), so the same size that reaches, when there is one.
                let mill = reaching(fit)
                add(Operation(kind: .bore, toolID: mill.id), mill, 1.0)
                if mill.isSuggestion { reasons.append("⌀\(Length.mm(d)) holes: bored with the \(mill.name) (to buy).") }
            } else if !tools.contains(where: { $0.kind == .flatEndMill && $0.diameter <= d * 0.8 }) {
                unmade.append(d)  // every end mill is too big for it (a bigger hole is milled as a pocket)
            }
        }
        if !unmade.isEmpty {
            finish = max(finish, unmadeHoleFinish)
            reasons.append("Unfinished: the ⌀\(unmade.map { Length.mm($0) }.joined(separator: ", ")) mm holes need a smaller drill or end mill than these tools: they're left out.")
        }
        if max(depth + 3, rougher.fluteLength) / rougher.diameter > 5 {
            risk += 0.15
            reasons.append("Risk: the \(rougher.name) reaches more than 5× its diameter: keep the stick-out short.")
            remedies.append(Remedy(title: "Slow the \(rougher.name) to 80 %", change: .slower(toolID: rougher.id, pace: 0.8)))
        }
        let used = Set(ops.compactMap(\.toolID))
        var c = Candidate(name: "", operations: ops, minutesByOp: minutes, minutes: minutes.values.reduce(0, +),
                          finish: finish, risk: min(risk, 1), reasons: reasons, tools: tools.filter { used.contains($0.id) })
        c.remedies = remedies
        return c
    }

    /// The finish (µm) a plan scores when it leaves holes out: worse than any real surface.
    public static let unmadeHoleFinish = 200.0

    static func explain(_ k: OperationKind, _ f: Facts) -> String {
        let steep = Int((f.steepFraction * 100).rounded())
        switch k {
        case .steepShallow: return "Steep & shallow: \(steep) % of the curved surface is steeper than 45°, so waterline there and parallel passes on the rest give an even finish."
        case .scallop: return "Scallop: passes at a constant distance over the surface, the most even finish on freeform shapes."
        case .parallel: return steep < 10 ? "Parallel: the surface is shallow (\(steep) % steep), so straight passes finish it evenly and quickly." : "Parallel: quick, but the \(steep) % steep area gets wider cusps."
        case .spiral: return "Spiral: the part is round (\(Int((f.analysis.circularity * 100).rounded())) % of a disc), so one continuous spiral with no direction changes."
        default: return k.explanation
        }
    }
}
