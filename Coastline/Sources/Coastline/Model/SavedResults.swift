import CoastlineCore
import Foundation

/// The generated job, saved inside a `.coastline` file next to the setup and operations: every
/// program's G-code and checks, each side's toolpaths (the engine's own float32 rows, LZFSE
/// compressed) and line map, and what generation decided (stand-out, tabs, reference bores).
/// Opening the project shows it all at once, with no engine work and nothing generated again.
/// Only written while the results match the job (any change clears them).
struct SavedResults: Codable, Equatable {
    var version = 1
    var programs: [Program]
    var prepPrograms: [Program]
    var sides: [Side]
    var prep: [Side]
    var autoProtrusion: Double?
    var bridgeNote: String?
    var placedTabs: [PlacedTab]
    /// Their Z range as generated (older files: from the split).
    var placedTabZ: [Double]? = nil
    var generatedTuning: Tuning
    var travelIssue: String?
    var referencePlan: ReferenceBores.Plan?

    struct Program: Codable, Equatable {
        var index: Int
        var side: Int
        var tool: Tool
        var operations: [Operation]
        var rpm: Double
        var gcode: String
        var report: GCodeValidator.Report
        var seconds: Double
        var warnings: [String]
        var minStickout: Double?
        var clearanceHits: [FixtureClearance.Hit]
        var title: String?
        var surfaceProbe: String? = nil
    }

    struct Side: Codable, Equatable {
        var side: Int
        var setup: Setup
        var planned: [Planned]
        var paths: [Path]
        var operationProgram: [Int]
        /// The G-code line of every move, per operation: Int32, −1 for none, LZFSE.
        var operationLines: Data
        var lineCounts: [Int]
    }

    /// What the views use of a planned operation (the engine-only details aren't needed).
    struct Planned: Codable, Equatable {
        var operation: Operation
        var tool: Tool
        var data: CuttingData
        var zMin: Double?
        var zTop: Double
        var refTool: Tool?
    }

    struct Path: Codable, Equatable {
        var operationID: UUID
        /// float32 rows [role, motion, x, y, z, i, j, feed] (OperationToolpath.decode), LZFSE.
        var moves: Data
        var warnings: [String]
        var notes: [String]
        var minStickout: Double?
    }
}

private extension Data {
    func lzfse() -> Data { ((try? (self as NSData).compressed(using: .lzfse)) as Data?) ?? self }
    func unlzfse() -> Data { ((try? (self as NSData).decompressed(using: .lzfse)) as Data?) ?? self }
    /// Int32 values as written (little-endian on every Mac Coastline runs on).
    var int32s: [Int32] {
        withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
    }
}

extension SavedResults.Program {
    init(_ p: ToolProgram) {
        self.init(index: p.index, side: p.side, tool: p.tool, operations: p.operations, rpm: p.rpm, gcode: p.gcode, report: p.report,
                  seconds: p.seconds, warnings: p.warnings, minStickout: p.minStickout, clearanceHits: p.clearanceHits, title: p.title,
                  surfaceProbe: p.surfaceProbe)
    }

    var program: ToolProgram {
        ToolProgram(index: index, side: side, tool: tool, operations: operations, rpm: rpm, gcode: gcode, report: report, seconds: seconds,
                    warnings: warnings, minStickout: minStickout, clearanceHits: clearanceHits, title: title, surfaceProbe: surfaceProbe)
    }
}

