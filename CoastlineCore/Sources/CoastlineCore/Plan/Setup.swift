import Foundation
import simd

/// One setup: how the part sits in the stock and how the stock sits in the CR-1.
///
/// **Work frame** (the WCS the G-code uses), aligned with the machine axes:
/// - +X up (the table's vertical travel; X− lifts the table, so the tool moves "down" the work)
/// - +Y to the operator's right (gantry)
/// - +Z along the spindle toward the tool: the tool comes from +Z and cuts toward −Z
/// - origin: the centre of the stock's top face (the face toward the spindle), so Z = 0 is
///   the stock surface and the part is below it. This matches Coast Runner's edge-finding
///   (midpoints with M100) and paper touch-off on the top face.
///
/// The CR-1 is a horizontal-spindle mill: "top face" means the face pointing at the spindle,
/// and the stock stands on the table with its X extent vertical.
public struct Setup: Equatable, Sendable, Codable {
    /// Which part axis points at the spindle (becomes +Z of the work frame).
    public enum Facing: String, CaseIterable, Sendable, Codable {
        case plusZ, minusZ, plusX, minusX, plusY, minusY
        public var title: String {
            switch self {
            case .plusZ: "+Z (top)"
            case .minusZ: "−Z (bottom)"
            case .plusX: "+X"
            case .minusX: "−X"
            case .plusY: "+Y"
            case .minusY: "−Y"
            }
        }
    }

    public var facing: Facing = .plusZ
    /// Quarter turns about the tool axis (0…3).
    public var spin: Int = 0
    /// Stock dimension (0, 1, 2 = its x, y, z) that runs along each work axis.
    /// Default: thinnest along Z (toward the spindle), longest along Y (the long gantry travel).
    public var stockAxes: [Int] = [1, 0, 2]
    /// Material left above the part, to face off first, mm.
    public var topAllowance: Double = 0.5
    /// Part offset from the stock centre in work X and Y, mm.
    public var partOffsetX: Double = 0
    public var partOffsetY: Double = 0
    /// How far the stock's face sticks out past the universal clamp's jaws, mm (parallels behind
    /// the stock set it).
    public var clampProtrusion: Double = 2
    /// Mill oversized stock down to this height (work X) on the side clamps first, so it fits
    /// the clamp kit. nil = use the stock as it is.
    public var downsizeHeight: Double?
    /// The bar's length after the prep sawed and faced it (its longer side across the work).
    public var prepLength: Double?
    /// Uniform scale of the imported part (1 = as modelled), so a big design can be machined
    /// smaller from the stock there is.
    public var partScale: Double = 1
    /// Adjustments to each prep clamping (stop along the slots, C-clamps), by stage.
    public var prepOverrides: [PrepOverride] = []
    /// Prep steps chosen by hand: face end A first (nil: when sawn), number of edge rounds
    /// (nil: as few as the overhang allows).
    public var prepFaceEnd: Bool?
    public var prepRounds: Int?
    /// Holding path B: the whole job flat on the bed (stop, riser, C-clamps) instead of the
    /// clamp kit, with the user's adjustments to the stop and clamps.
    public var onBed = false
    public var bedJobOverride = PrepOverride()
    /// Holding path D: a reduced-height shoulder at each end of the bar for the clamp kit to
    /// grip; the full-height middle carries the part above the jaws.
    public var shoulders: Shoulders?
    /// The clamp kit: each universal clamp moved along the T-slots from where Coastline
    /// put it (mm, model Y).
    public var kitClampShift: [Double] = []
    /// How many universal clamps hold the stock: nil lets Coastline choose
    /// (`UniversalClamp.suggestedCount`), 1 or 2 is the user's override.
    public var kitClampCount: Int?
    /// Batching: this many copies of the part side by side along the bar (Y).
    public var copies = 1

    /// The copies' Y offsets from the part's place, centred: each copy's roughing band (one
    /// roughing tool + 1 mm around it) plus a 3 mm web of frame between neighbours.
    public static func copyOffsets(count n: Int, partY: Double, toolDiameter d: Double = 6.35) -> [Double] {
        guard n > 1 else { return [0] }
        let pitch = copyPitch(partY: partY, toolDiameter: d)
        return (0..<n).map { (Double($0) - Double(n - 1) / 2) * pitch }
    }

    public static func copyPitch(partY: Double, toolDiameter d: Double = 6.35) -> Double {
        partY + 2 * (d + 1) + GripZones.grip
    }

