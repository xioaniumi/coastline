import CoastlineCore
import Foundation

let viewerTests: [TestCase] = [
    TestCase(name: "heightmapFlatAndBallProfiles") {
        var h = Heightmap(stockMin: SIMD3(-10, -10, -5), stockMax: SIMD3(10, 10, 0), maxCells: 40_000)
        h.cut(from: SIMD3(-8, 0, -1), to: SIMD3(8, 0, -1), radius: 2, cornerRadius: 0)
        func at(_ x: Double, _ y: Double) -> Float {
            h.height(col: Int(((x - h.origin.x) / h.cell).rounded()), row: Int(((y - h.origin.y) / h.cell).rounded()))
        }
        try expect(abs(at(0, 0) + 1) < 1e-6, "flat bottom")
        try expect(abs(at(0, 1.9) + 1) < 1e-6, "flat to the edge")
        try expect(at(0, 2.3) == 0, "untouched outside the tool")
        var b = Heightmap(stockMin: SIMD3(-10, -10, -5), stockMax: SIMD3(10, 10, 0), maxCells: 40_000)
        b.cut(from: SIMD3(0, 0, -1), to: SIMD3(0, 0, -1), radius: 2, cornerRadius: 2)
        let mid = b.height(col: Int(((0 - b.origin.x) / b.cell).rounded()), row: Int(((0 - b.origin.y) / b.cell).rounded()))
        let side = b.height(col: Int(((1.5 - b.origin.x) / b.cell).rounded()), row: Int(((0 - b.origin.y) / b.cell).rounded()))
        try expect(abs(mid + 1) < 0.02, "ball tip")
        try expect(side > mid + 0.4, "ball rises toward the edge (\(side))")
        try expect(b.removedVolume > 0)
    },
    TestCase(name: "timelinePositionsAndLines") {
        let moves = [Move(.rapid, x: 0, y: 0, z: 3), Move(.plunge, x: 0, y: 0, z: -1, feed: 60),
                     Move(.cut, x: 10, y: 0, z: -1, feed: 600)]
        let path = OperationToolpath(operationID: UUID(), moves: moves)
        let tool = Tool(name: "t", kind: .flatEndMill, diameter: 3, shankDiameter: 3, flutes: 2, fluteLength: 9, stickout: 20, overallLength: 38)
        let post = CR1Post.programWithLineMap(header: .init(programName: "t", setupName: "s", tool: tool, operationNames: [], stockDescription: ""),
                                              rpm: 8000, paths: [path])
        try expectEqual(post.lines[0].count, 3)
        let gl = post.text.split(separator: "\n", omittingEmptySubsequences: false)
        try expect(gl[post.lines[0][2]! - 1].contains("X10"), "line map points at the X10 move")
        let tl = ToolpathTimeline(paths: [path], programOf: [0], lines: post.lines)
        // Plunge: 4 mm at 60 mm/min = 4 s; cut: 10 mm at 600 mm/min = 1 s (+ a corner allowance).
        try expect(tl.duration > 5 && tl.duration < 6, "\(tl.duration)")
        let p = tl.position(at: tl.entries[2].tStart + (tl.entries[2].tEnd - tl.entries[2].tStart) / 2)
        try expect(abs(p.x - 5) < 0.6 && abs(p.z + 1) < 1e-9, "midway along the cut: \(p)")
        try expectEqual(tl.index(at: 0.0), 0)
    },
    TestCase(name: "heightmapFastCutMatchesTheBruteForceOne") {
        // The per-row sweep and the skip of cells already low enough change nothing: the same
        // heights as testing every cell of the box, over random flat, ball and bull moves.
        var fast = Heightmap(stockMin: SIMD3(-20, -15, -10), stockMax: SIMD3(20, 15, 0), maxCells: 40_000)
        var slow = fast.heights
        var rng = SystemRandomNumberGenerator()
        func reference(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ r: Double, _ rc0: Double) {
            let d = SIMD2(b.x - a.x, b.y - a.y), len2 = (d * d).sum(), rc = min(max(rc0, 0), r)
            for row in 0..<fast.rows {
                let y = fast.origin.y + Double(row) * fast.cell
                for col in 0..<fast.cols {
                    let x = fast.origin.x + Double(col) * fast.cell
                    var t = 0.0
                    if len2 > 1e-12 { t = min(max(((x - a.x) * d.x + (y - a.y) * d.y) / len2, 0), 1) }
                    let dist = ((x - a.x - d.x * t) * (x - a.x - d.x * t) + (y - a.y - d.y * t) * (y - a.y - d.y * t)).squareRoot()
                    guard dist <= r else { continue }
                    var z = a.z + (b.z - a.z) * t
                    if dist > r - rc { let u = dist - (r - rc); z += rc - max(rc * rc - u * u, 0).squareRoot() }
                    let i = row * fast.cols + col
                    slow[i] = min(slow[i], Float(max(z, fast.bottom)))
                }
            }
        }
        for _ in 0..<300 {
            let a = SIMD3(Double.random(in: -25...25, using: &rng), Double.random(in: -20...20, using: &rng), Double.random(in: -11...1, using: &rng))
            let b = SIMD3(Double.random(in: -25...25, using: &rng), Double.random(in: -20...20, using: &rng), Double.random(in: -11...1, using: &rng))
            let r = Double.random(in: 0.2...4, using: &rng), rc = [0, r, r / 3].randomElement(using: &rng)!
            fast.cut(from: a, to: b, radius: r, cornerRadius: rc)
            reference(a, b, r, rc)
        }
        try expect(fast.heights == slow, "fast cut differs")
    },
]
