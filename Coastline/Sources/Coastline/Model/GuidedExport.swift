import AppKit
import CoastlineCore
import Foundation
import simd
import Viewport

extension AppModel {
    /// Measuring checkpoints derived from the part and the programs: thickness after facing,
    /// the part's outline after the finishing contour, hole sizes after drilling or boring.
    func checkpoints() -> [GuidedJobBuilder.Checkpoint] {
        guard let part, let stock else { return [] }
        var out: [GuidedJobBuilder.Checkpoint] = []
        let (rlo, rhi) = setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        let size = setup.stockSize(stock)
        // An example with its own list (the first-cut coupon) measures that instead of the outline
        // and holes in general.
        let example = ExamplePart.of(part.url).flatMap { $0.checks.isEmpty ? nil : $0 }
        for p in programs {
            let kinds = Set(p.operations.filter { $0.reference == nil }.map(\.kind))  // not the reference bores
            if kinds.contains(.facing), let face = p.operations.first(where: { $0.kind == .facing }) {
                out.append(.init(afterProgram: p.index, what: "Stock thickness after facing", expected: size.z - face.faceDepth, tolerance: 0.05))
            }
            if kinds.contains(.contour), example == nil {
                out.append(.init(afterProgram: p.index, what: "Part height (X)", expected: rhi.x - rlo.x, tolerance: 0.05))
                out.append(.init(afterProgram: p.index, what: "Part width (Y)", expected: rhi.y - rlo.y, tolerance: 0.05))
            }
        }
        // Threads: a screw of the size goes in by hand, to the thread's depth.
        for p in programs {
            for op in p.operations where op.kind == .thread {
                guard let t = op.thread, let spec = t.thread else { continue }
                let hole = features?.holes.first { spec.fits(hole: $0.diameter) }
                let depth = t.depth ?? hole.map { $0.zTop - $0.zBottom } ?? 0
                guard depth > 0 else { continue }
                out.append(.init(afterProgram: p.index, what: "\(spec.name) thread: how deep a screw turns in by hand", expected: depth, tolerance: max(spec.pitch, 0.5)))
            }
        }
        // Every hole size once, after the last program that drills or bores (side A's holes).
        if example == nil, let last = programs.last(where: { p in p.side == 0 && p.operations.contains { ($0.kind == .bore || $0.kind == .drill) && $0.reference == nil } }) {
            var sizes: [Double] = []
            for h in features?.holes ?? [] where !sizes.contains(where: { abs($0 - h.diameter) < 0.01 }) { sizes.append(h.diameter) }
            for d in sizes.sorted() {
                out.append(.init(afterProgram: last.index, what: sizes.count == 1 ? "Hole diameter" : "Hole Ø\(Length.mm(d))", expected: d, tolerance: 0.03))
            }
        }
        // The example's own list (the first-cut coupon's every feature), after the last program.
        if let ex = example, let last = programs.last {
            for c in ex.checks { out.append(.init(afterProgram: last.index, what: c.what, expected: c.expected * setup.partScale, tolerance: c.tolerance)) }
        }
        return out
    }

    /// A picture of the setup from the spindle side, for the mounting step (side B: the part
    /// turned front-to-back, for the flip step).
    func setupSnapshot(side: Int = 0) -> Data? {
        let saved = renderer.camera
        let savedMachine = machineDisplay
        let savedAnimations = renderer.animationsEnabled
        renderer.animationsEnabled = false
        machineDisplay = .ghost
        setView(.toolIso)
        focusWork()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coastline-setup-\(UUID()).png")
        let partMesh = renderer.scene.mesh("part")
        let savedPart = partMesh?.transform
        if let part, let stock, let partMesh {
            let o = workOrigin(stockSize: setup.stockSize(stock))
            partMesh.transform = simd_float4x4(translation: SIMD3<Float>(o))
                * setupFor(side: side).partToWork(partMin: part.boundsMin, partMax: part.boundsMax).float
        }
        defer {
            renderer.camera = saved
            renderer.animationsEnabled = savedAnimations
            machineDisplay = savedMachine
            if let savedPart { partMesh?.transform = savedPart }
            try? FileManager.default.removeItem(at: url)
        }
        try? renderer.snapshot(width: 1200, height: 800, to: url)
        return try? Data(contentsOf: url)
    }

