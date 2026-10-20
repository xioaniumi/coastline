import Foundation

/// The edge finder's visits after a clamping, so the viewer can show them like a program:
/// the spinning Fisher edge finder comes down beside each edge of the face and creeps in until
/// it kicks (lower and upper edge in X, left and right end in Y), as the guided job's steps do.
public enum EdgeFinding {
    /// Fisher A250: 0.2" tip on a 1/4" shank.
    public static let tool = Tool(id: UUID(uuidString: "E06EF1D0-0000-4000-8000-000000000001")!, name: "Edge finder (Fisher A250)",
                                  kind: .flatEndMill, diameter: 5.08, shankDiameter: 6.35, flutes: 0, fluteLength: 9,
                                  stickout: 32, overallLength: 63.5)

    public static func isEdgeFinder(_ t: Tool) -> Bool { t.id == tool.id }

    /// Work-frame moves (origin at the face's centre): down beside each edge at `depth` below
    /// the face, a slow creep to the touch, back off, up.
    /// `radius`: the touching tool's (electrical probing touches with the cutter itself).
    public static func moves(stock s: SIMD3<Double>, depth: Double = 1.5, radius: Double? = nil) -> [Move] {
        let r = radius ?? tool.diameter / 2, away = 6.0
        var out: [Move] = []
        let edges: [(SIMD2<Double>, SIMD2<Double>)] = [  // (start beside the edge, touch)
            (SIMD2(-s.x / 2 - r - away, 0), SIMD2(-s.x / 2 - r, 0)),
            (SIMD2(s.x / 2 + r + away, 0), SIMD2(s.x / 2 + r, 0)),
            (SIMD2(0, -s.y / 2 - r - away), SIMD2(0, -s.y / 2 - r)),
            (SIMD2(0, s.y / 2 + r + away), SIMD2(0, s.y / 2 + r)),
        ]
        for (from, touch) in edges {
            out.append(Move(.rapid, x: from.x, y: from.y, z: 5))
            out.append(Move(.plunge, x: from.x, y: from.y, z: -depth, feed: 400))
            out.append(Move(.lead, x: touch.x, y: touch.y, z: -depth, feed: 120))
            out.append(Move(.lead, x: from.x, y: from.y, z: -depth, feed: 400))
            out.append(Move(.rapid, x: from.x, y: from.y, z: 5))
        }
        return out
    }
}
