import Foundation

/// The kinds of machining operation Coastline generates.
public enum OperationKind: String, CaseIterable, Sendable, Codable {
    case facing, adaptive, contour, floor, drill, bore, chamfer
    // 3D finishing. Raw values are the engine's strategy names.
    case parallel, waterline, steepShallow = "steep_shallow", scallop, spiral, radial, rest
    /// Text engraved along glyph outlines, following the surface.
    case engrave
    /// Internal threads milled with a single-form thread mill: a helix per pitch, from the
    /// bottom up (climb), in holes already made at the tap-drill size.
    case thread

    /// Freeform (3D) finishing: a drop-cutter strategy, usually with a ball end mill.
    public var is3D: Bool { [.parallel, .waterline, .steepShallow, .scallop, .spiral, .radial, .rest].contains(self) }

    public var title: String {
        switch self {
        case .facing: "Facing"
        case .adaptive: "Adaptive roughing"
        case .contour: "Contour finishing"
        case .floor: "Floor finishing"
        case .drill: "Drilling"
        case .bore: "Helical boring"
        case .chamfer: "Chamfer / deburr"
        case .parallel: "Parallel finishing"
        case .waterline: "Waterline finishing"
        case .steepShallow: "Steep & shallow finishing"
        case .scallop: "Scallop finishing"
        case .spiral: "Spiral finishing"
        case .radial: "Radial finishing"
        case .rest: "Rest / pencil finishing"
        case .engrave: "Engraving"
        case .thread: "Thread milling"
        }
    }

    /// What the strategy is for, in one line (tooltips).
    public var explanation: String {
        switch self {
        case .facing: "Flattens the stock face so Z0 is true. Light, fast passes."
        case .adaptive: "Roughing with constant tool engagement: deep cuts, small stepover, even wear, no full-width slotting."
        case .contour: "Finishes walls level by level with arc lead-ins and an optional spring pass."
        case .floor: "Finishes flat floors after roughing."
        case .drill: "Peck-drills holes along the tool axis."
        case .bore: "Helically mills holes that have no matching drill."
        case .chamfer: "Breaks sharp edges."
        case .parallel: "Straight passes over the whole surface at a fixed angle. Best on shallow, gently curved areas; steep walls get wider cusps."
        case .waterline: "Constant-Z contours. Best on steep walls; flat tops get few passes."
        case .steepShallow: "Waterline on steep areas, parallel on shallow ones, with a small overlap: an even finish on mixed shapes like domed pendants."
        case .scallop: "Passes at a constant 3D distance from each other, following the shape: the most even finish on freeform jewellery, at the cost of time."
        case .spiral: "One continuous spiral from the centre out: ideal for domes, cabochons and ring tops, with no direction changes to mark the surface."
        case .radial: "Spokes from the centre: for rosettes and radially symmetric shapes."
        case .rest: "Cleans only where a bigger tool couldn't reach: inside corners, creases and small fillets. Runs after a larger finishing tool."
        case .engrave: "Traces text into the surface at a set depth, following its shape: names, dates, hallmarks."
        case .thread: "Mills internal threads with a single-form thread mill: one helical turn per pitch, climbing from the bottom up, in holes made at the tap-drill size first. No tap to break, any depth the cutter reaches."
        }
    }

    public var symbol: String {
        switch self {
        case .facing: "square.3.layers.3d.top.filled"
        case .adaptive: "scribble.variable"
        case .contour: "circle.dashed"
        case .floor: "square.dashed"
        case .drill: "arrow.down.to.line"
        case .bore: "circle.circle"
        case .chamfer: "triangle"
        case .parallel: "line.3.horizontal"
        case .waterline: "water.waves"
        case .steepShallow: "mountain.2"
        case .scallop: "circle.circle"
        case .spiral: "hurricane"
        case .radial: "asterisk"
        case .rest: "pencil.tip"
        case .engrave: "textformat"
        case .thread: "screwdriver"
        }
    }
}

