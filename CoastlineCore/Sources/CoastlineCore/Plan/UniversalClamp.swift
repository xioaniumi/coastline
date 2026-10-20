import Foundation
import simd

/// The CR-1 universal clamp kit, measured from a hand-modelled Rhino file
/// (`CR-1 Clamp Kit - Accessories.3dm` → `resources/fixtures/cr1_clamp_kit.npz`, see
/// `engine/coastline_engine/fixture_kit.py`).
///
/// One clamp is a C-shaped aluminium body on an insulator sheet, bolted into **both** T-slots
/// (an M4x20 into the front slot, an M4x90 through the spine into the rear one). The stock sits
/// on the lower jaw (or on the U spacer / 1" cube for thin stock), against the spine, and a soft
/// jaw hanging from two M4x35 screws in the top arm presses it down: clamping force in machine X.
/// The throat opens toward the spindle; parallels behind the stock push its face out past the jaws.
///
/// Kit-local frame: x toward the spindle, y across (machine −Y), z up from the bed top.
public enum UniversalClamp {
    /// Top of the lower jaw: where the stock (or a spacer) rests.
    public static let jawTopZ = 18.45
    /// Underside of the top arm, the soft jaw's thickness, and how low the M4x35 screws can push
    /// it (its underside ranges 42.07…59.04 mm above the bed).
    public static let armUnderZ = 65.44
    public static let softJawThickness = 6.40
    public static let jawLowestZ = 42.07
    public static var jawHighestZ: Double { armUnderZ - softJawThickness }
    /// The front face (arm and lower jaw) and the spine face at the back of the throat.
    public static let frontX = 19.05
    public static let throatBackX = -8.26
    /// The bolts' x: over the front and rear T-slots, 40 mm apart.
    public static let frontSlotX = 13.62
    public static let rearSlotX = -26.38
    public static let width = 19.05
    /// Spacer heights: the U block and the 1" cube.
    public static let spacerU = 24.20
    public static let spacerCube = 25.40

    /// The M4x35 screws' tips as modelled, and how far they travel: down 14.6 mm (until the
    /// heads meet the arm), up to flush with the arm's underside.
    public static let screwTipZ = 61.82
    public static let screwDrop = 14.6

    /// Height range of whatever presses on the stock's top edge: the soft jaw's underside, or
    /// (without the soft jaw) the two screw tips.
    public static func pressRange(softJaw: Bool) -> ClosedRange<Double> {
        softJaw ? jawLowestZ ... jawHighestZ : (screwTipZ - screwDrop) ... armUnderZ
    }

    /// Stock height (machine X) the clamp holds on its lower jaw…
    public static func onJaw(softJaw: Bool) -> ClosedRange<Double> {
        let p = pressRange(softJaw: softJaw)
        return (p.lowerBound - jawTopZ) ... (p.upperBound - jawTopZ)
    }
    /// … and on the U spacer.
    public static func onSpacer(softJaw: Bool) -> ClosedRange<Double> { 0 ... (pressRange(softJaw: softJaw).upperBound - jawTopZ - spacerU) }
    public static var onJaw: ClosedRange<Double> { onJaw(softJaw: true) }
    public static var onSpacer: ClosedRange<Double> { onSpacer(softJaw: true) }

    /// Half the width of a universal clamp's jaw (19.05 mm), along Y.
    public static let clampHalfWidth = 9.525

    /// Stock up to this wide (Y) goes into one clamp: a 19 mm jaw in the middle holds it, with
    /// at most ~20 mm hanging out on each side, and the second clamp would only crowd the cut.
    public static let singleClampMaxWidth = 60.0
    /// One clamp with stock wider than this: the ends hang out far enough to ring.
    public static let singleClampWarnWidth = 80.0
    /// Two clamps need this much stock: each jaw 12 mm in from an end, side by side.
    public static var twoClampMinWidth: Double { 2 * (12 + clampHalfWidth) + 1 }

    /// How many clamps Coastline suggests for stock this wide (Y), and why.
    public static func suggestedCount(stockWidth w: Double) -> (count: Int, why: String) {
        w <= singleClampMaxWidth
            ? (1, "\(Length.mm(w)) mm wide stock sits in one clamp: its jaw holds the middle, and nothing crowds the cut at the ends.")
            : (2, "\(Length.mm(w)) mm wide stock gets a clamp near each end, so it can't rock about a single jaw.")
    }

