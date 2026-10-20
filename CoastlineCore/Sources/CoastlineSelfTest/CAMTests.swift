import CoastlineCore
import Foundation
import simd

private let quarter = Tool(name: "1/4 flat", kind: .flatEndMill, diameter: 6.35, shankDiameter: 6.35, flutes: 3,
                           fluteLength: 12.7, stickout: 28.575, overallLength: 50.8)
private let eighth = Tool(name: "1/8 flat", kind: .flatEndMill, diameter: 3.175, shankDiameter: 3.175, flutes: 3,
                          fluteLength: 9.525, stickout: 28.575, overallLength: 50.8)

let camTests: [TestCase] = [
    TestCase(name: "roughingStylesKeepTheChipAndGoDeeper") {
        let al = MaterialLibrary.material(id: "al-6061")!
        let quarter = Tool(name: "1/4\" flat", kind: .flatEndMill, diameter: 6.35, shankDiameter: 6.35, flutes: 3,
                           fluteLength: 12.7, stickout: 25, overallLength: 50)
        let sixteenth = Tool(name: "1/16\" flat", kind: .flatEndMill, diameter: 1.5875, shankDiameter: 3.175, flutes: 2,
                             fluteLength: 4.8, stickout: 15, overallLength: 38)
        let table = FeedsEngine.compute(tool: quarter, material: al, kind: .adaptive, roughing: .table)
        let thin = FeedsEngine.compute(tool: quarter, material: al, kind: .adaptive, roughing: .thinned)
        let deep = FeedsEngine.compute(tool: quarter, material: al, kind: .adaptive, roughing: .deep)
        // Coast Runner's 1/4" adaptive: 30 ipm, 0.020" stepover, 0.125" deep.
        try expect(abs(table.stepdown - 3.175) < 0.01 && table.feed < 950, "table \(table.feed) \(table.stepdown)")
        // The same chip per tooth at 8 % engagement: the feed rises (capped at ×1.6), the depth stays.
        try expect(thin.feed > table.feed * 1.3 && thin.feed <= table.feed / 1.15 * 1.6 + 1 && thin.stepdown == table.stepdown, "thin \(thin.feed)")
        try expect(abs(deep.stepdown - 6.35) < 0.01 && deep.feed == thin.feed, "deep \(deep.stepdown)")
        // Small tools never go deep.
        let s = FeedsEngine.compute(tool: sixteenth, material: al, kind: .adaptive, roughing: .deep)
        try expect(s.stepdown <= 0.5 * 1.5875 + 1e-9, "1/16\" deep \(s.stepdown)")
        // The tuner's presets: draft roughs deep, mirror by the table, standard chip-thinned.
        try expectEqual(Tuning.preset(.draft).roughingStyle, .deep)
        try expectEqual(Tuning.preset(.standard).roughingStyle, .thinned)
        try expectEqual(Tuning.preset(.mirror).roughingStyle, .table)
        var hidden = Tuning.preset(.fine); hidden.hiddenSide = 1
        try expectEqual(hidden.preset, .fine)
    },
    TestCase(name: "feedsMatchCoastRunnersAluminiumTable") {
        let al = MaterialLibrary.material(id: "al-6061")!
        let face = FeedsEngine.compute(tool: quarter, material: al, kind: .facing)
        try expectEqual(face.rpm, 8000)
        // Master document: 1/4" face finish 8000 RPM, 30 ipm (762 mm/min).
        try expect(abs(face.feed - 792) < 40, "facing feed \(face.feed)")
        let adaptive = FeedsEngine.compute(tool: quarter, material: al, kind: .adaptive)
        try expect(adaptive.feed > face.feed && adaptive.feed <= face.feed * 1.16, "chip thinning, capped")
        try expect(abs(adaptive.stepover - 0.508) < 0.01, "R 0.020\" stepover")
        try expect(abs(adaptive.stepdown - 3.175) < 0.01, "½·D stepdown")
        let contour = FeedsEngine.compute(tool: eighth, material: al, kind: .contour)
        try expect(contour.rpm == 8000 || contour.rpm < 8000)
        try expect(contour.notes.contains { $0.contains("8000") } || contour.rpm < 8000)
    },
    TestCase(name: "feedsSlowDownForSteelAndRespectLimits") {
        let steel = MaterialLibrary.material(id: "steel-1018")!
        let d = FeedsEngine.compute(tool: quarter, material: steel, kind: .adaptive)
        try expect(d.rpm < 5000 && d.rpm >= 1500, "steel rpm \(d.rpm)")
        try expect(d.feed < 400, "steel feed \(d.feed)")
        try expect(d.rampAngle <= 1, "careful mode ramps gently")
        let wax = MaterialLibrary.material(id: "wax-machinable")!
        let w = FeedsEngine.compute(tool: quarter, material: wax, kind: .adaptive)
        try expect(w.feed <= MachineProfile.cr1.maxFeedAnyDirection)
    },
    TestCase(name: "threeDFinishingPlansBallsAndCuspStepovers") {
        var inv = Inventory()
        inv.accessories = [Accessory(name: "1/8", kind: .collet, size: 3.175), Accessory(name: "1/4", kind: .collet, size: 6.35)]
        let ball = Tool(name: "1/8 ball", kind: .ballEndMill, diameter: 3.175, shankDiameter: 3.175, flutes: 2, fluteLength: 9.5,
                        stickout: 20, overallLength: 38, cornerRadius: 1.5875)
        let tiny = Tool(name: "1/32 ball", kind: .ballEndMill, diameter: 0.79375, shankDiameter: 3.175, flutes: 2, fluteLength: 1.6,
                        stickout: 15, overallLength: 38, cornerRadius: 0.4)
        inv.tools = [quarter, ball, tiny]
        let p = OperationPlanner.propose(inventory: inv, freeform: true)
        let kinds = p.operations.map(\.kind)
        try expect(kinds.contains(.steepShallow) && kinds.contains(.rest), "\(kinds)")
        try expectEqual(p.operations.first { $0.kind == .steepShallow }?.toolID, ball.id)
        try expectEqual(p.operations.first { $0.kind == .rest }?.toolID, tiny.id)
        try expectEqual(p.operations.first { $0.kind == .adaptive }?.stepdownOverride, 1.0)
        // Cusp height → stepover: 8 µm with a 1/8" ball ≈ 0.318 mm; halving the cusp ≈ ×0.71.
        let al = MaterialLibrary.material(id: "al-6061")!
        var op = Operation(kind: .steepShallow, toolID: ball.id)
        let s8 = op.cuttingData(tool: ball, material: al).stepover
        try expect(abs(s8 - 2 * (2 * 1.5875 * 0.008 - 0.008 * 0.008).squareRoot()) < 1e-9, "\(s8)")
        op.scallop = 0.004
        let s4 = op.cuttingData(tool: ball, material: al).stepover
        try expect(abs(s4 / s8 - 0.707) < 0.01)
        // No freeform: no 3D finishing.
        try expect(!OperationPlanner.propose(inventory: inv).operations.contains { $0.kind.is3D })
    },
    TestCase(name: "strategyEngineFindsAParetoFrontAndExplainsIt") {
        var inv = Inventory()
        inv.accessories = [Accessory(name: "1/8", kind: .collet, size: 3.175), Accessory(name: "1/4", kind: .collet, size: 6.35)]
        let eighth = Tool(name: "1/8 flat", kind: .flatEndMill, diameter: 3.175, shankDiameter: 3.175, flutes: 3, fluteLength: 9.5,
                          stickout: 15, overallLength: 38)
        let ball = Tool(name: "1/8 ball", kind: .ballEndMill, diameter: 3.175, shankDiameter: 3.175, flutes: 2, fluteLength: 9.5,
                        stickout: 20, overallLength: 38)
        let tiny = Tool(name: "1/32 ball", kind: .ballEndMill, diameter: 0.79375, shankDiameter: 3.175, flutes: 2, fluteLength: 1.6,
                        stickout: 15, overallLength: 38)
        let sixteenth = Tool(name: "1/16 flat", kind: .flatEndMill, diameter: 1.5875, shankDiameter: 3.175, flutes: 2, fluteLength: 4.8,
                             stickout: 12, overallLength: 38)
        inv.tools = [quarter, eighth, ball, tiny, sixteenth]  // the 1/16" bores the ⌀2.4 holes
        // The pendant: a 30 mm domed disc, 5 mm thick.
        let a = PartAnalysis(minCornerRadius: 1.2, depth: 5, freeformArea: 830, flatArea: 630, wallArea: 236, steepArea: 0,
                             volume: 2800, circularity: 0.78)
        let facts = StrategyEngine.Facts(analysis: a, part: SIMD3(30, 30, 5), stock: SIMD3(40, 60, 7), holeDiameters: [2.4],
                                         material: MaterialLibrary.material(id: "brass-c360")!)
        let all = StrategyEngine.candidates(facts: facts, inventory: inv)
        try expect(all.count > 20, "\(all.count) candidates")
        let front = StrategyEngine.pareto(all)
        try expect(!front.isEmpty && front.count < all.count)
        let picks = StrategyEngine.recommend(all)
        try expect(picks.count >= 2, "\(picks.map(\.name))")
        let fastest = picks.first { $0.name == "Fastest" }!, finest = picks.first { $0.name == "Finest" }!
        try expect(fastest.minutes <= finest.minutes && finest.finish <= fastest.finish)
        // Names follow the numbers: nothing is quicker than "Fastest" or finer than "Finest".
        try expect(picks.allSatisfy { $0.minutes >= fastest.minutes - 1e-9 && $0.finish >= finest.finish - 1e-9 },
                   "\(picks.map { "\($0.name) \(Int($0.minutes)) min \($0.finish) µm" })")
        try expect(fastest.reasons.contains { $0.contains("Roughing with") })
        try expect(finest.operations.contains { $0.kind.is3D })
        // Learning: simulated time twice the estimate pulls the factor up.
        var cal = StrategyEngine.Calibration()
        cal.learn(.adaptive, estimated: 10, simulated: 20)
        try expect(abs(cal.apply(.adaptive, 10) - 14) < 1e-9)
    },
    TestCase(name: "plansThatLeaveHolesOutAreUnfinishedAndToolsToBuyMakeThem") {
        // A watch bridge: ⌀0.8 pin holes and ⌀1.0 jewel holes. Your tools can't make them; the
        // suggested Kyocera micro drills can.
        var inv = Inventory()
        inv.accessories = [Accessory(name: "1/8", kind: .collet, size: 3.175), Accessory(name: "1/4", kind: .collet, size: 6.35)]
        let eighth = Tool(name: "1/8 flat", kind: .flatEndMill, diameter: 3.175, shankDiameter: 3.175, flutes: 3, fluteLength: 9.5,
                          stickout: 15, overallLength: 38)
        inv.tools = [quarter, eighth] + ToolCatalog.suggestions
        let a = PartAnalysis(minCornerRadius: 0.6, depth: 2.5, flatArea: 400, wallArea: 120, volume: 700, circularity: 0.3)
        let facts = StrategyEngine.Facts(analysis: a, part: SIMD3(13, 32, 2.5), stock: SIMD3(40, 50, 5), holeDiameters: [0.8, 1.0],
                                         material: MaterialLibrary.material(id: "brass-c360")!)
        let owned = StrategyEngine.candidates(facts: facts, inventory: inv)
        try expect(!owned.isEmpty && owned.allSatisfy { $0.finish >= StrategyEngine.unmadeHoleFinish && $0.reasons.contains { $0.hasPrefix("Unfinished") } })
        let buying = StrategyEngine.candidates(facts: facts, inventory: inv, includeSuggestions: true)
        let picks = StrategyEngine.recommend(owned + buying)
        try expect(!picks.isEmpty && picks.allSatisfy { $0.finish < StrategyEngine.unmadeHoleFinish }, "\(picks.map { "\($0.name) \($0.finish)" })")
        // Both hole sizes drilled with the micro drills (to buy).
        let best = picks[0]
        try expect(best.operations.filter { $0.kind == .drill }.count == 2 && best.needsTools.filter { $0.kind == .drill }.count == 2,
                   "\(best.operations.map(\.kind))")
    },
    TestCase(name: "postPutsFittedArcEndsExactlyOnTheArc") {
        // A small arc whose fitted centre is 0.015 mm closer to the start than to the end (what
        // the arc fitter can return within its tolerance): grbl would stop with error 33.
        let r = 1.2, c = SIMD2(5.0, 5.0)
        let a = c + SIMD2(r, 0), b = c + SIMD2(0, r + 0.015)
        let moves = [Move(.rapid, x: a.x, y: a.y, z: 1), Move(.plunge, x: a.x, y: a.y, z: -1, feed: 300),
                     Move(.cut, .arcCCW, x: b.x, y: b.y, z: -1, i: c.x - a.x, j: c.y - a.y, feed: 800),
                     Move(.rapid, x: b.x, y: b.y, z: 3)]
        let g = CR1Post.program(header: .init(programName: "t", setupName: "OP1", tool: quarter, operationNames: ["Test"], stockDescription: "6061"),
                                rpm: 8000, paths: [OperationToolpath(operationID: UUID(), moves: moves)])
        let ctx = GCodeValidator.Context(stockMin: SIMD3(-40, -75, -20), stockMax: SIMD3(40, 75, 0), tool: quarter)
        let report = GCodeValidator().validate(g, context: ctx)
        try expect(report.passed, "\(report.issues.map(\.message))")
        try expect(g.contains("G3 X5 Y6.215"), g)
    },
    TestCase(name: "postFollowsCoastRunnerConventions") {
        let moves = [Move(.rapid, x: 0, y: 0, z: 3), Move(.rapid, x: 0, y: 0, z: 1),
                     Move(.plunge, x: 0, y: 0, z: -1, feed: 300), Move(.cut, x: 10, y: 0, z: -1, feed: 800),
                     Move(.cut, .arcCCW, x: 10, y: 10, z: -1, i: 0, j: 5, feed: 800), Move(.rapid, x: 10, y: 10, z: 3)]
        let g = CR1Post.program(header: .init(programName: "t", setupName: "OP1", tool: quarter, operationNames: ["Test"],
                                              stockDescription: "6061"),
                                rpm: 8000, paths: [OperationToolpath(operationID: UUID(), moves: moves)])
        let lines = g.split(separator: "\n").map(String.init)
        try expect(lines.contains("G90 G17 G21"))
        try expectEqual(lines.filter { $0 == "G53 G0 G90 Z-1." }.count, 2)
        try expect(lines.contains("S5000") && lines.contains("S8000 M3"), "spindle ramp")
        try expect(!g.contains("M6") && !g.contains("M30"))
        try expect(lines.allSatisfy { $0.count <= 79 })
        try expect(lines.contains("G3 X10 Y10 I0 J5"), "arc line: \(lines)")
        let ctx = GCodeValidator.Context(stockMin: SIMD3(-40, -75, -20), stockMax: SIMD3(40, 75, 0), tool: quarter)
        let report = GCodeValidator().validate(g, context: ctx)
        try expect(report.passed, "\(report.issues)")
    },
    TestCase(name: "validatorRejectsDangerousPrograms") {
        let ctx = GCodeValidator.Context(stockMin: SIMD3(-40, -75, -20), stockMax: SIMD3(40, 75, 0), tool: quarter)
        let v = GCodeValidator()
        let header = "G90 G17 G21\nG54\nS8000 M3\n"
        func errors(_ g: String) -> [String] { v.validate(g, context: ctx).issues.filter { $0.severity == .error }.map(\.message) }
        try expect(errors(header + "G0 X0 Y0 Z3\nG0 X5 Y5 Z-1\n").contains { $0.contains("rapid") }, "rapid into stock")
        try expect(errors("G21\nG0 X0 Y0 Z3\n").contains { $0.contains("G90") }, "missing G90")
        try expect(errors(header + "S9000 M3\n").contains { $0.contains("9000") }, "rpm")
        try expect(errors(header + "M6 T1\n").contains { $0.contains("M6") })
        try expect(errors(header + "G0 X0 Y0 Z3\nG1 Z-25 F100\n").contains { $0.contains("fixture") }, "below stock")
        try expect(errors(header + "G0 X0 Y0 Z3\nG1 Z-1 F5000\n").contains { $0.contains("faster") }, "feed cap")
        try expect(errors("G90 G21\nM5\nG0 X0 Y0 Z3\nG1 Z-1 F100\n").contains { $0.contains("spindle stopped") })
        try expect(errors(header + "G0 X0 Y0 Z3\nG2 X10 Y0 I3 J0 F100\n").contains { $0.contains("arc") })
        try expect(errors(header + "G83 X0 Y0 Z-5 R1 Q1 F100\n").contains { $0.contains("canned") })
        try expect(errors(header + "(" + String(repeating: "x", count: 90) + ")\n").contains { $0.contains("79") })
    },
    TestCase(name: "plannerProposesFromInventory") {
        let inv = Inventory.starter(toolLibraries: [repoRoot.appendingPathComponent("resources/libraries/CR-tools-for-Aluminum.tools")])
        var withCollets = inv
        withCollets.accessories.append(Accessory(name: "3/16", kind: .collet, size: 4.7625))
        let p = OperationPlanner.propose(inventory: withCollets, holeDiameters: [2.4])
        try expectEqual(p.operations.first?.kind, .facing)
        try expect(p.operations.contains { $0.kind == .adaptive } && p.operations.contains { $0.kind == .contour })
        try expect(p.operations.contains { $0.kind == .bore }, "⌀2.4 hole with no 2.4 drill → bore. \(p.notes)")
        let rough = withCollets.tools.first { $0.id == p.operations[1].toolID }!
        try expect(abs(rough.diameter - 6.35) < 0.01, "rough with the 1/4\"")
    },
    TestCase(name: "pendantEndToEndThroughEnginePostAndValidator") {
        let python = repoRoot.appendingPathComponent("engine/.venv/bin/python")
        guard FileManager.default.fileExists(atPath: python.path) else { throw Skip(reason: "engine venv missing") }
        let e = try EngineClient.development(repoRoot: repoRoot)
        let part = try camBlocking { try await e.importPart(repoRoot.appendingPathComponent("resources/samples/pendant.step")) }
        var setup = Setup()
        let stock = StockItem(materialID: "al-6061", sizeX: 150, sizeY: 80, sizeZ: 20)
        setup.stockAxes = Setup.defaultStockAxes(stock)
        let lo = SIMD3(part.boundsMin.x, part.boundsMin.y, part.boundsMin.z), hi = SIMD3(part.boundsMax.x, part.boundsMax.y, part.boundsMax.z)
        let m = setup.partToWork(partMin: lo, partMax: hi)
        let box = setup.stockBox(stock)
        let al = MaterialLibrary.material(id: "al-6061")!
        let small = Tool(name: "1/16 flat", kind: .flatEndMill, diameter: 1.5875, shankDiameter: 3.175, flutes: 3,
                         fluteLength: 6.35, stickout: 15.875, overallLength: 38.1)
        let ops = [Operation(kind: .facing), Operation(kind: .adaptive, leaveRadial: 0.2, leaveAxial: 0.1),
                   Operation(kind: .contour, springPass: true), Operation(kind: .bore)]
        let tools = [quarter, quarter, eighth, small]
        let planned = zip(ops, tools).map { EngineClient.PlannedOperation(operation: $0, tool: $1, data: $0.cuttingData(tool: $1, material: al)) }
        let paths = try camBlocking { try await e.generate(partID: part.partID, transform: m, stockMin: box.min, stockMax: box.max, operations: planned) }
        try expectEqual(paths.count, 4)
        for (p, path) in zip(planned, paths) {
            try expect(path.moves.count > 10, "\(p.operation.kind) produced \(path.moves.count) moves, warnings \(path.warnings), data \(p.data.stepdown)/\(p.data.stepover) m=\(m)")
            let g = CR1Post.program(header: .init(programName: "pendant", setupName: "OP1", tool: p.tool, operationNames: [p.operation.kind.title], stockDescription: "6061"),
                                    rpm: p.data.rpm, paths: [path])
            let report = GCodeValidator().validate(g, context: .init(stockMin: box.min, stockMax: box.max, tool: p.tool))
            if !report.passed { try? g.write(to: URL(fileURLWithPath: "/tmp/coastline_failed_\(p.operation.kind).nc"), atomically: true, encoding: .utf8) }
            try expect(report.passed, "\(p.operation.kind): \(report.issues.map(\.message))")
        }
        let minutes = TimeEstimate.seconds(paths) / 60
        try expect(minutes > 1 && minutes < 120, "estimate \(minutes) min")
    },
]

private final class Box<T>: @unchecked Sendable { var value: Result<T, Error>? }
private func camBlocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.value!.get()
}