/// Speeds, feeds and engagement for one tool in one material for one kind of operation.
public struct CuttingData: Equatable, Sendable, Codable {
    public var rpm: Double
    /// Cutting feed, mm/min.
    public var feed: Double
    public var plungeFeed: Double
    public var rampFeed: Double
    /// Feed per tooth actually used, mm.
    public var chipLoad: Double
    /// Axial depth per pass, mm.
    public var stepdown: Double
    /// Radial engagement (stepover), mm.
    public var stepover: Double
    /// Ramp/helix angle for entries, degrees.
    public var rampAngle: Double
    /// Estimated cutting power at full engagement, W.
    public var power: Double
    /// Plain-language reasoning, shown in the operation inspector.
    public var notes: [String]
}

/// Computes cutting data. Anchored on Coast Runner's feeds & speeds master document
/// (aluminium, 3-flute carbide) and scaled by material, tool and operation.
public enum FeedsEngine {
    /// Coast Runner's aluminium chip loads (inches per tooth) by tool diameter (inches). [FS]
    static let anchorDiameters: [Double] = [1.0 / 16, 1.0 / 8, 5.0 / 32, 3.0 / 16, 1.0 / 4]
    static let anchorAdaptive: [Double] = [0.0006, 0.0008, 0.0010, 0.0010, 0.0013]  // also face finish
    static let anchorContour: [Double] = [0.0003, 0.0004, 0.0005, 0.0006, 0.0006]
    static let anchorSlot: [Double] = [0.0002, 0.0003, 0.0004, 0.0004, 0.0004]
    /// Adaptive radial stepover (inches) by diameter: "R" values in the master document. [FS]
    static let anchorAdaptiveStepover: [Double] = [0.012, 0.014, 0.016, 0.018, 0.020]
    /// Contour-finish radial stepover (inches). [FS]
    static let anchorFinishStepover: [Double] = [0.005, 0.006, 0.007, 0.008, 0.010]

    /// Piecewise-linear lookup in the anchor table, in mm. Below the smallest anchor the
    /// value scales with diameter; above the largest it extrapolates gently (cap 1.4×).
    static func lookup(_ table: [Double], diameter d: Double) -> Double {
        let xs = anchorDiameters.map { $0 * 25.4 }
        let ys = table.map { $0 * 25.4 }
        if d <= xs[0] { return ys[0] * d / xs[0] }
        if d >= xs[xs.count - 1] { return ys[ys.count - 1] * min(d / xs[xs.count - 1], 1.4) }
        for i in 0..<(xs.count - 1) where d <= xs[i + 1] {
            let t = (d - xs[i]) / (xs[i + 1] - xs[i])
            return ys[i] + t * (ys[i + 1] - ys[i])
        }
        return ys[ys.count - 1]
    }

    /// Stepover that leaves cusps `cusp` mm high on flat ground: 2·√(2·R·h − h²) for a ball (or
    /// a bull nose's corner radius); flat end mills finish shallow areas at 30 % of the diameter.
    public static func scallopStepover(tool: Tool, cusp h: Double) -> Double {
        let r: Double = switch tool.kind {
        case .ballEndMill: tool.diameter / 2
        case .bullNoseEndMill where tool.cornerRadius > 0.05: tool.cornerRadius
        default: 0
        }
        guard r > 0 else { return 0.3 * tool.diameter }
        return 2 * max(2 * r * h - h * h, 1e-9).squareRoot()
    }

    /// How hard roughing runs. Roughing leaves stock for the finishing passes, so it never
    /// shows on the part: it can run as hard as the tool and the machine take.
    public enum RoughingStyle: String, Codable, Sendable, CaseIterable {
        /// Coast Runner's aluminium table as printed (chip thinning barely used: ×1.15).
        case table
        /// The feed raised so each tooth cuts the table's chip at the light engagement adaptive
        /// uses (radial chip thinning, up to ×1.6): the same load per tooth, less time.
        case thinned
        /// Chip-thinned, and each level one tool diameter deep instead of half (the flutes do
        /// the work, wear spreads along them): tools of 3 mm and up.
        case deep