    /// How many copies fit along the stock (Y) with the frame's room at both ends.
    public static func maxCopies(stockY: Double, partY: Double, toolDiameter d: Double = 6.35) -> Int {
        let pitch = copyPitch(partY: partY, toolDiameter: d)
        let room = stockY - 2 * (d + 1) - partY  // the first copy, centred with its band
        return max(1 + Int((room / pitch).rounded(.down) + 0.0), 1)
    }

    public struct Shoulders: Codable, Equatable, Sendable {
        /// Stock height at the shoulders (work X, what the clamps grip) and each one's length (Y).
        public var height: Double
        public var length: Double
        /// Also milled off the bottom edge at the ends (four-corner shoulders): the full-height
        /// middle then hangs this much lower, between the clamps, toward the bed.
        public var bottom: Double = 0
        public init(height: Double, length: Double = Shoulders.defaultLength, bottom: Double = 0) {
            self.height = height
            self.length = length
            self.bottom = bottom
        }
        /// Centred under a universal clamp (19 mm wide, 12 mm in from the end) with room each side.
        public static let defaultLength = 24.0

        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            height = try c.decode(Double.self, forKey: .height)
            length = try c.decode(Double.self, forKey: .length)
            bottom = try c.decodeIfPresent(Double.self, forKey: .bottom) ?? 0
        }