    /// Why running without the soft jaw is a compromise.
    public static let noSoftJawDisclaimer = "Without the soft jaw the two screw tips press straight on the stock: two small contact points instead of a jaw, so less clamping force and grip against rocking, and they dent the top edge (put a thin aluminium or brass strip under them). Take lighter cuts and check the stock hasn't moved after roughing."
    public static var throatDepth: Double { frontX - throatBackX }

    /// One line for the UI.
    public static var capacity: String { capacity(softJaw: true) }
    public static func capacity(softJaw: Bool) -> String {
        let j = onJaw(softJaw: softJaw), sp = onSpacer(softJaw: softJaw)
        return "Holds stock \(Length.mm(j.lowerBound))–\(Length.mm(j.upperBound)) mm tall on the jaw, or up to \(Length.mm(sp.upperBound)) mm on the U spacer\(softJaw ? "" : " (without the soft jaw)"). Any length; at least ~3 mm deep in the \(Length.mm(throatDepth)) mm throat."
    }

    /// Where stock of a given height sits.
    public struct Seat: Sendable, Equatable {
        public enum Kind: String, Sendable { case jaw, spacer, parallel, tooTall }
        public var kind: Kind
        /// Height of the stock's underside above the bed.
        public var z: Double
        /// A parallel under the stock (kind == .parallel), mm.
        public var parallel: Double = 0

        public var description: String {
            switch kind {
            case .jaw: "on the lower jaw"
            case .spacer: "on the U spacer"
            case .parallel: "on a \(Length.mm(parallel)) mm parallel on the lower jaw"
            case .tooTall: "too tall for the clamp"
            }
        }
    }

    public static func seat(stockHeight h: Double, softJaw: Bool = true) -> Seat {
        let onJaw = onJaw(softJaw: softJaw), onSpacer = onSpacer(softJaw: softJaw)
        if h > onJaw.upperBound + 1e-9 { return Seat(kind: .tooTall, z: jawTopZ) }
        if h >= onJaw.lowerBound { return Seat(kind: .jaw, z: jawTopZ) }
        if h <= onSpacer.upperBound { return Seat(kind: .spacer, z: jawTopZ + spacerU) }
        // Between the spacer's range and the jaw's: lift it into the jaw's range.
        let t = (onJaw.lowerBound - h + 1).rounded(.up)
        return Seat(kind: .parallel, z: jawTopZ + t, parallel: t)
    }

    public struct Placement: Sendable {
        /// Kit-local → model transforms: one per clamp, and the U spacers under thin stock.
        public var clamps: [simd_double4x4]
        public var spacers: [simd_double4x4]
        /// The stock face toward the spindle (model Z) and the stock's underside (model X).
        public var stockFaceZ: Double
        public var stockBottomX: Double
        public var seat: Seat
        /// Parallels needed behind the stock to push its face out, mm (0 = none).
        public var parallels: Double
        public var issues: [Issue]
    }

