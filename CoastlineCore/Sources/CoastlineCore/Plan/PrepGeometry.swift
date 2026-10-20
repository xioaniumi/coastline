import Foundation

/// What the bar looks like at each prep step and what that step mills off, for drawing it
/// (the stepped bar on the bed, the cut in orange, numbered).
///
/// The bar's own coordinates: `u` along its length (centred on the bar as bought, end A at
/// −length/2), `v` up from its bottom long edge (0…width, the top edge is the one milled first).
/// Shoulders (path D) are cut at both ends: the top first, then (turned over) the bottom.
extension FlatPrep.Plan {
    public struct BarBox: Sendable, Equatable {
        public var u: ClosedRange<Double>
        public var v: ClosedRange<Double>
        public init(u: ClosedRange<Double>, v: ClosedRange<Double>) { self.u = u; self.v = v }
    }

    public struct Box: Sendable, Equatable {
        public var min: SIMD3<Double>
        public var max: SIMD3<Double>
        public init(min: SIMD3<Double>, max: SIMD3<Double>) { self.min = min; self.max = max }
        public var centre: SIMD3<Double> { (min + max) / 2 }
    }

    /// How much each step has taken before step `k` (top edge, bottom edge, end A faced).
    private func done(before k: Int) -> (top: Double, bottom: Double, faced: Bool) {
        var top = 0.0, bottom = 0.0, faced = false
        for s in stages.prefix(max(k, 0)) {
            switch s.kind {
            case .faceEnd: faced = true
            case .edge: if s.otherEdge { bottom += s.cut } else { top += s.cut }
            }
        }
        return (top, bottom, faced)
    }

    private var endA: Double { -length / 2 + (faceEnds ? FlatPrep.faceAllowance : 0) }

    /// The two shoulder stretches along the bar (after end A is faced).
    private func shoulderSpans(_ ls: Double) -> [ClosedRange<Double>] {
        [endA...(endA + ls), (length / 2 - ls)...(length / 2)]
    }

    /// The bar before step `k` (k < 0: as bought).
    public func barMaterial(before k: Int, shoulderLength ls: Double?) -> [BarBox] {
        let d = done(before: k)
        let a = -length / 2 + (d.faced ? FlatPrep.faceAllowance : 0), b = length / 2
        guard let ls else { return [BarBox(u: a...b, v: 0...(width - d.top))] }
        let spans = shoulderSpans(ls)
        let ends = [BarBox(u: a...spans[0].upperBound, v: d.bottom...(width - d.top)),
                    BarBox(u: spans[1], v: d.bottom...(width - d.top))]
        return [BarBox(u: spans[0].upperBound...spans[1].lowerBound, v: 0...width)] + ends
    }

    /// What step `j` mills off.
    public func barCut(_ j: Int, shoulderLength ls: Double?) -> [BarBox] {
        guard stages.indices.contains(j) else { return [] }
        let s = stages[j], d = done(before: j)
        switch s.kind {
        case .faceEnd:
            return [BarBox(u: (-length / 2)...(-length / 2 + s.cut), v: 0...width)]
        case .edge:
            let along = ls.map { shoulderSpans($0) } ?? [(-length / 2 + (d.faced ? FlatPrep.faceAllowance : 0))...(length / 2)]
            let v = s.otherEdge ? d.bottom...(d.bottom + s.cut) : (width - d.top - s.cut)...(width - d.top)
            return along.map { BarBox(u: $0, v: v) }
        }
    }

    /// Bar boxes in step `k`'s clamping frame (k < 0: as bought, top edge toward the spindle):
    /// X the bar's thickness (centred), Y along the table (centred), Z toward the spindle with
    /// the face being cut at Z0 — the frame the prep view draws the bar in.
    public func frameBoxes(_ boxes: [BarBox], stage k: Int) -> [Box] {
        let t = thickness / 2
        func box(_ y: ClosedRange<Double>, _ z: ClosedRange<Double>) -> Box {
            Box(min: SIMD3(-t, y.lowerBound, z.lowerBound), max: SIMD3(t, y.upperBound, z.upperBound))
        }
        func span(_ a: Double, _ b: Double) -> ClosedRange<Double> { min(a, b)...max(a, b) }
        guard stages.indices.contains(k) else {
            return boxes.map { box($0.u, span($0.v.lowerBound - width, $0.v.upperBound - width)) }
        }
        let s = stages[k], d = done(before: k)
        switch s.kind {
        case .faceEnd:
            // Turned with its length toward the spindle: end A at Z0, the width along the table.
            return boxes.map { box(span($0.v.lowerBound - width / 2, $0.v.upperBound - width / 2),
                                   span(-($0.u.lowerBound + length / 2), -($0.u.upperBound + length / 2))) }
        case .edge:
            let uc = (-length / 2 + (d.faced ? FlatPrep.faceAllowance : 0) + length / 2) / 2
            if s.otherEdge {
                // Turned over: the bottom edge toward the spindle.
                return boxes.map { box(span($0.u.lowerBound - uc, $0.u.upperBound - uc),
                                       span(d.bottom - $0.v.lowerBound, d.bottom - $0.v.upperBound)) }
            }
            let face = width - d.top
            return boxes.map { box(span($0.u.lowerBound - uc, $0.u.upperBound - uc),
                                   span($0.v.lowerBound - face, $0.v.upperBound - face)) }
        }
    }
}
