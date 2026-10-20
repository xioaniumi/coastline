import AppKit
import CoastlineCore
import Foundation
import simd
import Viewport

/// A view of the job: a side (−1 = prep on the squaring stop, 0 = A, 1 = B) and, for the prep,
/// which clamping.
struct ViewKey: Equatable {
    var side: Int
    var stage: Int
}

extension AppModel {
    var viewKey: ViewKey { ViewKey(side: viewSide, stage: prepStage) }

    /// Shows another side or prep stage in one step (one animation for both changes).
    func show(side: Int, stage: Int) {
        let old = viewKey
        guard old != ViewKey(side: side, stage: stage) else { return }
        switchingView = true
        viewSide = side
        prepStage = stage
        switchingView = false
        transition(from: old)
    }

    /// Re-lays the scene for the new view the way it happens at the machine: the clamps come
    /// off first (the fixtures fade out), the stock lifts out (turned the way it goes next: end
    /// for end, a quarter turn onto its long side, up into the clamp kit, or front-to-back for
    /// side B), the next clamping's fixtures come in, then the stock goes in. Into the clamp kit
    /// it can't come from the front (the spindle is there) or from above (the clamps' top arms):
    /// the kit slides along the T-slots clear of the spindle, the stock slides in from the side
    /// through the clamps' throats, and the kit slides back.
    func transition(from old: ViewKey) {
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            if self.result(forSide: self.viewSide) == nil { self.layoutScene() } else { self.showSide() }
            self.revealYourStock()
        }
        let animate = (ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] == nil || ProcessInfo.processInfo.environment["COASTLINE_ANIMATE"] != nil)
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animate, let to = stockBox(for: viewKey) else {
            // No animation this time: one still running must not land on top of this view.
            flipTask?.cancel()
            renderer.scene.remove(id: "stock.anim")
            stockAnimating = false
            finish()
            return
        }
        let (axis, angle) = old.side >= 0 && viewSide >= 0
            ? (SIMD3<Float>(1, 0, 0), Float.pi)  // side A ↔ B: front-to-back about the vertical
            : turn(from: old, to: viewKey)
        // The bar as bought arrives from above; otherwise it leaves from where it was.
        let from = viewKey == ViewKey(side: -1, stage: -1) && old.side < 0 ? nil : stockBox(for: old)
        animateClamping(from: from, to: to, axis: axis, angle: angle, then: finish)
    }

    /// One frame-paced animation step (t 0…1, eased by the caller); false when cancelled.
    private func run(_ duration: Double, _ step: (Float) -> Void) async -> Bool {
        let start = Date()
        while !Task.isCancelled {
            let t = Float(min(Date().timeIntervalSince(start) / duration, 1))
            step(t)
            if t >= 1 { return true }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return false
    }

    private static func ease(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    /// The clamping sequence (see `transition`), with a stand-in box for the stock; the real
    /// stock, part and paths are hidden until it's in.
    func animateClamping(from a: (centre: SIMD3<Float>, size: SIMD3<Float>)?, to b: (centre: SIMD3<Float>, size: SIMD3<Float>),
                         axis: SIMD3<Float>, angle: Float, then done: @escaping @MainActor () -> Void) {
        flipTask?.cancel()
        stockAnimating = true
        let scene = renderer.scene
        scene.remove(id: "stock.anim")
        let colour = stock?.material?.linearSwatch ?? SIMD3(0.6, 0.6, 0.62)
        guard let proxy = SceneMesh.box(device: renderer.device, id: "stock.anim", min: SIMD3(repeating: -0.5), max: SIMD3(repeating: 0.5),
                                        color: SIMD4(colour, 1)) else { stockAnimating = false; done(); return }
        proxy.material = scene.mesh("simstock")?.material ?? scene.mesh("stock")?.material ?? proxy.material
        let hide = ["part", "stock", "stock.edges", "simstock", "simstock.back", "simstock.walls", "simstock.loose", "toolpath", "tabs",
                    "cutface", "cutface.edges", "undercuts", "clearance", "prep.cut", "prep.cut.edges", "prep.next"]
        func hideWork() {
            for id in hide { scene.mesh(id)?.isVisible = false; scene.lineSet(id)?.isVisible = false }
            for m in scene.meshes where m.id.hasPrefix("copy.") { m.isVisible = false }
        }
        let q = simd_quatf(angle: angle, axis: simd_normalize(axis))
        let endLocal = simd_abs(q.inverse.act(b.size))
        func place(_ centre: SIMD3<Float>, _ turn: Float, _ size: SIMD3<Float>) {
            let rot = simd_slerp(simd_quatf(angle: 0, axis: SIMD3(1, 0, 0)), q, turn)
            proxy.transform = simd_float4x4(translation: centre) * simd_float4x4(rot) * simd_float4x4(diagonal: SIMD4(size.x, size.y, size.z, 1))
        }
        // Into the clamp kit: from the side (see `transition`); onto the bed: from above.
        let intoKit = viewSide >= 0 && !setup.onBed
        let lift = SIMD3<Float>(45, 0, 0)  // X is up
        let slide = SIMD3<Float>(0, 55, 0)  // the kit along the T-slots, clear of the spindle
        let sideIn = SIMD3<Float>(0, b.size.y + 20, 0)  // the stock's start, wholly beside the clamps
        let finish: @MainActor () -> Void = { [weak self] in
            scene.remove(id: "stock.anim")
            self?.stockAnimating = false
            done()
        }
        flipTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 1. The clamps come off: the fixtures fade out, the stock still in them.
            hideWork()
            if let a { place(a.centre, 0, a.size); scene.setMesh(proxy) }
            let old = scene.meshes.filter { $0.id.hasPrefix("fixture.") && $0.isVisible }.map { ($0, $0.color.w) }
            guard await self.run(0.35, { t in for (m, w) in old { m.color.w = w * (1 - Self.ease(t)) } }) else { return }
            for (m, _) in old { m.isVisible = false }
            // 2. The stock lifts out.
            if let a {
                guard await self.run(0.45, { t in place(a.centre + lift * Self.ease(t), 0, a.size) }) else { return }
            }
            // 3. The next clamping's fixtures come in (the kit slid clear of the spindle).
            self.layoutScene()
            hideWork()
            let new = scene.meshes.filter { $0.id.hasPrefix("fixture.") && $0.isVisible }.map { ($0, $0.color.w, $0.transform) }
            let kitSlide = intoKit ? slide : .zero
            for (m, _, t) in new { m.color.w = 0; m.transform = simd_float4x4(translation: kitSlide) * t }
            // Meanwhile the stock, still in the air, goes over to where it comes in, turning.
            let start = a.map { $0.centre + lift } ?? b.centre + lift + SIMD3(30, 0, 0)
            let startSize = a?.size ?? b.size
            let startTurn: Float = a == nil ? 1 : 0
            let park = intoKit ? b.centre + kitSlide + sideIn + lift : b.centre + lift
            if a == nil { place(start, 1, endLocal); scene.setMesh(proxy) }
            guard await self.run(0.75, { t in
                let e = Self.ease(t)
                for (m, w, _) in new { m.color.w = w * min(t * 1.6, 1) }
                place(simd_mix(start, park, SIMD3(repeating: e)), startTurn + (1 - startTurn) * e,
                      simd_mix(startSize, endLocal, SIMD3(repeating: e)))
            }) else { return }
            for (m, w, _) in new { m.color.w = w }
            // 4. The stock goes in: down beside the kit and in through the throats, or down onto the bed.
            let landed = intoKit ? b.centre + kitSlide : b.centre
            if intoKit {
                guard await self.run(0.35, { t in place(simd_mix(park, park - lift, SIMD3(repeating: Self.ease(t))), 1, endLocal) }) else { return }
                guard await self.run(0.6, { t in place(simd_mix(park - lift, landed, SIMD3(repeating: Self.ease(t))), 1, endLocal) }) else { return }
                // 5. The kit, with the stock in it, slides back under the spindle.
                guard await self.run(0.45, { t in
                    let back = kitSlide * (1 - Self.ease(t))
                    place(b.centre + back, 1, endLocal)
                    for (m, _, base) in new { m.transform = simd_float4x4(translation: back) * base }
                }) else { return }
            } else {
                guard await self.run(0.5, { t in place(simd_mix(park, landed, SIMD3(repeating: Self.ease(t))), 1, endLocal) }) else { return }
            }
            for (m, _, base) in new { m.transform = base }
            finish()
        }
    }

    /// The stock's box in the model for a view (centre and size).
    func stockBox(for key: ViewKey) -> (centre: SIMD3<Float>, size: SIMD3<Float>)? {
        guard let stock else { return nil }
        if key.side == -1, hasPrep, let stage = prepStage(at: key.stage) {
            let p = prepPlacement(stage)
            let s = stage.stock
            let bottom = key.stage < 0 ? prepTable.topX : p.stockBottomX
            return (SIMD3<Float>(SIMD3(bottom + s.x / 2, prepCentreY(stage), p.stockFaceZ - s.z / 2)), SIMD3<Float>(s))
        }
        let s = setup.stockSize(stock)
        if setup.onBed, let p = bedJobPlacement {
            return (SIMD3<Float>(SIMD3(p.stockBottomX + s.x / 2, bedJobCentreY, p.stockFaceZ - s.z / 2)), SIMD3<Float>(s))
        }
        guard let p = clampPlacement(stockSize: s) else { return nil }
        return (SIMD3<Float>(SIMD3(p.stockBottomX + s.x / 2, kitCentreY, p.stockFaceZ - s.z / 2)), SIMD3<Float>(s))
    }

    /// How the bar turns between two clampings (model axes: X up, Y along the table, Z toward
    /// the spindle). Steps the other way turn back.
    func turn(from a: ViewKey, to b: ViewKey) -> (axis: SIMD3<Float>, angle: Float) {
        let none = (SIMD3<Float>(1, 0, 0), Float(0))
        func kind(_ k: ViewKey) -> FlatPrep.Kind? { k.side == -1 ? prepStage(at: k.stage)?.kind : nil }
        func forward(_ a: ViewKey, _ b: ViewKey) -> (SIMD3<Float>, Float)? {
            switch (kind(a), kind(b)) {
            case (.faceEnd(0), .faceEnd(1)): return (SIMD3(1, 0, 0), .pi)            // end for end
            case (.faceEnd, .edge): return (SIMD3(1, 0, 0), .pi / 2)                 // length along the table
            case (.edge, .edge): return none                                          // slid out
            case (.edge, nil), (.faceEnd, nil): return (SIMD3(0, 1, 0), .pi / 2)     // stood up in the clamp kit
            default: return nil
            }
        }
        if let f = forward(a, b) { return f }
        if let f = forward(b, a) { return (f.0, -f.1) }
        return none
    }
}