        public var title: String {
            switch self {
            case .table: "Coast Runner table"
            case .thinned: "Chip-thinned"
            case .deep: "Deep"
            }
        }
        public var explanation: String {
            switch self {
            case .table: "Coast Runner's printed feeds and ½-diameter levels. The gentlest; the slowest roughing."
            case .thinned: "At the light engagement adaptive roughing uses, the chip is thinner than the feed per tooth: the feed rises until each tooth cuts the table's chip again. Same load on the tool, roughly a third less roughing time."
            case .deep: "Chip-thinned, and each level a full tool diameter deep (tools 3 mm and up): about half the levels. Twice the cutting force of the table; listen for chatter on the first cut."
            }
        }
    }

    public static func compute(tool: Tool, material: Material, kind: OperationKind,
                               machine: MachineProfile = .cr1, roughing: RoughingStyle = .table) -> CuttingData {
        let d = max(tool.diameter, 0.1)
        var notes: [String] = []
        let hss = tool.toolMaterial == .hss
        let flutes = Double(max(tool.flutes, 1))

        // Surface speed: middle of the material's range; finishing and slotting run slower
        // (the master document uses 6000 instead of 8000 RPM for those in aluminium).
        var vc = (material.surfaceSpeed.lowerBound + material.surfaceSpeed.upperBound) / 2
        if hss { vc *= 0.4; notes.append("HSS tool: surface speed reduced to 40%.") }
        switch kind {
        case .contour: vc *= 0.75
        case .drill: vc *= 0.75
        case .thread: vc *= 0.6  // the whole profile engages at once
        default: break
        }
        // A ball cuts at a smaller effective diameter near its tip: spin it as fast as allowed.
        if kind.is3D && tool.kind == .ballEndMill { vc *= 1.2 }
        let idealRPM = vc * 1000 / (Double.pi * d)
        let rpm = min(max(idealRPM, machine.spindleRPM.lowerBound), machine.spindleRPM.upperBound)
        if idealRPM > machine.spindleRPM.upperBound {
            notes.append("Normal for a small tool: its ideal cutting speed would need \(Int((idealRPM / 1000).rounded())) 000 RPM, far beyond any desktop spindle. At the CR-1's \(Int(machine.spindleRPM.upperBound)) RPM the feed is lowered to keep the right chip load, so it simply cuts slower.")
        } else if idealRPM < machine.spindleRPM.lowerBound {
            notes.append("Raised to the CR-1's minimum of \(Int(machine.spindleRPM.lowerBound)) RPM; the chip load is kept, so the feed rises with it.")
        }

        // Chip load from the anchor table, scaled for the material and tool material.
        var fz: Double
        switch kind {
        case .facing, .adaptive, .floor, .bore, .chamfer: fz = lookup(anchorAdaptive, diameter: d)
        case .contour: fz = lookup(anchorContour, diameter: d)
        case .drill: fz = lookup(anchorAdaptive, diameter: d) * 0.6
        case .parallel, .waterline, .steepShallow, .scallop, .spiral, .radial, .rest: fz = lookup(anchorContour, diameter: d)
        case .engrave: fz = lookup(anchorContour, diameter: d) * 0.5  // a fine tip in a full-width slot
        case .thread: fz = lookup(anchorContour, diameter: d) * 0.4  // a full thread profile, a thin neck
        }
        fz *= material.chipLoadFactor
        if hss { fz *= 0.8 }

        // Engagement.
        var stepover: Double
        var stepdown: Double
        let depthScale = material.adaptiveDepthMax / 2.0  // aluminium = 1
        let reach = max(tool.fluteLength * 0.9, 0.1)
        switch kind {
        case .facing:
            stepover = 0.4 * d
            stepdown = min(0.04 * d * max(material.chipLoadFactor, 0.5), 0.3)
        case .adaptive:
            stepover = lookup(anchorAdaptiveStepover, diameter: d) * (material.adaptiveStepoverMax / 0.10)
            stepdown = min((roughing == .deep && d >= 3 ? 1.0 : 0.5) * d * depthScale, reach)
            // Radial chip thinning: at low engagement the real chip is thinner than fz, so the
            // feed can rise. The table style keeps it low (×1.15); chip-thinned restores the
            // table's chip up to ×1.6.
            let ae = min(stepover, d / 2)
            let thinning = min(d / (2 * (d * ae - ae * ae).squareRoot()), roughing == .table ? 1.15 : 1.6)
            if thinning > 1.01 {
                fz *= thinning
                notes.append("Chip thinning at \(Int((ae / d * 100).rounded()))% engagement: feed raised \(Int(((thinning - 1) * 100).rounded()))%.")
            }
        case .contour:
            stepover = lookup(anchorFinishStepover, diameter: d)
            stepdown = min(1.5 * d * depthScale, reach)
        case .floor:
            stepover = 0.4 * d
            stepdown = 0
        case .drill:
            stepover = 0
            stepdown = min(max(0.25 * d * material.chipLoadFactor, 0.2 * d), d)  // peck depth
        case .bore:
            stepover = 0
            stepdown = min(0.25 * d * depthScale, reach)  // depth per helix turn
        case .chamfer:
            stepover = 0
            stepdown = 0
        case .parallel, .waterline, .steepShallow, .scallop, .spiral, .radial, .rest:
            // From the cusp height: the default leaves 8 µm cusps (Operation.scallop changes it).
            stepover = scallopStepover(tool: tool, cusp: 0.008)
            stepdown = stepover  // waterline spacing on steep walls
            notes.append("Stepover \(Length.mm(stepover)) mm leaves cusps about 8 µm high.")
        case .thread:
            stepover = 0
            stepdown = 0
            notes.append("The feed is at the cutting edge; on the inside of the thread the tool's centre runs slower (the engine scales it), so the edge's chip stays as set.")
        case .engrave:
            stepover = 0
            stepdown = min(0.1 * d, 0.2)  // engraving depth per pass
        }

        var feed = rpm * flutes * fz
        if kind == .drill { feed = rpm * fz * 2 }  // drills: feed per rev ≈ two "teeth"
        let cap = machine.maxFeedAnyDirection
        if feed > cap {
            notes.append("Feed capped at the CR-1's \(Int(cap)) mm/min.")
            feed = cap
        }
        let plunge = kind == .drill ? feed : feed * 0.35
        let ramp = feed * 0.8

        // Power at full engagement: P = ae · ap · vf · kc / 60 000 (W).
        let ae = kind == .adaptive || kind == .facing || kind == .floor ? stepover : (kind == .contour ? stepover : d)
        let ap = kind == .facing ? stepdown : (kind == .drill || kind == .bore ? d : stepdown)
        let power = ae * ap * feed * material.specificCuttingForce / 60_000
        if power > machine.estimatedSpindlePower * 0.8 {
            notes.append("Estimated \(Int(power)) W is near the spindle's estimated \(Int(machine.estimatedSpindlePower)) W. Coastline will reduce the depth of cut.")
        }

        if notes.isEmpty {
            notes.append("Coast Runner's aluminium values for this tool size, scaled for \(material.name).")
        }
        return CuttingData(rpm: rpm.rounded(), feed: feed.rounded(), plungeFeed: plunge.rounded(), rampFeed: ramp.rounded(),
                           chipLoad: fz, stepdown: stepdown, stepover: stepover,
                           rampAngle: material.difficulty >= .careful ? 1.0 : 2.0, power: power, notes: notes)
    }
}
