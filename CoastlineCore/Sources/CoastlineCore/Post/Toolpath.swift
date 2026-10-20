import Foundation

/// One move of a toolpath, in the work frame (mm).
public struct Move: Equatable, Sendable {
    public enum Role: Int, Sendable { case rapid = 0, cut = 1, plunge = 2, ramp = 3, lead = 4, link = 5 }
    public enum Motion: Int, Sendable { case line = 0, arcCW = 1, arcCCW = 2 }

    public var role: Role
    public var motion: Motion
    public var x, y, z: Double
    /// Arc centre offset from the start point (G17 plane), for arcs.
    public var i, j: Double
    /// mm/min; ignored for rapids.
    public var feed: Double

    public init(_ role: Role, _ motion: Motion = .line, x: Double, y: Double, z: Double,
                i: Double = 0, j: Double = 0, feed: Double = 0) {
        self.role = role
        self.motion = motion
        self.x = x
        self.y = y
        self.z = z
        self.i = i
        self.j = j
        self.feed = feed
    }

    public var position: SIMD3<Double> { SIMD3(x, y, z) }
}

/// The toolpath of one operation, as returned by the engine.
public struct OperationToolpath: Sendable {
    public var operationID: UUID
    public var moves: [Move]
    public var warnings: [String]
    /// Expected things the plan already handles (a smaller tool later takes what this one
    /// can't): shown quietly, not as warnings.
    public var notes: [String] = []

    /// Shortest stick-out that keeps the collet nut clear of the work (from the engine), mm.
    public var minStickout: Double?

    public init(operationID: UUID, moves: [Move], warnings: [String] = [], minStickout: Double? = nil) {
        self.operationID = operationID
        self.moves = moves
        self.warnings = warnings
        self.minStickout = minStickout
    }

    /// Decodes the engine's blob: float32 rows [role, motion, x, y, z, i, j, feed].
    public static func decode(operationID: UUID, blob: Data, warnings: [String]) -> OperationToolpath {
        let f = blob.littleEndianArray(of: Float.self)
        var moves: [Move] = []
        moves.reserveCapacity(f.count / 8)
        var k = 0
        while k + 7 < f.count {
            moves.append(Move(Move.Role(rawValue: Int(f[k])) ?? .cut, Move.Motion(rawValue: Int(f[k + 1])) ?? .line,
                              x: Double(f[k + 2]), y: Double(f[k + 3]), z: Double(f[k + 4]),
                              i: Double(f[k + 5]), j: Double(f[k + 6]), feed: Double(f[k + 7])))
            k += 8
        }
        return OperationToolpath(operationID: operationID, moves: moves, warnings: warnings)
    }
}

/// Toolpath geometry helpers shared by the viewer, time estimates and checks.
public enum ToolpathGeometry {
    /// Points along a move from `start`, arcs subdivided to `segmentAngle` radians.
    public static func points(of m: Move, from start: SIMD3<Double>, segmentAngle: Double = 0.1) -> [SIMD3<Double>] {
        guard m.motion != .line else { return [m.position] }
        let c = SIMD2(start.x + m.i, start.y + m.j)
        let r = ((start.x - c.x) * (start.x - c.x) + (start.y - c.y) * (start.y - c.y)).squareRoot()
        var a0 = atan2(start.y - c.y, start.x - c.x)
        var a1 = atan2(m.y - c.y, m.x - c.x)
        if m.motion == .arcCCW { while a1 <= a0 + 1e-9 { a1 += 2 * .pi } } else { while a0 <= a1 + 1e-9 { a0 += 2 * .pi } }
        let sweep = a1 - a0
        let n = max(Int((abs(sweep) / segmentAngle).rounded(.up)), 2)
        return (1...n).map { k in
            let t = Double(k) / Double(n)
            let a = a0 + sweep * t
            return SIMD3(c.x + r * cos(a), c.y + r * sin(a), start.z + (m.z - start.z) * t)
        }
    }

    /// Length of a move, mm.
    public static func length(of m: Move, from start: SIMD3<Double>) -> Double {
        var p = start, total = 0.0
        for q in points(of: m, from: start, segmentAngle: 0.05) {
            total += ((q - p) * (q - p)).sum().squareRoot()
            p = q
        }
        return total
    }
}
