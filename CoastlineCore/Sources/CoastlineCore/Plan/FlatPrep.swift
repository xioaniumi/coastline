import Foundation

/// Squaring and sizing oversized bar stock the way Coast Runner's Universal Clamp cutcode does
/// it: the bar lies **flat** on the riser plate, registered against **one** squaring stop (an
/// acetal brick bolted into both T-slots, its spindle-side face level with the table's edge) and
/// held down with two 3" screw C-clamps that wrap the table's back edge. Upright clamping on the
/// bed alone is too risky for heavy cuts, so it isn't offered.
///
/// Because the stop is bolted into the T-slots, its spindle-side face can't move back. So the
/// bar always sticks out past it toward the spindle by the depth being cut plus a clearance:
/// the tool never comes within `stopClearance` of the stop, the riser or a clamp.
///
/// 1. Sawn short ends can't register squarely, so they're faced first: the bar turned with its
///    length toward the spindle, an extruded (straight) long side against the stop. The whole bar
///    has to sit on the table for that (the C-clamps reach around the table's back edge), so a
///    long bar is sawn to the length the part needs first.
/// 2. Then a faced end goes against the stop and the long edge toward the spindle is side-milled
///    down, in rounds: each round the bar is slid out by the next round's depth, so it never
///    overhangs the riser by more than one round (a short, stiff overhang that is all waste).
public enum FlatPrep {
    /// The riser plate (the kit's aluminium block) and the table plate under it, mm.
    public static let riserHeight = 12.7
    public static let tableThickness = 14.72  // measured: top −31.0 (nominal) to bottom −45.72
    public static let faceAllowance = 0.5
    /// Closest the tool tip comes to the stop's (and riser's) spindle-side face, mm.
    public static let stopClearance = 2.0
    /// How far a sawn end sticks out past the stop for facing.
    public static let endProtrusion = faceAllowance + stopClearance + 0.5
    /// A 3" C-clamp: jaw opening and throat depth (frame to screw axis), mm.
    public static let clampOpening = 76.0
    public static let clampThroat = 50.0
    /// The parallel laid across a bar that overhangs the bed's back edge (bridge clamping).
    public static let bridgeSection = 12.7
    /// How far the C-clamps turn about their screws when the bar reaches past the bed (rad).
    public static let angledClamp = Double.pi / 4

    /// Where things are on the CR-1's table (model coordinates: X up, Z toward the spindle).
    public struct Table: Sendable, Equatable {
        public var topX = -31.12
        /// The table's spindle-side ("north") edge and its back edge (toward you).
        public var northZ = -2.4
        /// The T-slot bed's back edge across its middle (raycast on the CR-1 model; only the
        /// rounded ears at its far ends reach −77.4).
        public var backZ = -67.12
        /// The squaring stop's spindle-side face (bolted into both T-slots).
        public var stopNorthZ = -2.27
        public init() {}
        /// The C-clamp frame at the bed's height: from the screw axis to the frame's inner face
        /// (it curves forward near the fixed jaw, so less than the 50 mm throat), and its half
        /// width across. Measured on the clamp's mesh (AppModel.prepTable); these defaults are
        /// The 3" clamp model.
        public var clampInnerReach = 32.3
        public var clampHalfWidth = 6.5
        public init(topX: Double, northZ: Double = -2.4, backZ: Double = -67.12, stopNorthZ: Double = -2.27) {
            self.topX = topX
            self.northZ = northZ
            self.backZ = backZ
            self.stopNorthZ = stopNorthZ
        }
        /// The C-clamp frame sits just behind the table's back edge.
        /// The C-clamp is pushed on until its frame touches the bed's back edge.
        public var clampSpineZ: Double { backZ - 0.3 }
        /// Furthest toward the spindle a C-clamp's screw can press, square to the bed.
        public var clampReachZ: Double { padLimit(angle: 0) }
        /// Furthest toward the spindle the pad of a clamp turned by `angle` can be with its frame
        /// still behind the bed's back edge (the frame's inner corner at the bed's height swings
        /// forward as it turns).
        public func padLimit(angle a: Double) -> Double {
            backZ - 0.3 + clampInnerReach * cos(a) - clampHalfWidth * abs(sin(a))
        }
        /// Longest piece that sits on the table with its end protruding past the stop.
        public var maxEndFacingLength: Double { (stopNorthZ + FlatPrep.endProtrusion) - (backZ - 0.5) }
        /// Shortest piece the C-clamps reach (screw ≥ 6 mm in from its back end).
        public var minClampedDepth: Double { (stopNorthZ + FlatPrep.endProtrusion) - (clampReachZ - 6) }
    }