extension SavedResults.Side {
    init(_ r: SideResult) {
        var lines: [Int32] = []
        for op in r.operationLines { lines += op.map { Int32($0 ?? -1) } }
        self.init(side: r.side, setup: r.setup,
                  planned: r.planned.map { SavedResults.Planned(operation: $0.operation, tool: $0.tool, data: $0.data, zMin: $0.zMin, zTop: $0.zTop, refTool: $0.refTool) },
                  paths: r.paths.map { p in
                      var rows: [Float] = []
                      rows.reserveCapacity(p.moves.count * 8)
                      for m in p.moves {
                          rows += [Float(m.role.rawValue), Float(m.motion.rawValue), Float(m.x), Float(m.y), Float(m.z), Float(m.i), Float(m.j), Float(m.feed)]
                      }
                      let raw = rows.withUnsafeBufferPointer { Data(buffer: $0) }
                      return SavedResults.Path(operationID: p.operationID, moves: raw.lzfse(), warnings: p.warnings, notes: p.notes, minStickout: p.minStickout)
                  },
                  operationProgram: r.operationProgram,
                  operationLines: lines.withUnsafeBufferPointer { Data(buffer: $0) }.lzfse(),
                  lineCounts: r.operationLines.map(\.count))
    }

    var result: SideResult {
        let flat = operationLines.unlzfse().int32s
        var lines: [[Int?]] = []
        var k = 0
        for n in lineCounts {
            let end = min(k + n, flat.count)
            lines.append(flat[k..<end].map { $0 < 0 ? nil : Int($0) })
            k = end
        }
        return SideResult(side: side, setup: setup,
                          planned: planned.map { p in
                              var o = EngineClient.PlannedOperation(operation: p.operation, tool: p.tool, data: p.data, zMin: p.zMin)
                              o.zTop = p.zTop
                              o.refTool = p.refTool
                              return o
                          },
                          paths: paths.map { p in
                              var t = OperationToolpath.decode(operationID: p.operationID, blob: p.moves.unlzfse(), warnings: p.warnings)
                              t.notes = p.notes
                              t.minStickout = p.minStickout
                              return t
                          },
                          operationProgram: operationProgram, operationLines: lines)
    }
}

extension AppModel {
    /// The generated job as it stands, for saving (nil while generating or with nothing made).
    var savedResults: SavedResults? {
        guard !isGenerating, !programs.isEmpty, !sideResults.isEmpty else { return nil }
        return SavedResults(programs: programs.map(SavedResults.Program.init), prepPrograms: prepPrograms.map(SavedResults.Program.init),
                            sides: sideResults.map(SavedResults.Side.init), prep: prepResults.map(SavedResults.Side.init),
                            autoProtrusion: autoProtrusion, bridgeNote: bridgeNote, placedTabs: placedTabs, placedTabZ: placedTabZ.map { [$0.lowerBound, $0.upperBound] }, generatedTuning: generatedTuning,
                            travelIssue: travelIssue, referencePlan: referencePlan)
    }

    /// Puts a saved job back: the programs checked as they were, at chapter 1, step 1.
    func restore(_ r: SavedResults) {
        autoProtrusion = r.autoProtrusion
        referencePlan = r.referencePlan
        generatedTuning = r.generatedTuning
        tuning = r.generatedTuning
        prepPrograms = r.prepPrograms.map(\.program)
        prepResults = r.prep.map(\.result)
        programs = r.programs.map(\.program)
        sideResults = r.sides.map(\.result)
        placedTabs = r.placedTabs
        placedTabZ = r.placedTabZ.flatMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0]...$0[1] : nil }
        bridgeNote = r.bridgeNote
        travelIssue = r.travelIssue
        plannedPrograms = []
        plannedOperationCount = Dictionary(uniqueKeysWithValues: sideResults.map { ($0.side, $0.planned.count) })
        toolpaths = Dictionary((sideResults.first?.paths ?? []).map { ($0.operationID, $0) }, uniquingKeysWith: { a, _ in a })
        switchingView = true
        viewSide = 0
        prepStage = 0
        switchingView = false
        // Framed as a new job is (the table at rest), then at chapter 1, step 1: the stock as
        // bought for a job with prep, else side A's clamping.
        setView(.iso)
        focusWork()
        updateKitShift()
        computeSideAFinal()
        prepareToolChangeSpot()
        showSide(at: 0)
        if let first = jobSteps.first { go(to: first) }
        status = "Toolpaths from the project · about \(Self.duration(programs.reduce(0) { $0 + $1.seconds } + prepPrograms.reduce(0) { $0 + $1.seconds })) of machining"
    }
}