    /// Clamps across both T-slots and the stock in their throats, its face `protrusion` mm proud
    /// of the jaws so the tool and collet nut stay clear of them.
    /// - Parameters:
    ///   - stock: stock size along work X (vertical), Y, Z (toward the spindle).
    ///   - tableTopX: the table's top face (model X).
    ///   - frontSlotZ: model Z of the front T-slot (toward the spindle).
    ///   - centreY: model Y of the stock's centre.
    public static func place(stock: SIMD3<Double>, tableTopX: Double, frontSlotZ: Double, centreY: Double,
                             protrusion: Double, softJaw: Bool = true, shifts: [Double] = [], count: Int? = nil) -> Placement {
        var issues: [Issue] = []
        let onJaw = onJaw(softJaw: softJaw), onSpacer = onSpacer(softJaw: softJaw)
        // Narrow stock: one clamp in the middle; wider: one near each end (`suggestedCount`,
        // which `count` overrides). The clamps grip the stock's top edge, so they never sit in
        // front of the face being cut. Each can be slid along the T-slots (`shifts`).
        var n = count ?? suggestedCount(stockWidth: stock.y).count
        if n >= 2, stock.y < twoClampMinWidth {
            n = 1
            if count != nil {
                issues.append(Issue(.info, "Two clamps don't fit side by side on \(Length.mm(stock.y)) mm wide stock (\(Length.mm(twoClampMinWidth)) mm at least): it goes into one."))
            }
        }
        if n == 1, stock.y > singleClampWarnWidth {
            issues.append(Issue(.warning, "One clamp holds \(Length.mm(stock.y)) mm wide stock by its middle \(Length.mm(2 * clampHalfWidth)) mm only: the ends can ring and spring away from the tool. Use two clamps, or take lighter cuts near the ends."))
        }
        var ys: [Double] = n == 1 ? [centreY] : [centreY - stock.y / 2 + 12, centreY + stock.y / 2 - 12]
        for k in ys.indices where k < shifts.count { ys[k] += shifts[k] }
        for (k, y) in ys.enumerated() {
            let inside = stock.y / 2 - abs(y - centreY) + clampHalfWidth  // how much of the jaw is under the stock
            if inside < 2 * clampHalfWidth - 0.5 {
                issues.append(Issue(inside < clampHalfWidth ? .error : .warning,
                                    "Universal clamp \(k + 1) \(inside <= 0 ? "misses the stock" : "only grips \(Length.mm(max(inside, 0))) of its \(Length.mm(2 * clampHalfWidth)) mm jaw"): slide it back under the stock."))
            }
        }
        let dz = frontSlotZ - frontSlotX
        func transform(_ y: Double) -> simd_double4x4 {
            // Local x → model Z, local z → model X, local y → model −Y: a proper rotation.
            simd_double4x4(columns: (SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(tableTopX, y, dz, 1)))
        }
        let clamps = ys.map(transform)
        let seat = seat(stockHeight: stock.x, softJaw: softJaw)
        if !softJaw {
            issues.append(Issue(.info, noSoftJawDisclaimer))
        }
        let p = max(min(protrusion, stock.z - 1), 0.5)
        let behind = stock.z - p
        switch seat.kind {
        case .tooTall:
            issues.append(Issue(.error, "The stock is \(Length.mm(stock.x)) mm tall (X); the clamp kit holds at most \(Length.mm(onJaw.upperBound)) mm\(softJaw ? " (\(Length.mm(UniversalClamp.onJaw(softJaw: false).upperBound)) mm without the soft jaws)" : ""). Turn the stock, use smaller stock, or square and mill it down first on the side clamps."))
        case .parallel:
            issues.append(Issue(.warning, "\(Length.mm(stock.x)) mm stock is too short for the jaw (\(Length.mm(onJaw.lowerBound)) mm minimum) and too tall for the U spacer (\(Length.mm(onSpacer.upperBound)) mm): put a \(Length.mm(seat.parallel)) mm parallel under it."))
        case .spacer, .jaw: break
        }
        if behind < 3 {
            issues.append(Issue(.warning, "Only \(Length.mm(max(behind, 0))) mm of the stock is inside the clamp. Thin stock grips better in soft jaws or a printed nest."))
        }
        if p < protrusion - 1e-9 {
            issues.append(Issue(.info, "The stock is thin, so its face only sticks out \(Length.mm(p)) mm past the jaws. Keep the cut away from its top and bottom edges."))
        }
        return Placement(clamps: clamps, spacers: seat.kind == .spacer ? clamps : [],
                         stockFaceZ: dz + frontX + p, stockBottomX: tableTopX + seat.z, seat: seat,
                         parallels: max(throatDepth - behind, 0), issues: issues)
    }
}

/// The flat squaring setup (FlatPrep): the bar on a riser plate, one acetal stop bolted into
/// both T-slots at each end, and two 3" screw C-clamps holding it down to the table plate.
public enum SideClamps {
    /// Kit-local (same convention as UniversalClamp): the brick's half-width across, and its
    /// spindle-side face.
    public static let brickInnerY = 9.52
    public static let brickFrontLocal = 24.75

    /// The table on the CR-1 model, with the stop's face from where it bolts in.
    public static func table(topX: Double, frontSlotZ: Double) -> FlatPrep.Table {
        FlatPrep.Table(topX: topX, stopNorthZ: frontSlotZ - UniversalClamp.frontSlotX + brickFrontLocal)
    }

    public struct Placement: Sendable {
        /// The squaring stop (kit-local → model).
        public var brick: simd_double4x4
        /// Where the C-clamp screws press the bar's top (model coordinates).
        public var clampPoints: [SIMD3<Double>]
        public var riserMin: SIMD3<Double>
        public var riserMax: SIMD3<Double>
        public var stockFaceZ: Double
        public var stockBottomX: Double
        public var issues: [Issue]
        /// A parallel across the bar (model box); unused since the clamps angle instead.
        public var bridge: (min: SIMD3<Double>, max: SIMD3<Double>)?
        /// Each C-clamp's turn about its screw (radians, + swings the frame toward +Y): angled
        /// 45° when the bar reaches past the bed's back edge, so the frame clears the bar's side.
        public var clampAngles: [Double] = []
    }

