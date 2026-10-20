import Foundation

/// Two-sided registration from machined reference features, the way production shops pick up
/// a second op: side A bores two holes in the frame (from the same zero as the part, so they
/// sit exactly where side A's geometry is); after the flip, side B opens them from the back
/// ("windows"), probes each bore's centre (four touches: X±, then Y± from the X centre — a
/// chord's midpoint is the centre whatever the offset across it) and sets X0 Y0 from the two
/// centres. Then it checks what it found:
/// - each bore measures its diameter (wrong spot, a chip or a wrong flip: stop),
/// - the centres are the right distance apart,
/// - the line between them isn't turned (the stock seated crooked: stop).
/// The pair sits off the stock's centre line, so a stock turned the wrong way round (upside
/// down instead of front-to-back) mirrors it away: the bores aren't found and the job stops.
///
/// Side B's zero then follows side A's features to a few hundredths, whatever the sawn edges
/// are like, and an edge the CR-1 can't reach doesn't matter any more.
public enum ReferenceBores {
    /// Bore diameter: fits a 1/4" tool with 1.8 mm to spare each side (electrical probing), or
    /// the Fisher edge finder's 0.2" tip with 2.5 mm (manual pickup).
    public static let diameter = 10.0
    /// The window opened from side B: wider, so the bore below keeps its own walls.
    public static let windowDiameter = 13.0
    /// How much material side A leaves under each bore (it never cuts through into the clamp
    /// or the parallels behind), mm.
    public static let skin = 1.0
    /// The window reaches this far into the bore, mm.
    public static let overlap = 1.0
    /// Probing happens this far below the window's floor (inside side A's bore walls), mm.
    public static let probeBelowWindow = 1.5
    /// The pair's offset from the stock's centre line (the axis a wrong flip mirrors about), mm:
    /// more than a bore's width, so a mirrored bore lands nowhere near the window.
    public static let offCentre = 7.0
    /// Wall left between a bore and anything else (the part's clearing band, the stock edge).
    public static let wall = 2.5

    public struct Plan: Sendable, Equatable, Codable {
        /// Bore centres in side A's work frame (X up, Y along the stock), mm.
        public var centresA: [SIMD2<Double>]
        /// How deep side A bores (from its face), mm.
        public var depthA: Double
        /// Stock thickness, mm.
        public var thickness: Double
        public init(centresA: [SIMD2<Double>], depthA: Double, thickness: Double) {
            self.centresA = centresA
            self.depthA = depthA
            self.thickness = thickness
        }

        /// The same centres in side B's work frame: turned front-to-back about X, Y mirrors.
        public var centresB: [SIMD2<Double>] { centresA.map { SIMD2($0.x, -$0.y) } }
        /// How deep side B's windows go (from its face): through the skin and `overlap` into
        /// the bore.
        public var windowDepth: Double { thickness - depthA + ReferenceBores.overlap }
        /// Where the probe touches the bore walls (side B work Z).
        public var probeZ: Double { -(windowDepth + ReferenceBores.probeBelowWindow) }
    }