    func guidedInput(measuring: [MeasuringTool]) -> GuidedJobBuilder.Input? {
        guard let part, let stock, let material = stock.material, !programs.isEmpty else { return nil }
        var input = GuidedJobBuilder.Input(
            partName: part.fileName, material: material, stock: stock, stockSize: setup.stockSize(stock), setupName: "Setup 1",
            programs: guidedPrograms(),
            checkpoints: checkpoints(), measuring: measuring, setupImage: setupSnapshot(),
            squareStockFirst: stock.finish == .sawn)
        input.shoulders = setup.shoulders
        if setup.onBed, let st = bedJobStage, let p = bedJobPlacement {
            input.bed = .init(protrusion: st.protrusion, clampAngles: p.clampAngles)
        } else if let p = clampPlacement(stockSize: setup.stockSize(stock)) {
            input.clampCount = p.clamps.count
            if !setup.kitClampShift.isEmpty {
                // Each clamp's middle from the stock's left end (model −Y is left as you face the machine).
                let left = kitCentreY - setup.stockSize(stock).y / 2
                input.clampFromLeft = p.clamps.map { (($0.columns.3.y - left) * 2).rounded() / 2 }
            }
            input.parallels = p.parallels
            input.protrusion = max(min(effectiveProtrusion, setup.stockSize(stock).z - 1), 0.5)
        }
        if let tool = programs.map(\.tool).filter({ $0.kind == .flatEndMill }).max(by: { $0.diameter < $1.diameter }),
           var m = prepMillDown(tool: tool) {
            let saved = (previewMillDown, prepStage)
            switchingView = true
            defer { switchingView = false }
            previewMillDown = true
            prepStage = (flatPrepPlan?.stages.firstIndex(where: \.isEdge)) ?? 0
            layoutScene()
            m.image = setupSnapshot()
            (previewMillDown, prepStage) = saved
            layoutScene()
            input.millDown = m
        }
        if cutsThroughWithTabs, !placedTabs.isEmpty {
            input.tabs = tabs
            input.tabs?.count = placedTabs.count
        }
        if twoSided {
            input.tabs = holdWithTabs && !placedTabs.isEmpty ? tabs : nil
            input.tabs?.count = placedTabs.count  // as placed (a side without frame gets none)
            input.flipImage = setupSnapshot(side: 1)
        }
        input.probing = probing(stockSize: setup.stockSize(stock))
        // The job's tool-change spot (ToolChange.swift): room around the spindle in every clamping.
        let spot = toolChangeSpot(), tc = machine.toolChangePose
        input.toolChangeZ = spot.z > tc.z + 1e-9 ? spot.z : nil
        input.toolChangeY = abs(spot.y - tc.y) > 1e-9 ? spot.y : nil
        // The kit left of the middle: where its stock's right end goes, from the spindle there.
        if kitShiftY < -1e-9, !setup.onBed, let mm = machineModel {
            let spindleY = mm.spindleNose.y + (spot.y - mm.modelPose.y)
            input.stockRightOfToolChange = spindleY - (kitCentreY + setup.stockSize(stock).y / 2)
        }
        return input
    }

    /// The programs for the guided job, each with the face height its tool is touched off on
    /// (below Z0 once an earlier program on the same side faced the stock).
    func guidedPrograms() -> [GuidedJobBuilder.Program] {
        var faced: [Int: Double] = [:]
        return programs.map { p in
            var g = GuidedJobBuilder.Program(tool: p.tool, gcode: p.gcode, operationNames: p.operations.map(\.title),
                                             minutes: p.seconds / 60, side: p.side)
            g.touchZ = -(faced[p.side] ?? 0)
            g.reference = p.operations.lazy.compactMap(\.reference).first
            g.surfaceProbe = p.surfaceProbe
            for o in p.operations where o.kind == .facing { faced[p.side, default: 0] += o.faceDepth }
            return g
        }
    }