    /// One prep stage on the table: the bar flat on the riser, its left side (end facing) or
    /// left end (edge) against the stop, its face `protrusion` past the stop toward the spindle.
    /// The riser stops just short of the stop's face; the C-clamp screws press behind everything
    /// the tool reaches and within the clamp's throat.
    public static func place(stage: FlatPrep.Stage, table: FlatPrep.Table, frontSlotZ: Double, centreY: Double) -> Placement {
        let s = stage.stock
        let dz = frontSlotZ - UniversalClamp.frontSlotX
        let face = table.stopNorthZ + stage.protrusion
        let back = face - s.z
        let bottom = table.topX + FlatPrep.riserHeight
        let brickY = centreY - s.y / 2 - brickInnerY
        let brick = simd_double4x4(columns: (SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(table.topX, brickY, dz, 1)))
        var issues: [Issue] = []
        let riserNorth = table.stopNorthZ - 0.5
        let riserSouth = max(back + 1, table.backZ + 0.5, riserNorth - 70)
        // The tool never comes behind this (stop clearance behind the deepest level).
        let cutBack = face - stage.cut - FlatPrep.stopClearance
        let farthest = min(table.clampReachZ, riserNorth - 8, cutBack - 10)
        let nearest = max(back + 8, table.clampSpineZ + 10)
        if farthest < nearest {
            issues.append(Issue(.warning, "The C-clamps can't reach far enough onto the bar for \(stage.title.lowercased()): put a parallel behind it and clamp across both."))
        }
        // A bar reaching past the bed's back edge is where the C-clamp frames would go: bridge it.
        let overhangs = back < table.clampSpineZ + 0.5
        var padZ = max(farthest, nearest)
        var ys: [Double]
        var topX = bottom + s.x
        var bridge: (min: SIMD3<Double>, max: SIMD3<Double>)?
        var angles: [Double] = [0, 0]
        if overhangs {
            // Each C-clamp turned 45° about its screw, symmetrically: the pad on the bar near its
            // side, the frame swinging out beside the bar to the bed's back edge.
            let a = FlatPrep.angledClamp
            padZ = min(table.padLimit(angle: a), riserNorth - 8, cutBack - 10)
            let inset = min(8.0, s.y / 4)
            ys = [centreY - s.y / 2 + inset, centreY + s.y / 2 - inset]
            angles = [-a, a]
            issues.removeAll { $0.message.contains("C-clamps can't reach") }
            if padZ < back + 6 {
                issues.append(Issue(.warning, "Even angled, the C-clamps can't reach far enough onto the bar: support it under its overhang."))
            }
            issues.append(Issue(.info, "The bar reaches past the bed's back edge, so the C-clamps are turned 45° each way: their frames pass beside the bar."))
        } else {
            let spread = max(s.y / 4, 10)
            ys = [centreY - spread, centreY + spread].map { max($0, centreY - s.y / 2 + 12) }
        }
        if topX - (table.topX - FlatPrep.tableThickness) > FlatPrep.clampOpening {
            issues.append(Issue(.warning, "The riser, bar and table are more than a 3\" C-clamp opens (\(Length.mm(FlatPrep.clampOpening)) mm)."))
        }
        return Placement(brick: brick, clampPoints: ys.map { SIMD3(topX, $0, padZ) },
                         riserMin: SIMD3(table.topX, centreY - s.y / 2 + 3, riserSouth),
                         riserMax: SIMD3(bottom, centreY + s.y / 2 - 3, riserNorth),
                         stockFaceZ: face, stockBottomX: bottom, issues: issues, bridge: bridge, clampAngles: angles)
    }
}

/// The user's adjustments to one prep clamping, on top of Coastline's proposal: where the stop
/// sits along the T-slots (the bar moves with it) and each C-clamp's place on the bar and turn.
public struct PrepOverride: Codable, Equatable, Sendable {
    public var stopShiftY: Double = 0
    public var clamps: [ClampOverride] = []
    public init() {}
    public var isEmpty: Bool { stopShiftY == 0 && clamps.allSatisfy { $0 == ClampOverride() } }
}

