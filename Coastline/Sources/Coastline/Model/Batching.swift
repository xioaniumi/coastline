import CoastlineCore
import Foundation
import simd
import Viewport

/// Batching: several copies of the part side by side along the bar. Each copy has
/// its own roughing band and frame; between neighbours a web of frame stays (GripZones.grip).
/// The toolpaths are made once and repeated for every copy; facing covers the bar once.
extension AppModel {
    /// The copies' Y offsets (work frame) for a side's setup.
    func copyOffsets(for s: Setup) -> [Double] {
        guard let part, s.copies > 1 else { return [0] }
        let (lo, hi) = s.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        return Setup.copyOffsets(count: s.copies, partY: hi.y - lo.y, toolDiameter: roughingDiameter)
    }

    /// The largest flat end mill among the operations (it sets each copy's band), else 1/4".
    var roughingDiameter: Double { 6.35 }

    /// How many copies fit in this stock along Y.
    var maxCopies: Int {
        guard let part, let stock else { return 1 }
        let (lo, hi) = setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        return Setup.maxCopies(stockY: setup.stockSize(stock).y, partY: hi.y - lo.y, toolDiameter: roughingDiameter)
    }

    /// One path repeated at each offset (lifted to a safe height between copies).
    func batched(_ path: OperationToolpath, offsets: [Double]) -> OperationToolpath {
        var out = path
        out.moves = []
        let safe = 3.0
        for (k, dy) in offsets.enumerated() {
            let shifted = path.moves.map { m -> Move in
                var m = m
                m.y += dy
                return m
            }
            if k > 0, let last = out.moves.last, let first = shifted.first {
                out.moves.append(Move(.rapid, x: last.x, y: last.y, z: max(last.z, safe)))
                out.moves.append(Move(.rapid, x: first.x, y: first.y, z: max(last.z, safe)))
            }
            out.moves += shifted
        }
        return out
    }

    /// The part's copies in the 3D view (the original is the "part" mesh at the first offset).
    func layoutCopies(partTransform: simd_double4x4, visible: Bool) {
        let scene = renderer.scene
        let offsets = copyOffsets(for: setup)
        for m in scene.meshes where m.id.hasPrefix("part.copy.") { m.isVisible = false }
        guard offsets.count > 1, visible, let data = partMeshData else { return }
        // The main mesh takes the first offset; the rest are copies.
        if let main = scene.mesh("part") {
            main.transform = (simd_double4x4(translation: SIMD3(0, offsets[0], 0)) * partTransform).float
        }
        for (k, dy) in offsets.enumerated().dropFirst() {
            let id = "part.copy.\(k)"
            if scene.mesh(id) == nil, let m = SceneMesh(device: renderer.device, id: id, positions: data.positions, normals: data.normals,
                                                        indices: data.indices, color: SIMD4(0.55, 0.57, 0.6, 1)) {
                scene.setMesh(m)
            }
            guard let m = scene.mesh(id) else { continue }
            m.transform = (simd_double4x4(translation: SIMD3(0, dy, 0)) * partTransform).float
            m.material = scene.mesh("part")?.material ?? m.material
            m.color = scene.mesh("part")?.color ?? m.color
            m.isVisible = true
        }
    }

    /// The copies don't fit the stock.
    var batchIssue: Issue? {
        guard setup.copies > 1, setup.copies > maxCopies else { return nil }
        return Issue(.error, "\(setup.copies) copies don't fit along this stock: at most \(maxCopies).")
    }
}

extension simd_double4x4 {
    init(translation t: SIMD3<Double>) {
        self.init(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(t, 1)))
    }
}

extension AppModel {
    /// The engraving's outline on the part's face (purple), while there's an engraving op.
    func layoutEngravingPreview() {
        let scene = renderer.scene
        scene.remove(id: "engrave.preview")
        guard !showingMillDown, !showingStockOnly, viewSide >= 0, let size = displayStockSize else { return }
        let texts = operations.filter { $0.kind == .engrave && $0.enabled }.compactMap(\.engraving).filter { $0.side == viewSide || !twoSided }
        guard !texts.isEmpty else { return }
        let o = workOrigin(stockSize: size)
        let z = -setupFor(side: viewSide).topAllowance + 0.05
        let purple = SIMD4<UInt8>(175, 80, 255, 255)
        var segs: [LineSegment] = []
        for e in texts {
            for dy in copyOffsets(for: setup) {
                for loop in e.polylines(tolerance: 0.05) {
                    for (a, b) in zip(loop, loop.dropFirst()) {
                        segs.append(LineSegment(SIMD3<Float>(SIMD3(a.x, a.y + dy, z) + o), SIMD3<Float>(SIMD3(b.x, b.y + dy, z) + o), color: purple))
                    }
                }
            }
        }
        if let l = SceneLines(device: renderer.device, id: "engrave.preview", segments: segs) { scene.setLines(l) }
    }
}
