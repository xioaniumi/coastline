import Foundation
import simd

/// Decorative textures, cut like engraving (a V engraver or a small ball following the surface
/// at a set depth): the patterns of a watchmaker's rose engine and straight-line engine.
///
/// - **Sunburst** (soleil): straight rays from the centre, optionally waving.
/// - **Barleycorn** (grain d'orge): concentric rose rings, each turned half a lobe from the last,
///   so the cuts cross into a woven pattern.
/// - **Flinqué**: parallel waves across the area.
/// - **Clous de Paris** (hobnail): two sets of straight grooves at right angles; with a 90° V
///   cut half the pitch deep they meet in a field of small pyramids.
/// - **Spiral** (escargot): one Archimedean spiral out from the centre.
/// - **Rosette**: circles of the same size round the centre, overlapping into petals.
///
/// Lines are spaced `pitch` apart, clipped to a circle or a rectangle centred on the
/// engraving's position and turned by its angle.
public struct Texture: Codable, Equatable, Sendable {
    public enum Pattern: String, CaseIterable, Codable, Sendable, Identifiable {
        case sunburst, barleycorn, flinque, clousDeParis, spiral, rosette
        public var id: Self { self }
        public var title: String {
            switch self {
            case .sunburst: "Sunburst (soleil)"
            case .barleycorn: "Barleycorn (grain d'orge)"
            case .flinque: "Flinqué waves"
            case .clousDeParis: "Clous de Paris (hobnail)"
            case .spiral: "Spiral (escargot)"
            case .rosette: "Rosette"
            }
        }
        /// Whether `lobes` and `amplitude` shape it.
        public var waves: Bool { [.sunburst, .barleycorn, .flinque, .rosette].contains(self) }
    }

    public enum Region: String, CaseIterable, Codable, Sendable {
        case circle, rectangle
    }

    public var pattern: Pattern
    public var region: Region
    /// The circle's diameter, or the rectangle's size (along Y, up X), mm.
    public var width: Double
    public var height: Double
    /// Between neighbouring lines, mm.
    public var pitch: Double
    /// How far the waves swing (mm; sunburst: degrees of the ray's wave), and how many there are
    /// round the circle or across the area.
    public var amplitude: Double
    public var lobes: Int

    public init(pattern: Pattern, region: Region = .circle, width: Double = 16, height: Double = 16, pitch: Double = 0.6,
                amplitude: Double = 0.4, lobes: Int = 12) {
        self.pattern = pattern
        self.region = region
        self.width = width
        self.height = height
        self.pitch = pitch
        self.amplitude = amplitude
        self.lobes = lobes
    }

    /// A good starting point for each pattern.
    public static func preset(_ p: Pattern) -> Texture {
        switch p {
        case .sunburst: Texture(pattern: p, pitch: 0.5, amplitude: 0, lobes: 0)
        case .barleycorn: Texture(pattern: p, pitch: 0.5, amplitude: 0.35, lobes: 18)
        case .flinque: Texture(pattern: p, region: .rectangle, width: 20, height: 12, pitch: 0.5, amplitude: 0.3, lobes: 6)
        case .clousDeParis: Texture(pattern: p, region: .rectangle, width: 20, height: 12, pitch: 0.8, amplitude: 0, lobes: 0)
        case .spiral: Texture(pattern: p, pitch: 0.5, amplitude: 0, lobes: 0)
        case .rosette: Texture(pattern: p, pitch: 0.6, amplitude: 3, lobes: 0)
        }
    }