public struct ClampOverride: Codable, Equatable, Sendable {
    /// Pad moved along Y / Z on the bar (mm), and the turn about the screw (rad; nil = proposed).
    public var dy = 0.0
    public var dz = 0.0
    public var angle: Double?
    public init(dy: Double = 0, dz: Double = 0, angle: Double? = nil) {
        self.dy = dy
        self.dz = dz
        self.angle = angle
    }
}

extension SideClamps {
    /// The proposal with the user's adjustments, and checks that the clamps still hold the bar:
    /// each pad on the bar, each frame reaching around the bed's back edge.
    public static func place(stage: FlatPrep.Stage, table: FlatPrep.Table, frontSlotZ: Double, centreY: Double,
                             override o: PrepOverride?) -> Placement {
        var p = place(stage: stage, table: table, frontSlotZ: frontSlotZ, centreY: centreY + (o?.stopShiftY ?? 0))
        guard let o else { return p }
        let s = stage.stock
        let cy = centreY + o.stopShiftY
        let back = p.stockFaceZ - s.z
        for k in p.clampPoints.indices where k < o.clamps.count {
            let c = o.clamps[k]
            p.clampPoints[k].y += c.dy
            p.clampPoints[k].z += c.dz
            if let a = c.angle {
                while p.clampAngles.count <= k { p.clampAngles.append(0) }
                p.clampAngles[k] = a
            }
        }
        for (k, c) in p.clampPoints.enumerated() {
            let a = k < p.clampAngles.count ? p.clampAngles[k] : 0
            if abs(c.y - cy) > s.y / 2 - 3 || c.z > p.stockFaceZ - 3 || c.z < back + 3 {
                p.issues.append(Issue(.warning, "C-clamp \(k + 1)'s pad is off the bar: move it back onto it."))
            }
            if c.z > table.padLimit(angle: a) + 0.5 {
                p.issues.append(Issue(.warning, "C-clamp \(k + 1) doesn't reach around the bed's back edge: move its pad back, or turn it less."))
            }
            if c.z > p.stockFaceZ - stage.cut - FlatPrep.stopClearance - 4 {
                p.issues.append(Issue(.warning, "C-clamp \(k + 1)'s pad is where the cutter goes: move it back, away from the spindle."))
            }
            if c.z < p.riserMin.z + 2 {
                p.issues.append(Issue(.warning, "C-clamp \(k + 1)'s pad isn't over the riser: the bar would bend under it."))
            }
        }
        if p.clampPoints.count == 2, abs(p.clampPoints[0].y - p.clampPoints[1].y) < 22, abs(p.clampPoints[0].z - p.clampPoints[1].z) < 22 {
            p.issues.append(Issue(.warning, "The C-clamps are on top of each other: spread them along the bar."))
        }
        return p
    }

    /// A solid box of a fixture, model coordinates.
    public struct Solid: Sendable {
        public var name: String
        public var min: SIMD3<Double>
        public var max: SIMD3<Double>
    }

