import Foundation

/// ISO metric coarse threads (ISO 261/724), the ones small parts use. A milled internal thread
/// goes into a hole made at the tap-drill size (major − pitch); the cutter's centre runs on a
/// helix of radius (major − cutter) / 2, rising one pitch a turn.
public struct ThreadSpec: Equatable, Hashable, Sendable, Codable, Identifiable {
    public var name: String
    /// Nominal (major) diameter, mm.
    public var major: Double
    /// mm per turn.
    public var pitch: Double

    public var id: String { name }
    /// The hole to make first: the usual tap drill, major − pitch.
    public var tapDrill: Double { ((major - pitch) * 100).rounded() / 100 }
    /// The basic minor diameter of the nut thread (D1 = D − 1.0825 P).
    public var minor: Double { major - 1.082532 * pitch }
    /// How deep the thread profile cuts into the wall from the tap-drill hole.
    public var profileDepth: Double { (major - tapDrill) / 2 }
    public var title: String { "\(name) × \(pitch.formatted(.number.precision(.fractionLength(1...2))))" }

    public static let metricCoarse: [ThreadSpec] = [
        .init(name: "M1.6", major: 1.6, pitch: 0.35), .init(name: "M2", major: 2, pitch: 0.4),
        .init(name: "M2.5", major: 2.5, pitch: 0.45), .init(name: "M3", major: 3, pitch: 0.5),
        .init(name: "M4", major: 4, pitch: 0.7), .init(name: "M5", major: 5, pitch: 0.8),
        .init(name: "M6", major: 6, pitch: 1.0), .init(name: "M8", major: 8, pitch: 1.25),
    ]

    public static func named(_ name: String) -> ThreadSpec? { metricCoarse.first { $0.name == name } }

    /// The holes it goes into: made at about the tap drill, from the thread's minor diameter to
    /// a little over the tap drill (not as far as the next size's clearance hole: Ø3.4 is an M3
    /// screw's, not an M4 thread's).
    public var holeRange: ClosedRange<Double> { (minor - 0.05)...(tapDrill + 0.08) }

    public func fits(hole diameter: Double) -> Bool { holeRange.contains(diameter) }

    /// The thread a hole of this diameter was most likely made for (nil: none is close).
    public static func likely(forHole diameter: Double) -> ThreadSpec? {
        metricCoarse.filter { $0.fits(hole: diameter) }.min { abs($0.tapDrill - diameter) < abs($1.tapDrill - diameter) }
    }

    /// Can this thread mill cut it? A single-form cutter smaller than the hole, with a profile
    /// made for this pitch (or for any, when its pitch isn't known).
    public func canBeCut(by tool: Tool) -> Bool {
        tool.kind == .threadMill && tool.diameter < tapDrill - 0.05 && tool.diameter < major
            && (tool.threadPitch.map { abs($0 - pitch) < 0.01 } ?? true)
    }
}

/// A thread milling operation's settings: which thread, and how deep (nil: the hole's full
/// depth, as far as the cutter reaches).
public struct ThreadMilling: Equatable, Sendable, Codable {
    public var spec: String
    public var depth: Double?
    public init(spec: String, depth: Double? = nil) {
        self.spec = spec
        self.depth = depth
    }
    public var thread: ThreadSpec? { ThreadSpec.named(spec) }
}
