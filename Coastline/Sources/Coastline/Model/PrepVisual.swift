import CoastlineCore
import Foundation
import Metal
import simd
import Viewport

/// The prep on the bed, drawn so each step says what it does: the bar as it really is at that
/// step (stepped once shoulders are cut), what the step mills off in orange with its number,
/// and the later steps' cuts faint with theirs. As bought (and in Holding) every cut shows,
/// numbered in order.
extension AppModel {
    static let prepCutColor = SIMD4<Float>(1.0, 0.55, 0.1, 0.6)

    func layoutPrepBar(plan: FlatPrep.Plan, stage k: Int, origin: SIMD3<Double>, color c: SIMD3<Float>) {
        let scene = renderer.scene
        let ls = setup.shoulders?.length
        let material = plan.frameBoxes(plan.barMaterial(before: k, shoulderLength: ls), stage: k)
        if let m = Self.boxesMesh(device: renderer.device, id: "stock", boxes: material, origin: origin, color: SIMD4(c, 0.22)) {
            scene.setMesh(m)
        }
        let edges = material.flatMap { LineSegment.box(min: SIMD3<Float>($0.min + origin), max: SIMD3<Float>($0.max + origin), color: SIMD4(200, 205, 215, 255)) }
        if let l = SceneLines(device: renderer.device, id: "stock.edges", segments: edges) { scene.setLines(l) }

        var labels: [SceneLabel] = []
        var now: [FlatPrep.Plan.Box] = [], later: [FlatPrep.Plan.Box] = []
        for j in plan.stages.indices where j >= k && (k >= 0 || prepReveal.map { j < $0 } ?? true) {
            let boxes = plan.frameBoxes(plan.barCut(j, shoulderLength: ls), stage: k)
            let current = k < 0 || j == k
            if current { now += boxes } else { later += boxes }
            for (i, b) in boxes.enumerated() {
                let top = SIMD3(b.max.x + 1.5, b.centre.y, b.centre.z) + origin
                labels.append(SceneLabel(id: "prep.\(j).\(i)", text: "\(j + 1)", point: SIMD3<Float>(top), emphasized: current))
            }
        }
        // A hair bigger than the bar's faces, so the orange sits on top of them.
        func grown(_ b: [FlatPrep.Plan.Box]) -> [FlatPrep.Plan.Box] {
            b.map { FlatPrep.Plan.Box(min: $0.min - 0.05, max: $0.max + 0.05) }
        }
        if let m = Self.boxesMesh(device: renderer.device, id: "prep.cut", boxes: grown(now), origin: origin, color: Self.prepCutColor) {
            m.depthBias = 1
            scene.setMesh(m)
        }
        if let l = SceneLines(device: renderer.device, id: "prep.cut.edges",
                              segments: grown(now).flatMap { LineSegment.box(min: SIMD3<Float>($0.min + origin), max: SIMD3<Float>($0.max + origin), color: SIMD4(255, 140, 26, 255)) }) {
            scene.setLines(l)
        }
        if let m = Self.boxesMesh(device: renderer.device, id: "prep.next", boxes: grown(later), origin: origin, color: SIMD4(1.0, 0.55, 0.1, 0.16)) {
            m.depthBias = 1
            scene.setMesh(m)
        }
        if sceneLabels != labels { sceneLabels = labels }
    }

    /// "Your stock": the bar as bought, then each prep cut lights up in order with its number
    /// (a few seconds, so the step reads as what's coming instead of flickering past).
    func revealYourStock() {
        prepRevealTask?.cancel()
        guard viewKey == ViewKey(side: -1, stage: -1), let plan = flatPrepPlan, !plan.stages.isEmpty else { prepReveal = nil; return }
        prepReveal = 0
        relayoutPrepBar()
        prepRevealTask = Task { @MainActor [weak self] in
            for n in 1...plan.stages.count {
                try? await Task.sleep(for: .milliseconds(n == 1 ? 450 : 380))
                guard let self, !Task.isCancelled, self.viewKey == ViewKey(side: -1, stage: -1) else { self?.prepReveal = nil; return }
                self.prepReveal = n
                self.relayoutPrepBar()
            }
            self?.prepReveal = nil
        }
    }

    /// Just the prep bar's overlays again (the rest of the scene stays).
    func relayoutPrepBar() {
        guard showingMillDown, let plan = flatPrepPlan, !plan.stages.isEmpty, let size = displayStockSize else { return }
        let c = stock?.material?.linearSwatch ?? SIMD3(0.5, 0.5, 0.5)
        clearPrepBar()
        layoutPrepBar(plan: plan, stage: min(prepStage, plan.stages.count - 1), origin: workToModel(stockSize: size), color: c)
    }

    func clearPrepBar() {
        for id in ["prep.cut", "prep.cut.edges", "prep.next"] { renderer.scene.remove(id: id) }
        if !sceneLabels.isEmpty { sceneLabels = [] }
    }

    /// One mesh of several boxes (work-frame boxes placed at `origin`), flat-shaded.
    static func boxesMesh(device: MTLDevice, id: String, boxes: [FlatPrep.Plan.Box], origin: SIMD3<Double>, color: SIMD4<Float>) -> SceneMesh? {
        guard !boxes.isEmpty else { return nil }
        var p: [Float] = [], n: [Float] = [], ix: [UInt32] = []
        for b in boxes {
            let lo = SIMD3<Float>(b.min + origin), hi = SIMD3<Float>(b.max + origin)
            // Six faces: (normal, four corners counter-clockwise seen from outside).
            let faces: [(SIMD3<Float>, [SIMD3<Float>])] = [
                (SIMD3(1, 0, 0), [SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(hi.x, lo.y, hi.z)]),
                (SIMD3(-1, 0, 0), [SIMD3(lo.x, lo.y, lo.z), SIMD3(lo.x, lo.y, hi.z), SIMD3(lo.x, hi.y, hi.z), SIMD3(lo.x, hi.y, lo.z)]),
                (SIMD3(0, 1, 0), [SIMD3(lo.x, hi.y, lo.z), SIMD3(lo.x, hi.y, hi.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(hi.x, hi.y, lo.z)]),
                (SIMD3(0, -1, 0), [SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(lo.x, lo.y, hi.z)]),
                (SIMD3(0, 0, 1), [SIMD3(lo.x, lo.y, hi.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(lo.x, hi.y, hi.z)]),
                (SIMD3(0, 0, -1), [SIMD3(lo.x, lo.y, lo.z), SIMD3(lo.x, hi.y, lo.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(hi.x, lo.y, lo.z)]),
            ]
            for (normal, q) in faces {
                let base = UInt32(p.count / 3)
                for v in q { p += [v.x, v.y, v.z]; n += [normal.x, normal.y, normal.z] }
                ix += [base, base + 1, base + 2, base, base + 2, base + 3]
            }
        }
        return SceneMesh(device: device, id: id, positions: p, normals: n, indices: ix, color: color)
    }
}