    /// The prep setup's fixtures as boxes (stop, riser, the C-clamps' pads, screws and frames, the
    /// table plate): what the tool must keep clear of. The C-clamp proportions match CClampMesh.
    public static func solids(_ p: Placement, table: FlatPrep.Table, centreY: Double) -> [Solid] {
        let b = p.brick
        func local(_ v: SIMD3<Double>) -> SIMD3<Double> {
            let w = b * SIMD4(v, 1)
            return SIMD3(w.x, w.y, w.z)
        }
        let s0 = local(SIMD3(-29.45, -brickInnerY, -1.7)), s1 = local(SIMD3(brickFrontLocal, brickInnerY, 25.4))
        var out = [Solid(name: "stop", min: simd_min(s0, s1), max: simd_max(s0, s1))]
        if let b = p.bridge { out.append(Solid(name: "bridge parallel", min: b.min, max: b.max)) }
        out += [
                   Solid(name: "riser", min: p.riserMin, max: p.riserMax),
                   Solid(name: "table", min: SIMD3(table.topX - FlatPrep.tableThickness, centreY - 180, table.backZ),
                         max: SIMD3(table.topX, centreY + 180, table.northZ))]
        let under = table.topX - FlatPrep.tableThickness
        // The 3" C-clamp (the C-clamp model, scaled; fixture_kit.c_clamp_parts): x from the fixed
        // jaw's face under the table, the screw boss 85–108 mm up, the spine 50–57 mm behind the
        // screw, 16 mm across.
        for (k, c) in p.clampPoints.enumerated() {
            let a = k < p.clampAngles.count ? p.clampAngles[k] : 0
            // The frame runs from the screw toward its spine: straight back, or turned by `a`.
            let dir = SIMD2(sin(a), -cos(a))  // (Y, Z)
            let spine = SIMD2(c.y, c.z) + dir * (FlatPrep.clampThroat + 3.4)
            let lo = simd_min(SIMD2(c.y, c.z), spine) - 8.5, hi = simd_max(SIMD2(c.y, c.z), spine) + 8.5
            out.append(Solid(name: "C-clamp pad", min: SIMD3(c.x, c.y - 7.4, c.z - 7.4), max: SIMD3(c.x + 12.8, c.y + 7.4, c.z + 7.4)))
            out.append(Solid(name: "C-clamp screw", min: SIMD3(c.x + 12.8, c.y - 4.3, c.z - 4.3), max: SIMD3(under + 193, c.y + 4.3, c.z + 4.3)))
            out.append(Solid(name: "C-clamp frame", min: SIMD3(under + 85, lo.x, lo.y), max: SIMD3(under + 108, hi.x, hi.y)))   // top arm
            out.append(Solid(name: "C-clamp frame", min: SIMD3(under - 27, spine.x - 8.5, spine.y - 8.5),
                             max: SIMD3(under + 108, spine.x + 8.5, spine.y + 8.5)))                                         // spine
            out.append(Solid(name: "C-clamp frame", min: SIMD3(under - 27, lo.x, lo.y), max: SIMD3(under, hi.x, hi.y)))     // lower arm
        }
        return out
    }
}

extension FixtureField {
    /// The 12 triangles of a box.
    public static func boxTriangles(min a: SIMD3<Double>, max b: SIMD3<Double>) -> [SIMD3<Double>] {
        let c = (0..<8).map { i in SIMD3(i & 1 == 0 ? a.x : b.x, i & 2 == 0 ? a.y : b.y, i & 4 == 0 ? a.z : b.z) }
        let faces = [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]
        return faces.flatMap { f in [c[f[0]], c[f[1]], c[f[2]], c[f[0]], c[f[2]], c[f[3]]] }
    }
}

/// Stock sizing advice for the clamp kit.
public enum StockAdvice {
    /// Stock that fits both the part and the clamp kit: room to profile around the part
    /// (one tool diameter + 3 mm a side), face-off allowances front and back, and a height the
    /// clamp holds. Whole millimetres, rounded up.
    public static func idealSize(part: SIMD3<Double>, twoSided: Bool, topAllowance: Double, toolDiameter: Double) -> SIMD3<Double> {
        let margin = toolDiameter + 3
        var x = part.x + 2 * margin
        if x > UniversalClamp.onSpacer.upperBound && x < UniversalClamp.onJaw.lowerBound { x = UniversalClamp.onJaw.lowerBound }
        let y = max(part.y + 2 * margin, 30)
        let z = part.z + 2 * topAllowance + (twoSided ? 1 : 3)
        return SIMD3(x.rounded(.up), y.rounded(.up), z.rounded(.up))
    }

    /// Whether stock of this size (work X, Y, Z) holds in the clamp kit and still contains the
    /// part (work-frame size) with `margin` around it and `depth` along the tool axis.
    public static func fits(stock s: SIMD3<Double>, part: SIMD3<Double>, margin: Double, depth: Double, softJaw: Bool = true) -> Bool {
        UniversalClamp.seat(stockHeight: s.x, softJaw: softJaw).kind != .tooTall
            && s.x >= part.x + 2 && s.y >= part.y + 2 * margin && s.z >= depth
    }

    /// An arrangement of the stock (Setup.stockAxes) that fits the clamp kit and the part, if
    /// the current one doesn't. Prefers the jaw over spacers and the longest side along Y.
    public static func turnToFit(stock: StockItem, part: SIMD3<Double>, margin: Double, depth: Double, softJaw: Bool = true) -> [Int]? {
        let e = [stock.envelope.x, stock.envelope.y, stock.envelope.z]
        let perms: [[Int]] = [[1, 0, 2], [0, 1, 2], [2, 0, 1], [0, 2, 1], [2, 1, 0], [1, 2, 0]]
        return perms.filter { p in fits(stock: SIMD3(e[p[0]], e[p[1]], e[p[2]]), part: part, margin: margin, depth: depth, softJaw: softJaw) }
            .min { a, b in
                let ka = UniversalClamp.seat(stockHeight: e[a[0]]).kind == .jaw ? 0 : 1
                let kb = UniversalClamp.seat(stockHeight: e[b[0]]).kind == .jaw ? 0 : 1
                return ka != kb ? ka < kb : e[a[1]] > e[b[1]]
            }
    }

