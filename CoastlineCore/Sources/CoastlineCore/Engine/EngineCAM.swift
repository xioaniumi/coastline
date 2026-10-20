import Foundation
import simd

/// Machining features found by the engine (work frame).
public struct PartFeatures: Sendable {
    public struct Hole: Sendable, Equatable {
        public var x, y, diameter, zTop, zBottom: Double
        public var through: Bool
    }
    public var holes: [Hole]
    public var floorLevels: [Double]
    public var partZ: ClosedRange<Double>
    /// The widest circle that fits each pocket in the outline (narrowest first), mm.
    public var pocketWidths: [Double] = []
    /// Each flat floor's width (the widest circle that fits), mm.
    public var floorWidths: [Double] = []
    /// How deep each of those floors is below the stock face, mm.
    public var floorDepths: [Double] = []
}

extension EngineClient {
    static func rowMajor(_ m: simd_double4x4) -> [Double] {
        (0..<4).flatMap { r in (0..<4).map { c in m[c][r] } }
    }

    public func features(partID: String, transform: simd_double4x4) throws -> PartFeatures {
        let r = try call("features", ["part_id": partID, "transform": Self.rowMajor(transform)])
        let holes = (r.result["holes"] as? [[String: Any]] ?? []).map { h in
            PartFeatures.Hole(x: h["x"] as? Double ?? 0, y: h["y"] as? Double ?? 0, diameter: h["diameter"] as? Double ?? 0,
                              zTop: h["z_top"] as? Double ?? 0, zBottom: h["z_bottom"] as? Double ?? 0,
                              through: h["through"] as? Bool ?? false)
        }
        let floors = (r.result["floors"] as? [[String: Any]] ?? []).compactMap { $0["z"] as? Double }
        let z = r.result["part_z"] as? [Double] ?? [0, 0]
        var f = PartFeatures(holes: holes, floorLevels: floors, partZ: z[0] ... max(z[0], z[1]))
        f.pocketWidths = r.result["pockets"] as? [Double] ?? []
        let fl = (r.result["floors"] as? [[String: Any]] ?? []).filter { ($0["width"] as? Double ?? 0) > 0 }
        f.floorWidths = fl.map { $0["width"] as? Double ?? 0 }
        f.floorDepths = fl.map { max(-($0["z"] as? Double ?? 0), 0) }
        return f
    }

    /// One planned operation, ready for the engine.
    public struct PlannedOperation: Sendable {
        public var operation: Operation
        public var tool: Tool
        public var data: CuttingData
        /// Depth window: never cut below this work Z (two-sided jobs).
        public var zMin: Double?
        /// Cut through to `zMin` even below the part's own bottom (a part at the back of the bar,
        /// freed on holding tabs).
        public var through = false
        /// Where the material starts (work Z), when the face is faced down first.
        public var zTop: Double = 0
        /// Rest finishing: the larger tool that finished before this one.
        public var refTool: Tool?
        /// Areas the tool must keep out of below `keepOutBelow` (work XY): where the clamps are.
        public var keepOut: [(min: SIMD2<Double>, max: SIMD2<Double>)] = []
        public var keepOutBelow: Double = 0
        /// Roughing: how far around the part's outline to clear (mm; nil: one tool + 1 mm).
        public var band: Double?
        /// Where the uncut frame's top is (work Z) for the holder check, when it isn't `zTop`.
        public var frameTop: Double?
        /// Roughing after larger roughing tools on the same side (diameter, the pockets they
        /// took: min_pocket, what they left on the walls): their sweep counts as cleared.
        public var restFrom: [(diameter: Double, minPocket: Double, leave: Double)] = []
        /// 3D finishing in strips: only this work-Y stretch (each strip its own job).
        public var tile: ClosedRange<Double>?
        /// Boring at these circles instead of the part's own holes (reference bores): centre,
        /// diameter, from `top` down to `bottom` (work Z).
        public var holes: [(centre: SIMD2<Double>, diameter: Double, top: Double, bottom: Double)] = []
        public init(operation: Operation, tool: Tool, data: CuttingData, zMin: Double? = nil) {
            self.operation = operation
            self.tool = tool
            self.data = data
            self.zMin = zMin
        }
    }

