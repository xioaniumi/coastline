import Foundation

/// Every move of a job laid out in time, for playback, scrubbing and inspection.
public struct ToolpathTimeline: Sendable {
    public struct Entry: Sendable {
        public var start: SIMD3<Double>
        public var move: Move
        /// Index into the job's operation list.
        public var operation: Int
        /// Seconds from the start of the job.
        public var tStart: Double
        public var tEnd: Double
        /// 1-based line in the operation's G-code program, if the move produced a line.
        public var gcodeLine: Int?
        /// Index of the program (tool) this move belongs to.
        public var program: Int
    }

    public var entries: [Entry] = []
    public var duration: Double { entries.last?.tEnd ?? 0 }

    public init() {}

    /// Builds the timeline from per-operation toolpaths. `programOf[i]` is the program index of
    /// operation i; `lines[i]` maps operation i's moves to G-code lines.
    public init(paths: [OperationToolpath], programOf: [Int], lines: [[Int?]], machine: MachineProfile = .cr1) {
        // Times come from a simulation of grbl's planner (see `plannerSeconds`).
        var flat: [(oi: Int, mi: Int, start: SIMD3<Double>, move: Move)] = []
        var pos: SIMD3<Double>?
        for (oi, path) in paths.enumerated() {
            for (mi, m) in path.moves.enumerated() {
                flat.append((oi, mi, pos ?? m.position, m))
                pos = m.position
            }
        }
        let times = Self.plannerSeconds(flat.map { ($0.start, $0.move) }, machine: machine)
        var t = 0.0
        for (k, f) in flat.enumerated() {
            let dt = times[k]
            entries.append(Entry(start: f.start, move: f.move, operation: f.oi, tStart: t, tEnd: t + dt,
                                 gcodeLine: f.mi < (lines.indices.contains(f.oi) ? lines[f.oi].count : 0) ? lines[f.oi][f.mi] : nil,
                                 program: programOf.indices.contains(f.oi) ? programOf[f.oi] : 0))
            t += dt
        }
    }

    /// Seconds per move as grbl's planner would run them: arcs split into chords, a speed limit
    /// at every junction from the junction deviation (grbl's formula), a backward and a forward
    /// pass so every entry speed is reachable with the machine's acceleration, then trapezoidal
    /// (accelerate, cruise, decelerate) profiles. Corners and dense 3D paths slow down here
    /// exactly where the real machine does.
    public static func plannerSeconds(_ moves: [(start: SIMD3<Double>, move: Move)], machine: MachineProfile = .cr1) -> [Double] {
        let a = max(machine.acceleration.x, 1)          // mm/s²
        let jd = max(machine.junctionDeviation, 0.001)  // mm
        // Chords: (owner move, length, max speed mm/s, direction).
        var segs: [(owner: Int, len: Double, v: Double, dir: SIMD3<Double>)] = []
        for (k, item) in moves.enumerated() {
            let m = item.move
            let v = (m.role == .rapid ? machine.maxFeedAnyDirection : max(m.feed, 1)) / 60
            var pts = [item.start]
            pts += m.motion == .line ? [m.position] : ToolpathGeometry.points(of: m, from: item.start, segmentAngle: 0.1)
            for (p, q) in zip(pts, pts.dropFirst()) {
                let d = q - p
                let len = (d * d).sum().squareRoot()
                if len > 1e-6 { segs.append((k, len, v, d / len)) }
            }
        }
        var times = [Double](repeating: 0, count: moves.count)
        guard !segs.isEmpty else { return times }
        let n = segs.count
        // Junction limits (speed²) at the start of each chord.
        var entry = [Double](repeating: 0, count: n + 1)
        for i in 1..<n {
            let c = -(segs[i - 1].dir * segs[i].dir).sum()  // cos of the angle between them
            var vj2: Double
            if c > 0.999999 {
                vj2 = 0  // reversal
            } else if c < -0.999999 {
                vj2 = .infinity  // straight on
            } else {
                let sinHalf = ((1 - c) / 2).squareRoot()
                vj2 = a * jd * sinHalf / (1 - sinHalf)
            }
            entry[i] = min(vj2, segs[i - 1].v * segs[i - 1].v, segs[i].v * segs[i].v)
        }
        // Backward then forward passes: reachable within each chord's length.
        for i in stride(from: n - 1, through: 0, by: -1) {
            entry[i] = min(entry[i], entry[i + 1] + 2 * a * segs[i].len)
        }
        for i in 0..<n {
            entry[i + 1] = min(entry[i + 1], entry[i] + 2 * a * segs[i].len)
        }
        for i in 0..<n {
            let v0 = entry[i].squareRoot(), v1 = entry[i + 1].squareRoot(), vm = segs[i].v, L = segs[i].len
            let da = max(vm * vm - v0 * v0, 0) / (2 * a), dd = max(vm * vm - v1 * v1, 0) / (2 * a)
            let t: Double
            if da + dd <= L {
                t = (vm - v0) / a + (vm - v1) / a + (L - da - dd) / vm
            } else {
                let vp = ((2 * a * L + v0 * v0 + v1 * v1) / 2).squareRoot()
                t = max(vp - v0, 0) / a + max(vp - v1, 0) / a
            }
            times[segs[i].owner] += t
        }
        return times
    }

    /// Seconds for one move: length over feed (rapids at the axis limit) plus a stop-and-go
    /// allowance at sharp corners. Shared with `TimeEstimate`.
    static func duration(of m: Move, from start: SIMD3<Double>, lastDir: inout SIMD3<Double>?, accel: Double,
                         machine: MachineProfile) -> Double {
        let len = ToolpathGeometry.length(of: m, from: start)
        let v = m.role == .rapid ? machine.maxFeedAnyDirection : max(m.feed, 1)
        var t = len / v * 60
        let d = m.position - start
        let n = (d * d).sum().squareRoot()
        if n > 1e-9 {
            let dir = d / n
            if let ld = lastDir, (ld * dir).sum() < 0.7 { t += 2 * v / accel * 60 }
            lastDir = dir
        }
        return t
    }

    /// Index of the entry playing at time t (binary search).
    public func index(at t: Double) -> Int {
        guard !entries.isEmpty else { return 0 }
        var lo = 0, hi = entries.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].tEnd < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Tool tip position at time t.
    public func position(at t: Double) -> SIMD3<Double> {
        guard !entries.isEmpty else { return .zero }
        let e = entries[index(at: t)]
        let span = max(e.tEnd - e.tStart, 1e-9)
        let f = min(max((t - e.tStart) / span, 0), 1)
        let pts = [e.start] + ToolpathGeometry.points(of: e.move, from: e.start, segmentAngle: 0.1)
        let k = f * Double(pts.count - 1)
        let i = min(Int(k), pts.count - 2)
        let r = k - Double(i)
        return pts[i] + (pts[i + 1] - pts[i]) * r
    }
}