    public enum Kind: Sendable, Equatable {
        case faceEnd(Int)            // 0 = end A, 1 = end B (to length)
        case edge(round: Int, of: Int)
    }

    /// One clamping of the bar on the stop, and what's cut in it.
    public struct Stage: Sendable, Equatable {
        public var kind: Kind
        public var title: String
        /// The bar in this stage's work frame: X its thickness (up), Y along the table, Z toward
        /// the spindle (the face being cut is at Z0).
        public var stock: SIMD3<Double>
        /// Depth cut off the face, and how far the face sticks out past the stop.
        public var cut: Double
        public var protrusion: Double
        /// Where along the bar (stage Y) the edge is cut; nil: its whole length. Shoulders are
        /// the two ends only.
        public var spans: [ClosedRange<Double>]?
        /// Shoulders: how far the uncut middle stands above the face being cut (rapids go over it).
        public var raised = 0.0
        /// The bar's other long edge toward the spindle (bottom shoulders, after turning it over).
        public var otherEdge = false
        /// The stop touches the bar's left long side (end facing) or its left end (edge).
        public init(kind: Kind, title: String, stock: SIMD3<Double>, cut: Double, protrusion: Double) {
            self.kind = kind
            self.title = title
            self.stock = stock
            self.cut = cut
            self.protrusion = protrusion
        }
        public var stopAgainstEnd: Bool { if case .edge = kind { return true } else { return false } }
        public var isEdge: Bool { stopAgainstEnd }
    }

    public struct Plan: Sendable, Equatable {
        /// The bar lying flat: thickness (vertical), length, width (the dimension cut down).
        public var thickness: Double
        public var length: Double
        public var width: Double
        public var cut: Double
        public var target: Double
        /// Saw the bar to this length first (it's too long to face its ends on the table).
        public var sawLength: Double?
        public var faceEnds: Bool
        /// Length after sawing and facing.
        public var finalLength: Double
        public var stages: [Stage]
        public var issues: [Issue]
        public var rounds: Int { stages.filter(\.isEdge).count }
        public init(thickness: Double, length: Double, width: Double, cut: Double, target: Double, sawLength: Double?, faceEnds: Bool,
                    finalLength: Double, stages: [Stage], issues: [Issue]) {
            self.thickness = thickness
            self.length = length
            self.width = width
            self.cut = cut
            self.target = target
            self.sawLength = sawLength
            self.faceEnds = faceEnds
            self.finalLength = finalLength
            self.stages = stages
            self.issues = issues
        }
    }

    /// Deepest edge cut per clamping: a stiff overhang of no more than ~¾ of the bar's
    /// thickness, 6–18 mm.
    public static func maxRoundCut(thickness t: Double) -> Double { min(max(t * 0.75, 6), 18) }