    /// Generates toolpaths for the operations (work frame). The engine does geometry only;
    /// feeds come from `FeedsEngine` via `data`.
    public func generate(partID: String, transform: simd_double4x4, stockMin: SIMD3<Double>, stockMax: SIMD3<Double>,
                         operations: [PlannedOperation], safeZ: Double = 3) throws -> [OperationToolpath] {
        try generate(partID: partID, transform: transform, stockMin: stockMin, stockMax: stockMax, operations: operations,
                     safeZ: safeZ, tabs: nil, tabBottom: 0).paths
    }

    /// As above, keeping holding tabs between `tabBottom` and `tabBottom + tabs.height` (work Z).
    public func generate(partID: String, transform: simd_double4x4, stockMin: SIMD3<Double>, stockMax: SIMD3<Double>,
                         operations: [PlannedOperation], safeZ: Double = 3, tabs: HoldingTabs?,
                         tabBottom: Double) throws -> (paths: [OperationToolpath], tabs: [PlacedTab]) {
        let ops: [[String: Any]] = operations.map { p in
            // An engraver cuts with its tip: that's the cutter that touches the surface.
            let engraveTip = p.operation.kind == .engrave && [.engraver, .chamferMill].contains(p.tool.kind)
            let cutDiameter = engraveTip ? max(p.tool.tipDiameter, 0.1) : p.tool.diameter
            var d: [String: Any] = [
                "id": p.operation.id.uuidString,
                "kind": p.operation.kind.rawValue,
                "tool": ["diameter": cutDiameter, "flute_length": p.tool.fluteLength, "kind": p.tool.kind.rawValue,
                         "angle": p.tool.angle ?? 118, "corner_radius": p.tool.cornerRadius, "stickout": p.tool.stickout,
                         // The shank above the flutes: wider than the cutter, it mustn't go into the part.
                         "shank_diameter": engraveTip || p.tool.kind == .engraver || p.tool.kind == .drill ? cutDiameter : p.tool.shankDiameter],
                "data": ["feed": p.data.feed, "plunge_feed": p.data.plungeFeed, "ramp_feed": p.data.rampFeed,
                         "stepdown": p.data.stepdown, "stepover": p.data.stepover, "ramp_angle": p.data.rampAngle],
                "leave_radial": p.operation.leaveRadial,
                "leave_axial": p.operation.leaveAxial,
                "face_depth": p.operation.faceDepth,
                "spring_pass": p.operation.springPass,
            ]
            if let z = p.zMin { d["z_min"] = z }  // only when set: JSON has no Swift nil
            if p.through { d["through"] = true }
            if p.operation.kind.is3D {
                var params: [String: Any] = ["scallop": p.operation.scallop, "angle": p.operation.angle, "steep_angle": p.operation.steepAngle]
                if let r = p.refTool {
                    params["ref_tool"] = ["kind": r.kind.rawValue, "diameter": r.diameter, "corner_radius": r.cornerRadius]
                }
                d["params"] = params
            }
            d["z_top"] = p.zTop
            if p.operation.pocketsOnly == true { d["pockets_only"] = true }
            if let m = p.operation.minPocket { d["min_pocket"] = m }
            if let w = p.operation.floorMaxWidth { d["floor_max_width"] = w }
            if let b = p.band { d["band"] = b }
            if p.operation.kind == .adaptive {
                // Roughing never asks for more travel than the CR-1 has (less 1.5 mm for the
                // edge finding and the solver's overshoot): on a bar nearly as wide as the X
                // travel, a strip at its outer edge stays uncut instead.
                let t = MachineProfile.cr1.travel
                d["max_span"] = [t.x - 1.5, t.y - 1.5]
            }
            if let f = p.frameTop { d["frame_top"] = f }
            if let t = p.tile { d["tile"] = [t.lowerBound, t.upperBound] }
            if !p.holes.isEmpty {
                d["holes"] = p.holes.map { ["x": $0.centre.x, "y": $0.centre.y, "diameter": $0.diameter, "z_top": $0.top, "z_bottom": $0.bottom] }
            }
            if !p.restFrom.isEmpty {
                d["rest_from"] = p.restFrom.map { ["diameter": $0.diameter, "min_pocket": $0.minPocket, "leave": $0.leave] }
            }
            if p.operation.kind == .thread, let t = p.operation.thread, let spec = t.thread {
                // The holes it threads: made at about the tap drill (ThreadSpec.fits).
                var th: [String: Any] = ["major": spec.major, "pitch": spec.pitch, "hole_min": spec.holeRange.lowerBound, "hole_max": spec.holeRange.upperBound]
                if let depth = t.depth { th["depth"] = depth }
                d["thread"] = th
            }
            if p.operation.kind == .engrave, let e = p.operation.engraving {
                d["curves"] = e.polylines().map { $0.map { [$0.x, $0.y] } }
                d["engrave_depth"] = e.depth
            }
            if !p.keepOut.isEmpty {
                d["keep_out"] = ["below": p.keepOutBelow, "rects": p.keepOut.map { [$0.min.x, $0.min.y, $0.max.x, $0.max.y] }]
            }
            return d
        }
        var params: [String: Any] = [
            "part_id": partID, "transform": Self.rowMajor(transform),
            "stock_min": [stockMin.x, stockMin.y, stockMin.z], "stock_max": [stockMax.x, stockMax.y, stockMax.z],
            "safe_z": safeZ, "ops": ops,
        ]
        if let tabs {
            var t: [String: Any] = ["count": tabs.count, "width": tabs.width, "height": tabs.height, "z_bottom": tabBottom]
            if let r = tabs.reach { t["reach"] = r }
            if let w = tabs.withinX { t["within_x"] = [w.lowerBound, w.upperBound] }
            if tabs.lift == true { t["lift"] = true }
            if let s = tabs.skinTop { t["skin_top"] = s }
            if let a = tabs.avoid, !a.isEmpty { t["avoid"] = a.map { [$0.x, $0.y, $0.z] } }
            if let f = tabs.frame {
                t["frame"] = ["x0": f.origin.x, "y0": f.origin.y, "cell": f.cell, "cols": f.cols, "rows": f.rows, "bits": f.bits]
            }
            params["tabs"] = t
        }
        let r = try call("generate", params)
        let meta = r.result["ops"] as? [[String: Any]] ?? []
        let paths = zip(operations, zip(meta, r.blobs)).map { p, mb in
            var t = OperationToolpath.decode(operationID: p.operation.id, blob: mb.1, warnings: mb.0["warnings"] as? [String] ?? [])
            t.minStickout = mb.0["min_stickout"] as? Double
            return t
        }
        let placed: [PlacedTab] = (r.result["tabs"] as? [[String: Any]] ?? []).compactMap { t in
            guard let c = t["centre"] as? [Double], let n = t["normal"] as? [Double], let poly = t["poly"] as? [[Double]],
                  c.count == 2, n.count == 2 else { return nil }
            return PlacedTab(centre: SIMD2(c[0], c[1]), normal: SIMD2(n[0], n[1]),
                             corners: poly.compactMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil })
        }
        return (paths, placed)
    }

    /// The part's top height (work Z) at each cell centre of a grid (row-major, NaN off the part):
    /// the reference for the simulation's deviation map.
    /// A printable nest for the part (engine cam/nest.py): its facts and binary STL. `transform`
    /// is the setup that machines the part (the face held in the nest down).
    public struct Nest: Sendable {
        /// Block size (X up in the clamp, Y along, Z), mm.
        public var size: SIMD3<Double>
        /// How much of the part stands above the rim, and its height, mm.
        public var proud: Double
        public var partHeight: Double
        public var triangles: Int
        public var stl: Data
    }

    public func nest(partID: String, transform: simd_double4x4, clearance: Double, wall: Double, floor: Double = 3,
                     minHeight: Double = 24) throws -> Nest {
        let r = try call("nest", ["part_id": partID, "transform": Self.rowMajor(transform), "clearance": clearance, "wall": wall,
                                  "floor": floor, "min_height": minHeight])
        let s = r.result["size"] as? [Double] ?? [0, 0, 0]
        return Nest(size: SIMD3(s[0], s[1], s[2]), proud: r.result["proud"] as? Double ?? 0, partHeight: r.result["part_height"] as? Double ?? 0,
                    triangles: r.result["triangles"] as? Int ?? 0, stl: r.blobs.first ?? Data())
    }

    public func heightField(partID: String, transform: simd_double4x4, origin: SIMD2<Double>, cell: Double,
                            cols: Int, rows: Int) throws -> [Float] {
        let r = try call("height_field", ["part_id": partID, "transform": Self.rowMajor(transform), "x0": origin.x, "y0": origin.y,
                                          "cell": cell, "cols": cols, "rows": rows])
        return r.blobs.first?.littleEndianArray(of: Float.self) ?? []
    }
}
