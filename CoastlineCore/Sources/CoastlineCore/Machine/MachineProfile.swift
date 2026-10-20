import Foundation

/// A 3D point or vector in millimetres.
public struct Vec3: Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
    public var x, y, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { (self.x, self.y, self.z) = (x, y, z) }
    public static let zero = Vec3(0, 0, 0)
    public var description: String { "(\(x), \(y), \(z))" }
}

/// An inclusive range per axis, in machine coordinates (mm).
public struct AxisBox: Equatable, Sendable, Codable {
    public var x, y, z: ClosedRange<Double>
    public init(x: ClosedRange<Double>, y: ClosedRange<Double>, z: ClosedRange<Double>) {
        (self.x, self.y, self.z) = (x, y, z)
    }
    public func contains(_ p: Vec3, margin: Double = 0) -> Bool {
        x.lowerBound + margin <= p.x && p.x <= x.upperBound - margin
            && y.lowerBound + margin <= p.y && p.y <= y.upperBound - margin
            && z.lowerBound + margin <= p.z && p.z <= z.upperBound - margin
    }
}

/// Everything Coastline knows about a machine. Values are the hard limits that the planner,
/// the post-processor and the safety validator use, so every number cites its source.
///
/// Sources:
/// - [FW]  CR-1 firmware `grblCR/defaults.h`, `DEFAULTS_CR1` (Coast Runner firmware repository)
/// - [MAN] Coast Runner Operator Manual v0.9 (Nov 2024)
/// - [CPS] Coast Runner's Fusion post `Coast_Runner_CR-1_Postprocessor.cps`
/// - [UC]  Universal Clamp cutcode `universal_clamp_v1_WFzXVS736N.14.crproj`
/// - [CRC] `CRCore/GRBL/RealTimeStatus.swift` (soft-limit maths)
/// - [DIM] `CoastRunnerCNCDimensions.3dm` (a measured envelope model)
public struct MachineProfile: Equatable, Sendable, Codable {
    public var name: String

    // MARK: Motion

    /// Travel per axis, mm ($130–$132). [FW]
    public var travel: Vec3
    /// Reachable machine coordinates. Home is the 0 corner; everything is negative. CRWrite's
    /// soft-limit window: X −(travel−0.5)…−0.5, Y and Z −travel…−0.5. [CRC]
    public var machineEnvelope: AxisBox
    /// Max feed per axis, mm/min ($110–$112). [FW]
    public var maxRate: Vec3
    /// Acceleration per axis, mm/s² ($120–$122). [FW]
    public var acceleration: Vec3
    /// GRBL junction deviation ($11), mm. Used by the planner-aware time estimate. [FW]
    public var junctionDeviation: Double
    /// GRBL arc tolerance ($12), mm. [FW]
    public var arcTolerance: Double

    // MARK: Spindle

    /// RPM that actually turns the spindle. Below 1500 it doesn't spin; above 8000 it's
    /// clamped, even though the firmware reports $30=8500 / $31=1360. [MAN §5.2.3.2, §9.7.2]
    public var spindleRPM: ClosedRange<Double>
    /// RPM the post uses for the start ramp (S0 → 5000 → target). [CPS]
    public var spindleRampIntermediateRPM: Double
    /// Usable spindle power, W. **Estimated**: the manual doesn't state it (belt-driven NEMA 23
    /// BLDC). Used only to warn about heavy cuts; refine after real cuts. [EST]
    public var estimatedSpindlePower: Double

    // MARK: Tooling

    /// ER-11 collet. [MAN §2.1]
    public var colletName: String
    /// Largest shank the collet takes, mm. [MAN §2.1, §4.5]
    public var maxShankDiameter: Double
    /// Longest tool that can be homed without crashing, mm (3"). [MAN §4.2]
    public var maxToolLength: Double
    /// How deep a shank seats in the collet/bore, mm (~0.9"). [MAN §4.5]
    public var colletSeatDepth: Double
    /// Machine-coordinate tool-change position, visited in this order after `$H`. [UC]
    public var toolChangeMoves: [String]