        /// What's milled off the top at the ends, for a bar this tall.
        public func top(barHeight x: Double) -> Double { max(x - bottom - height, 0) }
    }

    /// The height the bed prep brings the stock to where the clamps grip (mill-down or shoulders).
    public var prepHeight: Double? { downsizeHeight ?? shoulders?.height }

    /// What the shoulders take off, as boxes in the work frame (stock centred, face at Z0).
    public func shoulderCuts(stockSize s: SIMD3<Double>) -> [(min: SIMD3<Double>, max: SIMD3<Double>)] {
        guard let sh = shoulders, sh.height + sh.bottom < s.x + 1e-9 else { return [] }
        let xb = -s.x / 2 + sh.bottom, xt = xb + sh.height
        var out: [(min: SIMD3<Double>, max: SIMD3<Double>)] = []
        for (y0, y1) in [(-s.y / 2, -s.y / 2 + sh.length), (s.y / 2 - sh.length, s.y / 2)] {
            if xt < s.x / 2 - 1e-9 { out.append((SIMD3(xt, y0, -s.z), SIMD3(s.x / 2, y1, 0))) }
            if sh.bottom > 1e-9 { out.append((SIMD3(-s.x / 2, y0, -s.z), SIMD3(xb, y1, 0))) }
        }
        return out
    }

    /// The stock with its shoulders as triangles (work frame): a stepped profile in X–Y
    /// extruded along Z. Without shoulders, the box.
    public func stockTriangles(stockSize s: SIMD3<Double>) -> [SIMD3<Double>] {
        let lo = SIMD3(-s.x / 2, -s.y / 2, -s.z), hi = SIMD3(s.x / 2, s.y / 2, 0)
        guard let sh = shoulders, 2 * sh.length < s.y, sh.height + sh.bottom < s.x - 1e-9 || sh.bottom > 1e-9 else {
            return Collision.boxTriangles(min: lo, max: hi)
        }
        let xb = lo.x + sh.bottom, xt = min(xb + sh.height, hi.x), y0 = lo.y + sh.length, y1 = hi.y - sh.length
        // The profile (X–Y), counter-clockwise seen from +Z: the grip strip at each end, the
        // full height in the middle.
        let poly: [SIMD2<Double>] = [SIMD2(xb, lo.y), SIMD2(xt, lo.y), SIMD2(xt, y0), SIMD2(hi.x, y0), SIMD2(hi.x, y1), SIMD2(xt, y1),
                                     SIMD2(xt, hi.y), SIMD2(xb, hi.y), SIMD2(xb, y1), SIMD2(lo.x, y1), SIMD2(lo.x, y0), SIMD2(xb, y0)]
        var t: [SIMD3<Double>] = []
        for k in poly.indices {
            let a = poly[k], b = poly[(k + 1) % poly.count]
            guard simd_distance(a, b) > 1e-9 else { continue }
            let a0 = SIMD3(a.x, a.y, lo.z), b0 = SIMD3(b.x, b.y, lo.z), a1 = SIMD3(a.x, a.y, hi.z), b1 = SIMD3(b.x, b.y, hi.z)
            t += [a0, b0, b1, a0, b1, a1]
        }
        // Caps: the middle (full height) and the two ends (grip strip).
        for z in [lo.z, hi.z] {
            for (p, q) in [(SIMD2(lo.x, y0), SIMD2(hi.x, y1)), (SIMD2(xb, lo.y), SIMD2(xt, y0)), (SIMD2(xb, y1), SIMD2(xt, hi.y))] {
                let c = [SIMD3(p.x, p.y, z), SIMD3(q.x, p.y, z), SIMD3(q.x, q.y, z), SIMD3(p.x, q.y, z)]
                t += z > lo.z ? [c[0], c[1], c[2], c[0], c[2], c[3]] : [c[0], c[2], c[1], c[0], c[3], c[2]]
            }
        }
        return t
    }
    /// Clamp with the soft jaws (the blocks under the top screws). Off: the screws press the
    /// stock directly, for 6.4 mm taller stock (a compromise; see UniversalClamp).
    public var clampSoftJaw = true
    /// Side B of a two-sided job: the stock is turned front-to-back about the vertical (X) axis,
    /// so the back of the part faces the spindle.
    public var flipped = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case facing, spin, stockAxes, topAllowance, partOffsetX, partOffsetY, clampProtrusion, flipped, downsizeHeight, clampSoftJaw, prepLength, partScale, prepOverrides, prepFaceEnd, prepRounds, onBed, bedJobOverride, shoulders, kitClampShift, kitClampCount, copies
    }

    /// Tolerant decoding: sessions saved by older versions miss newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        facing = try c.decodeIfPresent(Facing.self, forKey: .facing) ?? .plusZ
        spin = try c.decodeIfPresent(Int.self, forKey: .spin) ?? 0
        stockAxes = try c.decodeIfPresent([Int].self, forKey: .stockAxes) ?? [1, 0, 2]
        topAllowance = try c.decodeIfPresent(Double.self, forKey: .topAllowance) ?? 0.5
        partOffsetX = try c.decodeIfPresent(Double.self, forKey: .partOffsetX) ?? 0
        partOffsetY = try c.decodeIfPresent(Double.self, forKey: .partOffsetY) ?? 0
        clampProtrusion = try c.decodeIfPresent(Double.self, forKey: .clampProtrusion) ?? 2
        flipped = try c.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
        downsizeHeight = try c.decodeIfPresent(Double.self, forKey: .downsizeHeight)
        prepLength = try c.decodeIfPresent(Double.self, forKey: .prepLength)
        partScale = try c.decodeIfPresent(Double.self, forKey: .partScale) ?? 1
        prepOverrides = try c.decodeIfPresent([PrepOverride].self, forKey: .prepOverrides) ?? []
        prepFaceEnd = try c.decodeIfPresent(Bool.self, forKey: .prepFaceEnd)
        prepRounds = try c.decodeIfPresent(Int.self, forKey: .prepRounds)
        onBed = try c.decodeIfPresent(Bool.self, forKey: .onBed) ?? false
        bedJobOverride = try c.decodeIfPresent(PrepOverride.self, forKey: .bedJobOverride) ?? PrepOverride()
        shoulders = try c.decodeIfPresent(Shoulders.self, forKey: .shoulders)
        kitClampShift = try c.decodeIfPresent([Double].self, forKey: .kitClampShift) ?? []
        kitClampCount = try c.decodeIfPresent(Int.self, forKey: .kitClampCount)
        copies = max(try c.decodeIfPresent(Int.self, forKey: .copies) ?? 1, 1)
        clampSoftJaw = try c.decodeIfPresent(Bool.self, forKey: .clampSoftJaw) ?? true
    }

    // MARK: Part transform

    /// Rotation from part coordinates into the work frame.
    public var partRotation: simd_double3x3 {
        let base: simd_double3x3
        switch facing {
        case .plusZ: base = matrix_identity_double3x3
        case .minusZ: base = Self.rotation(axis: SIMD3(1, 0, 0), quarterTurns: 2)
        case .plusX: base = Self.rotation(axis: SIMD3(0, 1, 0), quarterTurns: -1)
        case .minusX: base = Self.rotation(axis: SIMD3(0, 1, 0), quarterTurns: 1)
        case .plusY: base = Self.rotation(axis: SIMD3(1, 0, 0), quarterTurns: 1)
        case .minusY: base = Self.rotation(axis: SIMD3(1, 0, 0), quarterTurns: -1)
        }
        let r = Self.rotation(axis: SIMD3(0, 0, 1), quarterTurns: spin) * base
        return flipped ? Self.rotation(axis: SIMD3(1, 0, 0), quarterTurns: 2) * r : r
    }

    /// The part turned a quarter turn (or several) about a work axis (0 = X, 1 = Y, 2 = Z), as
    /// the orientation (facing + spin) that gives exactly that rotation.
    public func turned(about axis: Int, quarterTurns q: Int) -> Setup {
        var unit = SIMD3<Double>(0, 0, 0)
        unit[axis] = 1
        var plain = self
        plain.flipped = false
        let want = Self.rotation(axis: unit, quarterTurns: q) * plain.partRotation
        var out = self
        for f in Facing.allCases {
            for spin in 0..<4 {
                var t = plain
                t.facing = f
                t.spin = spin
                let r = t.partRotation
                if (0..<3).allSatisfy({ simd_length(r[$0] - want[$0]) < 1e-9 }) {
                    out.facing = f
                    out.spin = spin
                    return out
                }
            }
        }
        return out
    }

    /// Side B of this setup for the same stock: turned front-to-back about X, so work y → −y and
    /// z → −T − z. The part keeps its place in the stock: its top is now as far below the new
    /// face as its bottom was above the old stock bottom.
    public func sideB(partMin lo: SIMD3<Double>, partMax hi: SIMD3<Double>, stock: StockItem) -> Setup {
        var b = self
        b.flipped = true
        let thickness = stockSize(stock).z
        let (rlo, rhi) = rotatedPartBounds(min: lo, max: hi)
        b.topAllowance = thickness - topAllowance - (rhi.z - rlo.z)
        b.partOffsetY = -partOffsetY
        return b
    }

    /// Maps a side-A work Z to side B (−T − z).
    public func sideBZ(_ z: Double, stock: StockItem) -> Double { -stockSize(stock).z - z }

    /// Exact quarter-turn rotation (no floating-point drift: entries are −1, 0 or 1).
    static func rotation(axis: SIMD3<Double>, quarterTurns: Int) -> simd_double3x3 {
        let q = ((quarterTurns % 4) + 4) % 4
        let c = [1.0, 0, -1, 0][q], s = [0.0, 1, 0, -1][q]
        let (x, y, z) = (axis.x, axis.y, axis.z)
        // Rodrigues for a unit axis, with exact c/s.
        return simd_double3x3(rows: [
            SIMD3(c + x * x * (1 - c), x * y * (1 - c) - z * s, x * z * (1 - c) + y * s),
            SIMD3(y * x * (1 - c) + z * s, c + y * y * (1 - c), y * z * (1 - c) - x * s),
            SIMD3(z * x * (1 - c) - y * s, z * y * (1 - c) + x * s, c + z * z * (1 - c)),
        ])
    }

    /// Part bounds (part coordinates) → rotated bounds in the work frame (before translation).
    public func rotatedPartBounds(min lo: SIMD3<Double>, max hi: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        var rlo = SIMD3<Double>(repeating: .infinity), rhi = -rlo
        for i in 0..<8 {
            let c = SIMD3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z)
            let r = partRotation * c * partScale
            rlo = simd_min(rlo, r)
            rhi = simd_max(rhi, r)
        }
        return (rlo, rhi)
    }

    /// Full part → work transform (rotation, then translation that puts the part's top
    /// `topAllowance` below Z = 0 and centres it in X/Y plus the offsets).
    public func partToWork(partMin lo: SIMD3<Double>, partMax hi: SIMD3<Double>) -> simd_double4x4 {
        let (rlo, rhi) = rotatedPartBounds(min: lo, max: hi)
        let t = SIMD3(partOffsetX - (rlo.x + rhi.x) / 2,
                      partOffsetY - (rlo.y + rhi.y) / 2,
                      -topAllowance - rhi.z)
        let r = partRotation * partScale
        return simd_double4x4(columns: (
            SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), SIMD4(t, 1)
        ))
    }

    // MARK: Stock

    /// Stock size along work X, Y, Z, after milling it down if that's planned.
    public func stockSize(_ stock: StockItem) -> SIMD3<Double> {
        var s = rawStockSize(stock)
        if let h = downsizeHeight, h < s.x { s.x = h }
        if let l = prepLength {
            if s.y >= s.z { s.y = min(s.y, l) } else { s.z = min(s.z, l) }
        }
        return s
    }

    /// The stock as bought, along work X, Y, Z.
    public func rawStockSize(_ stock: StockItem) -> SIMD3<Double> {
        let e = [stock.envelope.x, stock.envelope.y, stock.envelope.z]
        return SIMD3(e[stockAxes[0]], e[stockAxes[1]], e[stockAxes[2]])
    }

    /// Stock box in the work frame.
    public func stockBox(_ stock: StockItem) -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        let s = stockSize(stock)
        return (SIMD3(-s.x / 2, -s.y / 2, -s.z), SIMD3(s.x / 2, s.y / 2, 0))
    }

    /// The default stock arrangement: thinnest dimension toward the spindle, longest along Y.
    public static func defaultStockAxes(_ stock: StockItem) -> [Int] {
        let e = [stock.envelope.x, stock.envelope.y, stock.envelope.z]
        let order = [0, 1, 2].sorted { e[$0] < e[$1] }  // thin, mid, long
        return [order[1], order[2], order[0]]           // X ← mid, Y ← long, Z ← thin
    }

    /// The default part orientation: thinnest part dimension along the tool axis, longest along Y.
    public static func defaultOrientation(partMin lo: SIMD3<Double>, partMax hi: SIMD3<Double>) -> (Facing, Int) {
        let size = hi - lo
        let thin = [0, 1, 2].min { size[$0] < size[$1] }!
        let facing: Facing = [.plusX, .plusY, .plusZ][thin]
        var best = (facing, 0)
        for spin in 0..<4 {
            var s = Setup()
            s.facing = facing
            s.spin = spin
            let (rlo, rhi) = s.rotatedPartBounds(min: lo, max: hi)
            if rhi.y - rlo.y >= rhi.x - rlo.x - 1e-9 { best = (facing, spin); break }
        }
        return best
    }
}