    /// - Parameters: raw: the stock as bought (work X = the dimension to reduce); target: the
    ///   height the clamp kit needs; neededLength: how long the part setup needs the bar.
    /// - extrudedAlong: the work axis the bar was extruded along (1 = Y, 2 = Z; nil = the
    ///   longer of the two). Along X (the dimension milled down) the edge cut itself takes the
    ///   sawn end off, so only the other end would need facing.
    public static func plan(raw: SIMD3<Double>, target: Double, sawn: Bool, neededLength: Double? = nil,
                            table: Table = Table(), extrudedAlong: Int? = nil, faceEnd: Bool? = nil, rounds: Int? = nil,
                            shoulderLength: Double? = nil, shoulderBottom: Double = 0) -> Plan {
        let alongY = extrudedAlong.map { $0 == 1 } ?? (raw.y >= raw.z)
        let t = alongY ? raw.z : raw.y, l = alongY ? raw.y : raw.z, w = raw.x
        let cut = max(w - target, 0)
        var issues: [Issue] = []
        // Coast Runner's way: face ONE sawn end square (long side against the stop), then push
        // that end against the stop and take the long edge down. The bar keeps its length: the
        // clamp kit takes long stock. A long bar overhangs the bed for the end; a parallel laid
        // across it, clamped at both ends by the C-clamps beside it, holds it (SideClamps).
        let faceEnds = faceEnd ?? (sawn && extrudedAlong != 0)
        if sawn && extrudedAlong == 0 {
            issues.append(Issue(.info, "The bar runs along the edge being milled down, so that cut squares one sawn end; the other end stays as sawn (it sits against the clamp kit's back, so it doesn't need to be square)."))
        }
        _ = neededLength
        let length = l
        let sawLength: Double? = nil
        var stages: [Stage] = []
        if faceEnds {
            stages.append(Stage(kind: .faceEnd(0), title: "Face end A", stock: SIMD3(t, w, length),
                                cut: faceAllowance, protrusion: endProtrusion))
        }
        let finalLength = faceEnds ? length - faceAllowance : length
        if cut > 0.01 {
            let fewest = max(Int((cut / maxRoundCut(thickness: t)).rounded(.up)), 1)
            let n = max(rounds ?? fewest, 1)
            if n < fewest {
                issues.append(Issue(.warning, "\(n) round\(n == 1 ? "" : "s") leave\(n == 1 ? "s" : "") \(Length.mm(cut / Double(n))) mm overhanging the riser each time: more than the \(Length.mm(maxRoundCut(thickness: t))) mm a \(Length.mm(t)) mm bar takes without chatter."))
            }
            let each = cut / Double(n)
            var width = w
            for k in 0..<n {
                var title = n == 1 ? "Mill the edge down to \(Length.mm(target)) mm"
                    : "Edge, round \(k + 1) of \(n) (to \(Length.mm(width - each)) mm)"
                if shoulderLength != nil {
                    title = n == 1 ? "Mill the shoulders down to \(Length.mm(target)) mm"
                        : "Shoulders, round \(k + 1) of \(n) (to \(Length.mm(width - each)) mm)"
                }
                var stage = Stage(kind: .edge(round: k, of: n), title: title, stock: SIMD3(t, finalLength, width),
                                  cut: each, protrusion: each + stopClearance)
                if let ls = shoulderLength {
                    stage.spans = [(-finalLength / 2)...(-finalLength / 2 + ls), (finalLength / 2 - ls)...(finalLength / 2)]
                    stage.raised = Double(k) * each
                }
                stages.append(stage)
                width -= each
            }
            if n > 1 {
                issues.append(Issue(.info, "\(Length.mm(cut)) mm comes off in \(n) rounds of \(Length.mm(each)) mm. Between rounds you slide the bar out by one round, so it never overhangs the riser by more than that."))
            }

        }
        // Four-corner shoulders: the bar turned over (its other long edge toward the spindle,
        // end A still on the stop) and the bottom of the ends milled the same way.
        if let ls = shoulderLength, shoulderBottom > 0.01 {
            let n = max(Int((shoulderBottom / maxRoundCut(thickness: t)).rounded(.up)), 1)
            let each = shoulderBottom / Double(n)
            for k in 0..<n {
                var stage = Stage(kind: .edge(round: k, of: n), title: n == 1 ? "Bottom shoulders, \(Length.mm(shoulderBottom)) mm"
                                    : "Bottom shoulders, round \(k + 1) of \(n)",
                                  stock: SIMD3(t, finalLength, w), cut: each, protrusion: each + stopClearance)
                stage.spans = [(-finalLength / 2)...(-finalLength / 2 + ls), (finalLength / 2 - ls)...(finalLength / 2)]
                stage.raised = Double(k) * each
                stage.otherEdge = true
                stages.append(stage)
            }
            issues.append(Issue(.info, "Then the bar is turned over and the bottom of the ends comes off too (\(Length.mm(shoulderBottom)) mm): the middle hangs that much lower in the clamp kit."))
        }
        return Plan(thickness: t, length: l, width: w, cut: cut, target: target, sawLength: sawLength, faceEnds: faceEnds,
                    finalLength: finalLength, stages: stages, issues: issues)
    }

    /// One stage's program in its own work frame (origin at the centre of the face toward the
    /// spindle, X up, Y along the table, Z toward the spindle).
    public struct Program: Sendable {
        public var stage: Stage
        public var title: String { stage.title }
        public var stock: SIMD3<Double> { stage.stock }
        public var moves: [Move]
    }

    public static func programs(_ p: Plan, tool: Tool, material: Material, machine: MachineProfile = .cr1) -> [Program] {
        p.stages.map { s in
            switch s.kind {
            case .faceEnd:
                let data = FeedsEngine.compute(tool: tool, material: material, kind: .facing, machine: machine)
                return Program(stage: s, moves: FacingProgram.moves(width: s.stock.x, length: s.stock.y, depth: s.cut, tool: tool, data: data))
            case .edge:
                // Rapids 2 mm above the face (the face sits near the end of Z travel); the raised
                // middle is passed over the top of the bar (in X), not toward the spindle.
                return Program(stage: s, moves: edgeFacing(stock: s.stock, depth: s.cut, tool: tool, material: material, machine: machine,
                                                           spans: s.spans, safeZ: 2))
            }
        }
    }