    // MARK: Controller

    /// grbl rejects longer lines (error 11). [MAN §9]
    public var maxLineLength: Int
    /// grbl planner blocks; tiny segments starve it, hence arc fitting. [MAN §9]
    public var plannerBlocks: Int
    /// grbl's power-on distance mode is G91, so every program must set G90. [MAN §9.1]
    public var powerOnDistanceModeIsIncremental: Bool

    // MARK: Probing & workholding

    /// Fisher A250 edge finder tip, mm (0.2"). Offset = radius = 2.54 mm. [MAN §4.6]
    public var edgeFinderTipDiameter: Double
    /// Conductive probing feed, mm/min, and spindle mode (M4 S1500). [MAN §5.4, UC]
    public var probeFeed: Double
    public var probeSpindleRPM: Double
    /// Two T-slots with M4 T-slot nuts (11 × 3.14 × 15.87 mm). [MAN §4.4]
    public var tSlotCount: Int
    public var tSlotNut: String
    /// The physical work envelope box from the measured dimensions model: 242 (Y) × 89 (X) × 79 (Z).
    /// [DIM]
    public var physicalEnvelope: Vec3

    public static let cr1 = MachineProfile(
        name: "Coast Runner CR-1",
        travel: Vec3(86.5, 241.5, 78.5),
        machineEnvelope: AxisBox(x: -86.0 ... -0.5, y: -241.5 ... -0.5, z: -78.5 ... -0.5),
        maxRate: Vec3(2540, 3100, 3100),
        acceleration: Vec3(500, 500, 500),
        junctionDeviation: 0.02,
        arcTolerance: 0.002,
        spindleRPM: 1500 ... 8000,
        spindleRampIntermediateRPM: 5000,
        estimatedSpindlePower: 150,
        colletName: "ER-11",
        maxShankDiameter: 8.0,
        maxToolLength: 76.2,
        colletSeatDepth: 22.9,
        toolChangeMoves: ["$H", "G53 G0 Z-1", "G53 G0 Y-58", "G53 G0 X-1", "G53 G0 Z-60"],
        maxLineLength: 79,
        plannerBlocks: 16,
        powerOnDistanceModeIsIncremental: true,
        edgeFinderTipDiameter: 5.08,
        probeFeed: 20,
        probeSpindleRPM: 1500,
        tSlotCount: 2,
        tSlotNut: "M4 T-slot nut, 11 × 3.14 × 15.87 mm (Fairway JPPNM04016)",
        physicalEnvelope: Vec3(89, 242, 79)
    )

    /// The slowest axis limit: a safe single cap for 3D moves whose direction varies.
    public var maxFeedAnyDirection: Double { min(maxRate.x, maxRate.y, maxRate.z) }

    /// Is this RPM one the spindle will actually run at?
    public func isUsableRPM(_ rpm: Double) -> Bool { spindleRPM.contains(rpm) }
}

extension MachineProfile {
    /// The machine positions the tool-change moves pass through, in order (each G53 move
    /// changes one or more axes of the last position, starting from home): the spindle back,
    /// over, the table down, the spindle out. [UC]
    public var toolChangeWaypoints: [SIMD3<Double>] {
        let home = SIMD3(machineEnvelope.x.upperBound, machineEnvelope.y.upperBound, machineEnvelope.z.upperBound)
        var p = home, out: [SIMD3<Double>] = []
        for line in toolChangeMoves where line.uppercased().contains("G53") {
            for (k, axis) in ["X", "Y", "Z"].enumerated() {
                if let r = line.uppercased().range(of: "\(axis)(-?[0-9.]+)", options: .regularExpression),
                   let v = Double(line.uppercased()[r].dropFirst()) { p[k] = v }
            }
            out.append(p)
        }
        return out
    }

    /// Where the tool is changed: the table down (machine X is the tool's place relative to
    /// the table, so X−1 is the table at its lowest), the spindle out (the last waypoint).
    public var toolChangePose: SIMD3<Double> { toolChangeWaypoints.last ?? SIMD3(-1, -58, -60) }
}