    /// The pattern's lines in its own frame (centred on 0, u along, v up), clipped to the region.
    public func lines() -> [[SIMD2<Double>]] {
        let pitch = max(self.pitch, 0.05)
        let r = max(width, 0.5) / 2
        let half = SIMD2(max(width, 0.5) / 2, max(region == .circle ? width : height, 0.5) / 2)
        let reach = region == .circle ? r : simd_length(half)  // far enough to cover the region
        let step = 0.1
        var raw: [[SIMD2<Double>]] = []
        func circle(_ c: SIMD2<Double>, _ radius: Double, wave: (Double) -> Double = { _ in 0 }) -> [SIMD2<Double>] {
            let n = max(Int((2 * .pi * radius / step).rounded(.up)), 24)
            return (0...n).map { k in
                let t = 2 * Double.pi * Double(k) / Double(n)
                let rr = radius + wave(t)
                return c + SIMD2(rr * cos(t), rr * sin(t))
            }
        }
        switch pattern {
        case .sunburst:
            let rays = max(Int((2 * .pi * reach / pitch).rounded()), 8)
            let r0 = max(reach * 0.06, 0.4)  // the rays crowd at the centre: they start a little out
            for k in 0..<rays {
                let a0 = 2 * Double.pi * Double(k) / Double(rays)
                let n = max(Int(((reach - r0) / step).rounded(.up)), 2)
                raw.append((0...n).map { i in
                    let rr = r0 + (reach - r0) * Double(i) / Double(n)
                    let a = a0 + amplitude * .pi / 180 * sin(Double(max(lobes, 1)) * 2 * .pi * rr / reach)
                    return SIMD2(rr * cos(a), rr * sin(a))
                })
            }
        case .barleycorn:
            let n = max(lobes, 3)
            // A small plain centre, as on a dial: rings closer in would bunch into a star.
            var radius = max(pitch, 2.5 * amplitude)
            var ring = 0
            while radius - amplitude <= reach {
                let phase = Double(ring % 2) * .pi / Double(n)
                raw.append(circle(.zero, radius) { amplitude * cos(Double(n) * $0 + phase) })
                radius += pitch
                ring += 1
            }
        case .flinque:
            let waves = Double(max(lobes, 1))
            var v = -reach
            while v <= reach {
                let n = max(Int((2 * reach / step).rounded(.up)), 2)
                raw.append((0...n).map { i in
                    let u = -reach + 2 * reach * Double(i) / Double(n)
                    return SIMD2(u, v + amplitude * sin(2 * .pi * waves * (u + reach) / (2 * half.x)))
                })
                v += pitch
            }
        case .clousDeParis:
            for a in [Double.pi / 4, -Double.pi / 4] {
                let d = SIMD2(cos(a), sin(a)), nrm = SIMD2(-d.y, d.x)
                var off = -reach
                while off <= reach {
                    let n = max(Int((2 * reach / step).rounded(.up)), 2)
                    raw.append((0...n).map { i in nrm * off + d * (-reach + 2 * reach * Double(i) / Double(n)) })
                    off += pitch
                }
            }
        case .spiral:
            let turns = reach / pitch
            let n = max(Int((Double.pi * reach * turns / step).rounded(.up)), 24)
            raw.append((0...n).map { i in
                let t = 2 * Double.pi * turns * Double(i) / Double(n)
                let rr = pitch * t / (2 * .pi)
                return SIMD2(rr * cos(t), rr * sin(t))
            })
        case .rosette:
            let offset = min(max(amplitude, pitch), reach * 0.9)
            let radius = reach - offset
            let count = max(Int((2 * .pi * offset / pitch).rounded()), 6)
            for k in 0..<count {
                let a = 2 * Double.pi * Double(k) / Double(count)
                raw.append(circle(SIMD2(offset * cos(a), offset * sin(a)), radius))
            }
        }
        func inside(_ p: SIMD2<Double>) -> Bool {
            region == .circle ? simd_length(p) <= r + 1e-9 : abs(p.x) <= half.x + 1e-9 && abs(p.y) <= half.y + 1e-9
        }
        // Clipped: each line split where it leaves the region (pieces under 0.3 mm dropped).
        var out: [[SIMD2<Double>]] = []
        for line in raw {
            var run: [SIMD2<Double>] = []
            for p in line {
                if inside(p) {
                    run.append(p)
                } else if !run.isEmpty {
                    if run.count > 3 { out.append(run) }
                    run = []
                }
            }
            if run.count > 3 { out.append(run) }
        }
        return out
    }

    /// The region's size (along Y, up X), mm.
    public var size: SIMD2<Double> { region == .circle ? SIMD2(width, width) : SIMD2(width, height) }
}