    /// Takes the band off the edge toward the spindle by **facing it in layers**: each layer is
    /// shallow (¼ of the tool's diameter) and wide (40 %), covering the whole edge face before
    /// the next one starts, so what's left is always one solid block. Deep, narrow passes
    /// (side-milling 2×D deep) would instead leave a thin fin along the bottom of every level,
    /// held only at its root: it chatters and snaps off as a burr. Every layer enters from
    /// beside the bar, never by plunging into it.
    /// With `spans` (shoulders) only those stretches of the edge are faced, each entered from
    /// the bar's open end; the tool's edge stops at the shoulder's wall.
    static func edgeFacing(stock s: SIMD3<Double>, depth: Double, tool: Tool, material: Material, machine: MachineProfile,
                           spans: [ClosedRange<Double>]? = nil, safeZ: Double = 3) -> [Move] {
        guard depth > 0 else { return [] }
        var d = FeedsEngine.compute(tool: tool, material: material, kind: .facing, machine: machine)
        d.stepdown = min(max(0.25 * tool.diameter, 0.3), max(tool.fluteLength - 1, 0.3))
        d.stepover = 0.4 * tool.diameter
        guard let spans else { return FacingProgram.moves(width: s.x, length: s.y, depth: depth, tool: tool, data: d) }
        let r = tool.diameter / 2
        let overX = s.x / 2 + r + 3  // above the bar's top: clear of the raised middle
        var out: [Move] = []
        for (k, span) in spans.enumerated() {
            let moves = spanMoves(span)
            if k > 0, let last = out.last, let first = moves.first {
                out.append(Move(.rapid, x: overX, y: last.y, z: last.z))
                out.append(Move(.rapid, x: overX, y: first.y, z: first.z))
            }
            out += moves
        }
        return out
        func spanMoves(_ span: ClosedRange<Double>) -> [Move] {
            // Tool centre: from outside the open end to one radius short of the wall.
            let atLow = span.lowerBound <= -s.y / 2 + 1e-6
            let range = atLow ? (span.lowerBound - r - 1)...(span.upperBound - r) : (span.lowerBound + r)...(span.upperBound + r + 1)
            return FacingProgram.moves(width: s.x, length: s.y, depth: depth, tool: tool, data: d, yRange: range, startHigh: !atLow,
                                       safeZ: safeZ)
        }
    }

    /// Side-mills a full-height band off the edge toward the spindle, `depth` deep: passes along
    /// Y with a light radial step down through the bar's height (X), deep axial steps (Z),
    /// climb cutting, entering from outside the bar. The bar overhangs the riser, so the tool
    /// runs out below it; the stop is behind the deepest level by `stopClearance`.
    static func sideMill(stock s: SIMD3<Double>, depth: Double, tool: Tool, material: Material, machine: MachineProfile) -> [Move] {
        guard depth > 0 else { return [] }
        let d = FeedsEngine.compute(tool: tool, material: material, kind: .adaptive, machine: machine)
        let r = tool.diameter / 2
        let ap = min(2 * tool.diameter, max(tool.fluteLength - 1, 1), depth)
        let ae = max(min(d.stepover, tool.diameter * 0.3), 0.05)
        var zs: [Double] = []
        var z = 0.0
        while z > -depth + 1e-9 { z = max(z - ap, -depth); zs.append(z) }
        var xs: [Double] = []
        var x = s.x / 2 + r - ae
        while x > -s.x / 2 - r - 0.5 { xs.append(x); x -= ae }
        xs.append(-s.x / 2 - r - 0.5)
        let yIn = s.y / 2 + r + 2, yOut = -s.y / 2 - r - 2
        var moves: [Move] = []
        for zl in zs {
            for xv in xs {
                moves.append(Move(.rapid, x: xv, y: yIn, z: 3))
                moves.append(Move(.rapid, x: xv, y: yIn, z: 1))
                moves.append(Move(.plunge, x: xv, y: yIn, z: zl, feed: d.plungeFeed))
                moves.append(Move(.cut, x: xv, y: yOut, z: zl, feed: d.feed))
                moves.append(Move(.rapid, x: xv, y: yOut, z: 3))
            }
        }
        return moves
    }
}
