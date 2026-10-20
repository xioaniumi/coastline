import Foundation
import simd

/// Workholding stock that must survive both sides: the strips along the edges the clamp jaws
/// grip (the top and bottom edges of the face, work X, along the whole length). No operation
/// cuts into them below the face, so after side A and side B the frame is still one piece the
/// jaws hold, and the part hangs in it on its tabs. Industry practice for frame-and-tab parts
/// ("leave clamping stock"); without it a part close to the clamped edges is cut free of the
/// frame on the second side.
public enum GripZones {
    /// How much stock the jaws keep along each clamped edge, mm.
    public static let grip = 3.0

    /// The cutter that runs the channel between the part and the frame (1/8" end mill).
    public static let channelTool = 3.175

    /// Stock height (work X) a part needs for a proper frame: the strip the jaws hold, a channel
    /// one cutter wide and a little clearance on each clamped side. The part then floats in the
    /// frame on its tabs instead of being held by bridges.
    public static func neededHeight(partX: Double) -> Double {
        partX + 2 * (grip + channelTool + 0.5)
    }

    /// The strips in the work frame (XY rectangles), with room beyond the stock so the tool can't
    /// reach around them.
    public static func strips(stock s: SIMD3<Double>, grip g: Double = grip) -> [(min: SIMD2<Double>, max: SIMD2<Double>)] {
        let outside = 30.0
        return [
            (SIMD2(s.x / 2 - g, -s.y / 2 - outside), SIMD2(s.x / 2 + outside, s.y / 2 + outside)),
            (SIMD2(-s.x / 2 - outside, -s.y / 2 - outside), SIMD2(-s.x / 2 + g, s.y / 2 + outside)),
        ]
    }

    /// How close the part comes to a clamped edge (work X), from its silhouette's X extent.
    public static func edgeMargin(stock s: SIMD3<Double>, partMinX: Double, partMaxX: Double) -> Double {
        min(s.x / 2 - partMaxX, partMinX + s.x / 2)
    }

    /// Removes the parts of a toolpath where the tool (radius + `margin`) would cut into a strip
    /// below `below` (work Z): the tool lifts to `safeZ`, moves over and comes back down where the
    /// path leaves the strip. What it skips stays joined to the frame (a bridge). Returns the new
    /// moves and how much cutting (mm) was skipped.
    public static func clip(_ moves: [Move], tool: Tool, strips: [(min: SIMD2<Double>, max: SIMD2<Double>)],
                            below: Double, safeZ: Double = 3, margin: Double = 0.5, plungeFeed: Double) -> (moves: [Move], skipped: Double) {
        guard let first = moves.first, !strips.isEmpty else { return (moves, 0) }
        let reach = tool.diameter / 2 + margin
        func blocked(_ p: SIMD3<Double>) -> Bool {
            guard p.z < below else { return false }
            for r in strips {
                let dx = max(r.min.x - p.x, 0, p.x - r.max.x), dy = max(r.min.y - p.y, 0, p.y - r.max.y)
                if dx * dx + dy * dy < reach * reach { return true }
            }
            return false
        }
        var out: [Move] = []
        out.reserveCapacity(moves.count)
        var skipped = 0.0
        var prev = first.position
        var lifted = false  // currently skipping (up at safe Z)
        for (k, m) in moves.enumerated() {
            defer { prev = m.position }
            if k == 0 || m.role == .rapid {
                if lifted {
                    // Rapids are above the work: carry on from the safe height.
                    out.append(Move(.rapid, x: m.x, y: m.y, z: max(m.z, safeZ)))
                    if m.z < safeZ { out.append(Move(.rapid, x: m.x, y: m.y, z: m.z)) }
                    lifted = false
                } else {
                    out.append(m)
                }
                continue
            }
            let pts = FixtureClearance.samples(from: prev, m, step: 0.25)
            let anyBlocked = blocked(prev) || pts.contains(where: blocked)
            if !anyBlocked && !lifted {
                out.append(m)
                continue
            }
            // Walk the move in short steps, cutting what's allowed and hopping over the rest.
            var last = prev
            for p in pts {
                if blocked(p) {
                    if !lifted {
                        out.append(Move(.rapid, x: last.x, y: last.y, z: safeZ))
                        lifted = true
                    }
                    skipped += simd_length(p - last)
                } else {
                    if lifted {
                        out.append(Move(.rapid, x: p.x, y: p.y, z: safeZ))
                        out.append(Move(.plunge, x: p.x, y: p.y, z: p.z, feed: plungeFeed))
                        lifted = false
                    } else {
                        out.append(Move(m.role == .rapid ? .rapid : m.role, x: p.x, y: p.y, z: p.z, feed: m.feed))
                    }
                }
                last = p
            }
        }
        if lifted, let l = out.last { out.append(Move(.rapid, x: l.x, y: l.y, z: safeZ)) }
        return (out, skipped)
    }
}