    /// Milling the top edge of oversized stock down to `target` height on the side clamps: the
    /// volume removed and roughly how long it takes with adaptive-style side milling.
    public static func downsize(stock: SIMD3<Double>, target: Double, tool: Tool?, material: Material?) -> (volume: Double, minutes: Double?) {
        let volume = max(stock.x - target, 0) * stock.y * stock.z
        guard let tool, let material else { return (volume, nil) }
        let d = FeedsEngine.compute(tool: tool, material: material, kind: .adaptive)
        let ap = min(2 * tool.diameter, max(tool.fluteLength - 1, 1), stock.z)
        let mrr = d.feed * min(d.stepover, tool.diameter * 0.3) * ap  // mm³/min
        return (volume, mrr > 0 ? volume / mrr * 1.25 : nil)  // + 25 % for links and lifts
    }
}

/// The ways a bar can sit for a part: which of its sizes stands up in the clamp (work X), runs
/// along the table (Y) and points at the spindle (Z). Only ways the part fits are workable; each
/// says what has to come off first to fit the clamp kit, and the one removing the least is best.
public enum StockOrientation {
    public struct Option: Sendable, Identifiable {
        public var id: [Int] { axes }
        /// Setup.stockAxes: envelope index for work X, Y, Z.
        public var axes: [Int]
        /// The stock as bought in this orientation (work X, Y, Z).
        public var raw: SIMD3<Double>
        public var workable: Bool
        /// Why not, when it isn't.
        public var reason: String?
        /// Milled down to this height first (too tall for the kit as it is).
        public var prepHeight: Double?
        /// Clamped without the soft jaws (the only way a proper frame fits the kit).
        public var softJawOff = false
        /// The extrusion runs left–right (work Y): the jaws grip and the face shows the bar's
        /// straight extruded sides; only its sawn ends are across.
        public var alongExtrusion = true
        /// Material removed to fit the kit and reach the part's depth, mm³ (smaller is better).
        public var removal: Double
        /// Workable only held by shoulders at the ends (holding path D): the kit grips the ends,
        /// so the part may come right to the bar's top and bottom edges.
        public var viaShoulders = false
        public var summary: String
    }