/// Fit checks for a setup. Plain-language results, like the inventory checks.
public enum SetupChecks {
    public static func check(_ setup: Setup, partMin lo: SIMD3<Double>, partMax hi: SIMD3<Double>,
                             stock: StockItem, machine: MachineProfile = .cr1) -> [Issue] {
        var issues: [Issue] = []
        let m = setup.partToWork(partMin: lo, partMax: hi)
        let (rlo, rhi) = setup.rotatedPartBounds(min: lo, max: hi)
        let shift = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let plo = rlo + shift, phi = rhi + shift
        let box = setup.stockBox(stock)
        let names = ["X (vertical)", "Y (left–right)"]
        for axis in 0..<2 {
            let slackLow = plo[axis] - box.min[axis], slackHigh = box.max[axis] - phi[axis]
            let slack = min(slackLow, slackHigh)
            if slack < -1e-6 {
                issues.append(Issue(.error, "The part sticks out of the stock in \(names[axis]) by \(Length.mm(-slack)) mm. Use bigger stock, turn the part, or move it."))
            } else if slack < 3 {
                issues.append(Issue(.warning, "Only \(Length.mm(slack)) mm of stock around the part in \(names[axis]). Profiling around it needs room for the tool."))
            }
        }
        let depth = phi.z - plo.z + setup.topAllowance
        let thickness = box.max.z - box.min.z
        if depth > thickness + 1e-6 {
            issues.append(Issue(.error, "The part (\(Length.mm(phi.z - plo.z)) mm deep plus \(Length.mm(setup.topAllowance)) mm to face) is thicker than the stock (\(Length.mm(thickness)) mm)."))
        } else if thickness - depth < 2 {
            issues.append(Issue(.info, "The part goes almost all the way through the stock. It will need tabs or a second setup to finish the back."))
        }
        // Reach: the tool has to cover the stock face in X and Y.
        let size = setup.stockSize(stock)
        if size.x > machine.travel.x {
            issues.append(Issue(.error, "The stock is \(Length.mm(size.x)) mm tall in X; the CR-1 only travels \(Length.mm(machine.travel.x)) mm vertically."))
        }
        if size.y > machine.travel.y {
            issues.append(Issue(.error, "The stock is \(Length.mm(size.y)) mm wide in Y; the CR-1 travels \(Length.mm(machine.travel.y)) mm."))
        }
        if phi.z - plo.z > 25 {
            issues.append(Issue(.info, "The part is \(Length.mm(phi.z - plo.z)) mm deep along the spindle. Deep walls need long tools; the planner will check reach per tool."))
        }
        return issues
    }
}