    /// Where the bores go: in the frame, past `clear` (mm) from the part's outline box on every
    /// side (the clearing band, the tabs), `wall` from the stock's edges, out of the clamped
    /// strips and (along X) within reach. Along the stock's length first (the widest spacing,
    /// so the best angle), else across it. nil: no frame wide enough.
    public static func place(stock: SIMD3<Double>, partMin: SIMD2<Double>, partMax: SIMD2<Double>, clear: Double,
                             keepOut: [(min: SIMD2<Double>, max: SIMD2<Double>)] = [], xReach: ClosedRange<Double>? = nil,
                             toolDiameter: Double, maxDepth: Double) -> Plan? {
        let r = diameter / 2
        let c = (partMin + partMax) / 2
        // The tool centre must reach the bore's whole circle.
        let reach = xReach.map { ($0.lowerBound + r + 0.5)...($0.upperBound - r - 0.5) }
        func fits(_ p: SIMD2<Double>) -> Bool {
            guard abs(p.x) <= stock.x / 2 - r - wall, abs(p.y) <= stock.y / 2 - r - wall else { return false }
            if let reach, !reach.contains(p.x) { return false }
            // Out of the part's band (box grown by `clear`) with a wall.
            let g = clear + r + wall
            if p.x > partMin.x - g, p.x < partMax.x + g, p.y > partMin.y - g, p.y < partMax.y + g { return false }
            for k in keepOut where p.x > k.min.x - r - wall && p.x < k.max.x + r + wall && p.y > k.min.y - r - wall && p.y < k.max.y + r + wall {
                return false
            }
            return true
        }
        let depth = min(stock.z - skin, maxDepth)
        guard depth > stock.z / 2 + 1 else { return nil }  // side B must be able to reach it
        // Off the stock's centre line across the pair: the right flip (front-to-back) keeps
        // that offset, a wrong one (upside down) mirrors it and the bores aren't found.
        let offsets = [offCentre, -offCentre, 4.5, -4.5, 0]
        // Along Y: the middle of the frame past each end of the band (symmetric about the
        // part, so the pair's midpoint is the part's centre in Y).
        let inner = partMax.y - c.y + clear + r + wall
        let outer = min(stock.y / 2 - c.y, stock.y / 2 + c.y) - r - wall
        if outer >= inner {
            let d = (inner + outer) / 2
            for e in offsets {
                let pair = [SIMD2(e, c.y - d), SIMD2(e, c.y + d)]
                if pair.allSatisfy(fits) { return Plan(centresA: pair, depthA: depth, thickness: stock.z) }
            }
        }
        // Across X (a short bar with room above and below the part).
        let innerX = partMax.x - c.x + clear + r + wall
        let outerX = min(stock.x / 2 - c.x, stock.x / 2 + c.x) - r - wall
        if outerX >= innerX {
            let d = (innerX + outerX) / 2
            for e in offsets {
                let pair = [SIMD2(c.x - d, e), SIMD2(c.x + d, e)]
                if pair.allSatisfy(fits) { return Plan(centresA: pair, depthA: depth, thickness: stock.z) }
            }
        }
        return nil
    }

    // MARK: Probing programs (CRWrite helpers)