    /// - Parameters: part: the part's size in the work frame; twoSided: machined from both sides.
    public static func options(stock: StockItem, part: SIMD3<Double>, twoSided: Bool, topAllowance: Double,
                               softJaw: Bool, toolDiameter: Double) -> [Option] {
        let e = [stock.envelope.x, stock.envelope.y, stock.envelope.z]
        let perms: [[Int]] = [[1, 0, 2], [0, 1, 2], [2, 0, 1], [0, 2, 1], [2, 1, 0], [1, 2, 0]]
        let jaw = UniversalClamp.onJaw(softJaw: softJaw)
        let bare = UniversalClamp.onJaw(softJaw: false)
        // Room the part needs: a frame (the jaws' strips and a channel one cutter wide) up and
        // down, a tool's width plus a little at the ends, and its depth plus the face-offs.
        let needX = GripZones.neededHeight(partX: part.x)
        let needY = part.y + 2 * (toolDiameter + 1)
        // Depth: the part plus the least face-off (0.3 mm a side), not where it sits now: a
        // part almost as thick as the bar still fits (it's moved to fit).
        let needZ = part.z + (twoSided ? 0.6 : 0.3 + 0.5)
        _ = topAllowance
        // The extrusion: given on the stock, else its longest side.
        let ext = stock.extrusionAxis ?? [0, 1, 2].max { e[$0] < e[$1] }!
        var out: [Option] = []
        var seen = Set<[Double]>()
        for p in perms {
            let raw = SIMD3(e[p[0]], e[p[1]], e[p[2]])
            guard seen.insert([raw.x, raw.y, raw.z]).inserted else { continue }
            var reason: String?
            if raw.z < needZ { reason = "only \(Length.mm(raw.z)) mm deep: the part needs \(Length.mm(needZ))" }
            else if raw.y < needY { reason = "only \(Length.mm(raw.y)) mm long: the part needs \(Length.mm(needY))" }
            else if raw.x < needX { reason = "only \(Length.mm(raw.x)) mm tall: the part and the jaws need \(Length.mm(needX))" }
            var prep: Double?
            var softOff = false
            if reason == nil, UniversalClamp.seat(stockHeight: raw.x, softJaw: softJaw).kind == .tooTall {
                let target = (jaw.upperBound - 0.5).rounded(.down)
                if target >= needX { prep = min(target, raw.x) }
                else if softJaw, raw.x >= needX, (bare.upperBound - 0.5).rounded(.down) >= needX {
                    // A proper frame only fits the kit without the soft jaws.
                    softOff = true
                    // As it is when the screws alone hold it, else down to the tallest they hold.
                    prep = raw.x <= bare.upperBound ? nil : (bare.upperBound - 0.5).rounded(.down)
                } else {
                    reason = "the clamp kit holds \(Length.mm(bare.upperBound)) mm; the part and its frame need \(Length.mm(needX))"
                }
            }
            // Held by shoulders instead: the jaws grip only the two ends, so the part needs just
            // its own height, and its length between the clamps' jaws.
            var viaShoulders = false
            if reason != nil, raw.z >= needZ, let sh = Shoulders.fit(raw: raw, part: part) {
                viaShoulders = true
                reason = nil
                prep = nil
                softOff = true
                _ = sh
            }
            let height = prep ?? raw.x
            let length = min(raw.y, max(needY, 0))
            var removal = (raw.x - height) * length * raw.z + max(raw.z - needZ, 0) * height * length
            if viaShoulders, let sh = Shoulders.fit(raw: raw, part: part) { removal = 2 * sh.length * (raw.x - sh.height) * raw.z }
            let dims = "\(Length.mm(raw.x)) up · \(Length.mm(raw.y)) along · \(Length.mm(raw.z)) deep"
            let summary: String
            let jaws = (softOff ? ", soft jaws off" : "") + (p[1] == ext ? "" : " (extrusion across: sawn faces in the jaws)")
            if let r = reason { summary = "\(dims): no, \(r)" }
            else if viaShoulders, let sh = Shoulders.fit(raw: raw, part: part) {
                summary = sh.height < raw.x - 0.01 ? "\(dims): shoulders at both ends (\(Length.mm(sh.height)) mm), the kit grips those"
                    : "\(dims): the kit grips the two ends only"
            }
            else if let h = prep { summary = "\(dims): mill to \(Length.mm(h)) mm tall first\(jaws)" }
            else { summary = "\(dims): fits the clamp kit as it is\(jaws)" }
            var o = Option(axes: p, raw: raw, workable: reason == nil, reason: reason, prepHeight: prep, softJawOff: softOff,
                           alongExtrusion: p[1] == ext, removal: removal, summary: summary)
            o.viaShoulders = viaShoulders
            out.append(o)
        }
        // Workable first; then the extrusion along Y (true faces in the jaws and toward the
        // spindle); then the least material removed.
        return out.sorted { a, b in
            if a.workable != b.workable { return a.workable }
            if a.viaShoulders != b.viaShoulders { return !a.viaShoulders }
            if a.alongExtrusion != b.alongExtrusion { return a.alongExtrusion }
            return a.removal < b.removal
        }
    }
}


/// Holding path D's geometry: where the universal clamps grip the bar's ends.
public enum Shoulders {
    /// A clamp sits 12 mm in from the end, its jaw 19.05 mm wide: the part keeps out of this
    /// much at each end (below the shoulder's top).
    public static let gripZone = 12 + UniversalClamp.clampHalfWidth
    /// Shoulder length: the grip zone and 1.5 mm to spare.
    public static let length = (gripZone + 1.5).rounded(.up)

    /// Shoulders that hold this part in this bar (work X up, Y along), or nil: as tall as the
    /// kit grips without its soft jaws (or the bar's own height when that fits: then the ends
    /// are simply gripped, nothing is milled), the part between the jaws with 1 mm each side.
    public static func fit(raw: SIMD3<Double>, part: SIMD3<Double>) -> Setup.Shoulders? {
        let grip = UniversalClamp.onJaw(softJaw: false)
        let h = min((grip.upperBound - 0.5).rounded(.down), raw.x)
        guard h >= grip.lowerBound, raw.x >= part.x + 1, raw.y - 2 * gripZone - 2 >= part.y else { return nil }
        return Setup.Shoulders(height: h, length: length)
    }
}
