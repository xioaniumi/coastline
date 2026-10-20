import CoreText
import Foundation
import simd

/// Text engraved into the part: its glyph outlines, traced at a fixed depth below
/// the part's surface (the engine drops each point onto the surface first, so text on a dome
/// stays the same depth all over).
public struct Engraving: Codable, Equatable, Sendable {
    public var text: String
    /// Cap height, mm.
    public var height: Double = 4
    /// Centre of the text in the work frame (X up, Y along the bar) and its turn, degrees.
    public var x: Double = 0
    public var y: Double = 0
    public var angle: Double = 0
    /// Depth below the surface, mm.
    public var depth: Double = 0.15
    /// A font installed on the Mac (PostScript or family name).
    public var font = "Helvetica-Bold"
    /// Which side it goes on (0 = A, the face; 1 = B, the back of a two-sided part).
    public var side = 0
    /// Probe the face first and follow it (uneven stock): CRWrite's contour mapping (SurfaceProbe).
    /// Only on a flat face, conductive stock, in the insulated clamp kit.
    public var probeSurface: Bool?
    /// A decorative texture instead of the text (Texture: guilloché, clous de Paris…), at the
    /// same position, turn, depth and side.
    public var texture: Texture?

    public init(text: String, height: Double = 4, x: Double = 0, y: Double = 0, angle: Double = 0, depth: Double = 0.15,
                font: String = "Helvetica-Bold") {
        self.text = text
        self.height = height
        self.x = x
        self.y = y
        self.angle = angle
        self.depth = depth
        self.font = font
    }

    /// The glyph outlines as closed polylines in the work frame's XY (text reads along +Y with
    /// its top toward +X, like reading the face from the spindle), flattened to `tolerance`.
    public func polylines(tolerance: Double = 0.02) -> [[SIMD2<Double>]] {
        if let texture {
            // Its own frame (u along, v up) into the work frame, as the text below.
            let a = angle * .pi / 180, ca = cos(a), sa = sin(a)
            return texture.lines().map { line in
                line.map { q in SIMD2(x + q.x * sa + q.y * ca, y + q.x * ca - q.y * sa) }
            }
        }
        guard !text.isEmpty else { return [] }
        let ctFont = CTFontCreateWithName(font as CFString, 100, nil)
        let capHeight = max(CTFontGetCapHeight(ctFont), 1)
        let scale = height / Double(capHeight)
        let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): ctFont])
        let line = CTLineCreateWithAttributedString(attr)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        var loops: [[SIMD2<Double>]] = []
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = attrs[kCTFontAttributeName] as! CTFont
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n), positions = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
            for k in 0..<n {
                guard let path = CTFontCreatePathForGlyph(runFont, glyphs[k], nil) else { continue }
                var current: [SIMD2<Double>] = []
                var start = SIMD2<Double>.zero
                func p(_ q: CGPoint) -> SIMD2<Double> { SIMD2(Double(q.x + positions[k].x), Double(q.y + positions[k].y)) }
                path.applyWithBlock { e in
                    let el = e.pointee
                    switch el.type {
                    case .moveToPoint:
                        if current.count > 2 { loops.append(current) }
                        start = p(el.points[0])
                        current = [start]
                    case .addLineToPoint:
                        current.append(p(el.points[0]))
                    case .addQuadCurveToPoint:
                        let a = current.last ?? start, c = p(el.points[0]), b = p(el.points[1])
                        let steps = Self.steps(chord: simd_distance(a, b) * scale, tol: tolerance)
                        for i in 1...steps {
                            let t = Double(i) / Double(steps), u = 1 - t
                            current.append(a * (u * u) + c * (2 * u * t) + b * (t * t))
                        }
                    case .addCurveToPoint:
                        let a = current.last ?? start, c1 = p(el.points[0]), c2 = p(el.points[1]), b = p(el.points[2])
                        let steps = Self.steps(chord: simd_distance(a, b) * scale, tol: tolerance)
                        for i in 1...steps {
                            let t = Double(i) / Double(steps), u = 1 - t
                            current.append(a * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + b * (t * t * t))
                        }
                    case .closeSubpath:
                        if current.count > 2 { current.append(current[0]); loops.append(current) }
                        current = []
                    @unknown default: break
                    }
                }
                if current.count > 2 { loops.append(current) }
            }
        }
        // Font units → mm, centred, then into the work frame: text x → work Y, text y → work X.
        let cx = width / 2, cy = Double(capHeight) / 2
        let a = angle * .pi / 180, ca = cos(a), sa = sin(a)
        return loops.map { loop in
            loop.map { q in
                let u = (q.x - cx) * scale, v = (q.y - cy) * scale  // along, up
                let along = u * ca - v * sa, up = u * sa + v * ca
                return SIMD2(x + up, y + along)
            }
        }
    }

    static func steps(chord: Double, tol: Double) -> Int { min(max(Int((chord / max(tol * 20, 0.05)).rounded(.up)), 2), 24) }

    /// Width (along Y) and height (X) of the text, mm.
    public var size: SIMD2<Double> {
        if let texture { return texture.size }
        let pts = polylines().flatMap { $0 }
        guard let f = pts.first else { return .zero }
        var lo = f, hi = f
        for p in pts { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return SIMD2(hi.y - lo.y, hi.x - lo.x)
    }
}