    /// How the job finds the stock: electrical probing in the clamp kit (Settings), which X
    /// edges are within reach (with the probing tool or the edge finder beside them, 3 mm out),
    /// and the reference bores.
    func probing(stockSize size: SIMD3<Double>) -> GuidedJobBuilder.Probing {
        var pr = GuidedJobBuilder.Probing()
        pr.electrical = !setup.onBed && AppSettings.shared.clampKitProbing == .electrical
        if let xr = kitWorkXRange {
            for side in 0..<2 {
                let tool = programs.first { $0.side == side }?.tool
                let r = pr.electrical ? (tool?.diameter ?? 6.35) / 2 : EdgeFinding.tool.diameter / 2
                pr.lowerXReachable[side] = -size.x / 2 - r - 3 >= xr.lowerBound
                pr.upperXReachable[side] = size.x / 2 + r + 3 <= xr.upperBound
                if !pr.lowerXReachable[side] && !pr.upperXReachable[side] {
                    // Neither (a bar as tall as the travel): the nearer one anyway.
                    pr.lowerXReachable[side] = true
                }
            }
        }
        let refs = Set(programs.flatMap { $0.operations.compactMap(\.reference) })
        pr.bores = refs.contains(.bores) && refs.contains(.windows) ? referencePlan : nil
        return pr
    }

    /// Writes the guided `.crproj` for CRWrite.
    func exportGuidedJob(to url: URL, measuring: [MeasuringTool]) throws {
        guard programs.allSatisfy(\.report.passed) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Fix the safety errors before exporting."])
        }
        guard let input = guidedInput(measuring: measuring) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Generate toolpaths first."])
        }
        if let m = input.millDown {
            for it in m.programs(material: input.material, sawn: input.squareStockFirst).items where !it.report.passed {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey:
                    "The prep program “\(it.title)” failed the safety check: " + it.report.issues.filter { $0.severity == .error }.map(\.message).joined(separator: " ")])
            }
        }
        try GuidedJobBuilder.write(input, to: url)
    }

    /// A native CRWrite build, if one is installed (or built next to Coastline).
    static var crwriteURL: URL? {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.github.xioaniumi.crwrite-native") { return u }
        for folder in ["crwrite-native"] {
            let built = repoRoot.deletingLastPathComponent().appendingPathComponent("\(folder)/dist/CRWrite.app")
            if FileManager.default.fileExists(atPath: built.path) { return built }
        }
        return nil
    }
}

extension AppModel {
    /// The part on its own, as designed (its CAD orientation, Z up), seen isometrically on a
    /// transparent background: the saved project's icon in Finder.
    func projectThumbnail(size: Int = 512) -> NSImage? {
        guard let part, let partMesh = renderer.scene.mesh("part") else { return nil }
        let scene = renderer.scene
        let meshes = scene.meshes.map { ($0, $0.isVisible) }
        let lines = scene.lines.map { ($0, $0.isVisible) }
        let saved = (renderer.camera, renderer.background, renderer.animationsEnabled, partMesh.transform, partMesh.group)
        defer {
            for (m, v) in meshes { m.isVisible = v }
            for (l, v) in lines { l.isVisible = v }
            renderer.camera = saved.0
            renderer.background = saved.1
            renderer.animationsEnabled = saved.2
            partMesh.transform = saved.3
            partMesh.group = saved.4
        }
        for (m, _) in meshes { m.isVisible = m.id == "part" }
        for (l, _) in lines { l.isVisible = false }
        renderer.animationsEnabled = false
        renderer.background = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        // The part on its own, centred, its CAD +Z up (display up is machine X): x → machine
        // Y, y → machine Z, z → machine X. Not riding the table's motion group.
        partMesh.group = nil
        let centre = SIMD3<Float>((part.boundsMin + part.boundsMax) / 2), half = SIMD3<Float>((part.boundsMax - part.boundsMin) / 2)
        let upright = simd_float4x4(columns: (SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(1, 0, 0, 0), SIMD4(0, 0, 0, 1)))
        partMesh.transform = upright * simd_float4x4(translation: -centre)
        let extent = SIMD3(half.z, half.x, half.y)
        renderer.camera.set(.iso)
        renderer.frame(worldMin: -extent, worldMax: extent)
        renderer.camera.zoom(by: 0.9)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coastline-thumb-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? renderer.snapshot(width: size, height: size, to: url)) != nil else { return nil }
        return NSImage(contentsOf: url)
    }
}