    /// G-code numbers without trailing zeros.
    static func n(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    /// Electrical probing: the tool turns slowly backwards (M4 S1500, as Coast Runner's own
    /// probing cutcode), so a touch never cuts, and the clamp kit closes the circuit.
    static let probeOn = ["M4 S1500", "G4 P2"]
    static let probeFeed = 20.0

    /// Finds bore `k`'s centre and stores it as G55 (k = 0) or G56 (k = 1) origin (machine
    /// coordinates of the centre). G57/G58 hold the touches (G59 is CRWrite's carry-over
    /// register: never touched). Side B work coordinates (the rough zero from the edges).
    /// The measured diameter must match: otherwise the step stops with an error.
    public static func boreProgram(_ plan: Plan, bore k: Int, toolDiameter: Double, electrical: Bool) -> String {
        let c = plan.centresB[k]
        let wcs = k == 0 ? "G55" : "G56"
        let gap = (diameter - toolDiameter) / 2
        let reach = gap + 1.5
        var g = ["(Reference bore \(k + 1): find its centre)", "G21 G90", "G53 G0 Z-1", "G54 G0 X\(n(c.x)) Y\(n(c.y))", "G0 Z2"]
        g += probeOn
        // Down into the bore: stops if it touches anything (the rough zero more than ~2 mm out).
        g += ["G38.3 G91 Z-\(n(2 - plan.probeZ)) F60", "G90"]
        for axis in ["X", "Y"] {
            let nominal = axis == "X" ? c.x : c.y
            g += ["G38.2 G91 \(axis)\(n(reach)) F\(n(probeFeed))", "G10 L20 P4 \(axis)0", "G91 G0 \(axis)-0.3",
                  "G90 G54 G0 \(axis)\(n(nominal))",
                  "G38.2 G91 \(axis)-\(n(reach)) F\(n(probeFeed))", "G10 L20 P5 \(axis)0", "G91 G0 \(axis)0.3", "G90",
                  "M102 \(wcs)\(axis) ((G57\(axis) + G58\(axis))/2)",
                  "M102 G58\(axis) (abs(G57\(axis) - G58\(axis)))",
                  "M106 G58\(axis) > \(n(2 * gap - 0.4)) error: bore \(k + 1) too small - not found",
                  "M106 G58\(axis) < \(n(2 * gap + 0.4)) error: bore \(k + 1) too big - not found",
                  "\(wcs) G0 \(axis)0"]
        }
        g += ["G53 G0 Z-1", "M5", "G54"]
        _ = electrical
        return g.joined(separator: "\n") + "\n"
    }

    /// X0 Y0 from the two bore centres (G55, G56) into G54, after checking their spacing and
    /// that the line between them isn't turned.
    public static func zeroProgram(_ plan: Plan) -> String {
        let b = plan.centresB
        let mid = (b[0] + b[1]) / 2
        let dx = b[0].x - b[1].x, dy = abs(b[0].y - b[1].y), dxy = abs(b[0].x - b[1].x)
        var g = ["(X0 Y0 from the reference bores)", "G21 G90"]
        if dy >= dxy {
            // Pair along Y: both at the same X.
            g += ["M102 G57X (abs(G55X - G56X - (\(n(dx)))))",
                  "M106 G57X < 0.1 error: stock turned - reseat it square",
                  "M102 G57Y (abs(abs(G55Y - G56Y) - \(n(dy))))",
                  "M106 G57Y < 0.15 error: bore spacing wrong - check the flip"]
        } else {
            let ddy = b[0].y - b[1].y
            g += ["M102 G57Y (abs(G55Y - G56Y - (\(n(ddy)))))",
                  "M106 G57Y < 0.1 error: stock turned - reseat it square",
                  "M102 G57X (abs(abs(G55X - G56X) - \(n(dxy))))",
                  "M106 G57X < 0.15 error: bore spacing wrong - check the flip"]
        }
        g += ["M102 G54X ((G55X + G56X)/2 - (\(n(mid.x))))",
              "M102 G54Y ((G55Y + G56Y)/2 - (\(n(mid.y))))",
              "G4 P0.5", "G54", "G53 G0 Z-1", "G54 G0 X\(n(b[0].x)) Y\(n(b[0].y))"]
        return g.joined(separator: "\n") + "\n"
    }

    /// Manual pickup with the edge finder: store one wall of bore `k` (side "+X", "-X", "+Y",
    /// "-Y") as G57/G58, and the centre from both walls into G55/G56.
    public static func storeWall(axis: String, positive: Bool) -> String {
        "G10 L20 P\(positive ? 4 : 5) \(axis)0\nG4 P0.5\n"
    }

    public static func storeCentre(bore k: Int, axis: String, toolDiameter: Double) -> String {
        let wcs = k == 0 ? "G55" : "G56"
        let gap = (diameter - toolDiameter) / 2
        return """
        M102 \(wcs)\(axis) ((G57\(axis) + G58\(axis))/2)
        M102 G58\(axis) (abs(G57\(axis) - G58\(axis)))
        M106 G58\(axis) > \(n(2 * gap - 0.4)) error: walls too close - find them again
        M106 G58\(axis) < \(n(2 * gap + 0.4)) error: walls too far apart - find them again
        G4 P0.5

        """
    }

    // MARK: Electrical edge and top probing

    /// Probe toward an edge from where the tool was jogged (beside it, below the face), and
    /// store the touch in G55 (`low`) or G56: the midpoint of two touches is the centre, the
    /// tool's radius cancels. `toward`: +1 or −1 along `axis`.
    public static func edgeProgram(axis: String, toward: Double, store p: Int) -> String {
        """
        G21
        \(probeOn.joined(separator: "\n"))
        G38.2 G91 \(axis)\(n(10 * toward)) F\(n(probeFeed))
        G10 L20 P\(p) \(axis)0
        G91 G0 \(axis)\(n(-2 * toward))
        M5
        G90

        """
    }

    /// One edge only (the other is out of the CR-1's reach): X0 from that edge and the stock's
    /// size. The tool touches with its side, so its centre is a radius off the edge.
    public static func singleEdgeProgram(axis: String, toward: Double, edgeAt: Double, radius: Double, electrical: Bool) -> String {
        let at = edgeAt - toward * radius
        if !electrical { return "G10 L20 P1 \(axis)\(n(at))\nG4 P0.5\n" }
        return """
        G21
        \(probeOn.joined(separator: "\n"))
        G38.2 G91 \(axis)\(n(10 * toward)) F\(n(probeFeed))
        G10 L20 P1 \(axis)\(n(at))
        G91 G0 \(axis)\(n(-2 * toward))
        M5
        G90

        """
    }

    /// Touch the tool down on the face (jogged just above a solid spot): that height is `z`
    /// (0 on a fresh face, below it after facing).
    public static func topProgram(z: Double) -> String {
        """
        G21
        \(probeOn.joined(separator: "\n"))
        G38.2 G91 Z-8 F\(n(probeFeed))
        G10 L20 P1 Z\(n(z))
        G91 G0 Z3
        M5
        G90
        G54

        """
    }
}
