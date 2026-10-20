import Foundation
import simd

/// Engraving that follows the real surface of uneven stock, with CRWrite's contour mapping
/// (its software M-codes, ports of Coast Runner's ContourMapping):
///
/// - `M114` clears the map; `M111 Z… F…` probes down (G38.2) and adds the hit to it;
/// - `M112` turns the Z compensation on: every move's Z gets the probed surface's height at
///   its X/Y added (a plane through the nearest three points), `M113` turns it off. CRWrite
///   turns it off at the start of every program, so the engraving program turns it on itself.
///
/// The probe program uses the engraving tool, right after its touch-off (the map is in machine
/// Z, compensated against the touch-off), with the stock electrically insulated in the clamp
/// kit: M4 S1500 and F20, as the Operator Manual probes. The points are on the engraving's own
/// cut positions, so every probe lands on the face that gets engraved. The engraving program is
/// then written relative to the nominal face (its Z minus the face's height), and CRWrite adds
/// the measured height back. Only for engravings on a flat face: on a curved one the
/// compensation would add the curve a second time.
public enum SurfaceProbe {
    /// Points: at most this many, spread over the engraving.
    public static let maxPoints = 9

    /// Where to probe: up to `maxPoints` of the cut positions, spread out (the extremes first,
    /// then whichever is furthest from those taken). Nil: fewer than three distinct ones.
    public static func points(cuts: [SIMD2<Double>], count: Int = maxPoints) -> [SIMD2<Double>]? {
        var pts: [SIMD2<Double>] = []
        for p in cuts where !pts.contains(where: { simd_distance($0, p) < 0.5 }) { pts.append(p) }
        guard pts.count >= 3 else { return nil }
        var chosen: [SIMD2<Double>] = [
            pts.min { $0.x + $0.y < $1.x + $1.y }!, pts.max { $0.x + $0.y < $1.x + $1.y }!,
            pts.min { $0.x - $0.y < $1.x - $1.y }!, pts.max { $0.x - $0.y < $1.x - $1.y }!,
        ]
        chosen = chosen.reduce(into: []) { acc, p in if !acc.contains(where: { simd_distance($0, p) < 0.5 }) { acc.append(p) } }
        while chosen.count < min(count, pts.count) {
            guard let next = pts.max(by: { a, b in
                chosen.map { simd_distance($0, a) }.min()! < chosen.map { simd_distance($0, b) }.min()!
            }), chosen.map({ simd_distance($0, next) }).min()! > 0.5 else { break }
            chosen.append(next)
        }
        return chosen.count >= 3 ? chosen : nil
    }

    /// The face under an engraving if it's flat: the deepest cut at each spot (it may go down
    /// in passes) within `tolerance` everywhere; the face's height is that plus the depth.
    /// Nil: curved, so it follows the CAD instead. `spread`: how much the deepest cuts vary.
    public static func flatFace(cuts: [SIMD3<Double>], depth: Double, tolerance: Double = 0.05) -> (face: Double?, spread: Double) {
        var deepest: [SIMD2<Int>: Double] = [:]
        for c in cuts {
            let key = SIMD2(Int((c.x / 0.1).rounded()), Int((c.y / 0.1).rounded()))
            deepest[key] = min(deepest[key] ?? .infinity, c.z)
        }
        guard let lo = deepest.values.min(), let hi = deepest.values.max() else { return (nil, 0) }
        return (hi - lo <= tolerance ? (lo + hi) / 2 + depth : nil, hi - lo)
    }

    /// The probe program: clear the map, then at each point come down to 2 mm above the face
    /// (rapid at the safe height, feed below the approach height) and probe to 1.5 mm below it.
    /// Work coordinates (G54), absolute.
    public static func program(points: [SIMD2<Double>], face: Double, safeZ: Double = 3, approach: Double = 1,
                               above: Double = 2, below: Double = 1.5, machine: MachineProfile = .cr1) -> String {
        var lines = [
            "(Surface probing for the engraving: \(points.count) points)",
            "G21",
            "G90",
            "G54",
            "M114",
            "G0 Z\(CR1Post.fmt(safeZ))",
            "M4 S\(Int(machine.probeSpindleRPM))",
            "G4 P2",
        ]
        let start = face + above
        for p in points {
            lines.append("G0 X\(CR1Post.fmt(p.x)) Y\(CR1Post.fmt(p.y))")
            if start >= approach {
                lines.append("G0 Z\(CR1Post.fmt(start))")
            } else {
                lines.append("G0 Z\(CR1Post.fmt(approach))")
                lines.append("G1 Z\(CR1Post.fmt(start)) F200")
            }
            lines.append("M111 Z\(CR1Post.fmt(face - below)) F\(Int(machine.probeFeed))")
            lines.append("G0 Z\(CR1Post.fmt(safeZ))")
        }
        lines += ["M5", "G53 G0 Z-1"]
        return lines.joined(separator: "\n") + "\n"
    }

    /// The engraving program made to follow the probed surface: every work Z relative to the
    /// nominal face, compensation on before the moves and off before a machine-coordinate
    /// retract (G53 isn't compensated) and at the end. `moved[k]`: where original line k
    /// (0-based) is now, for the program's line map.
    public static func follow(_ gcode: String, face: Double) -> (text: String, moved: [Int]) {
        var out: [String] = []
        var moved: [Int] = []
        var on = false
        for raw in gcode.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            let code = line.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression).uppercased()
            let isMove = !code.contains("G53") && code.range(of: #"[XYZ]-?\d"#, options: .regularExpression) != nil
            if isMove {
                if !on {
                    out.append("M112 (follow the probed surface)")
                    on = true
                }
                if let r = line.range(of: #"Z(-?\d+(\.\d+)?)"#, options: .regularExpression) {
                    let v = Double(line[r].dropFirst()) ?? 0
                    line.replaceSubrange(r, with: "Z" + CR1Post.fmt(v - face))
                }
            } else if on && code.contains("G53") {
                out.append("M113")
                on = false
            }
            moved.append(out.count)
            out.append(line)
        }
        if on { out.append("M113") }
        return (out.joined(separator: "\n"), moved)
    }
}
