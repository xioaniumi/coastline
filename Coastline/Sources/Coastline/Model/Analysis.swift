import CoastlineCore
import Foundation
import simd
import Viewport

extension AppModel {
    /// Re-runs the part analysis for the current orientation (debounced; ~1 s in the engine).
    func scheduleAnalysis() {
        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await self.runAnalysis()
        }
    }

    func runAnalysis() async {
        guard let part, part.exact else { analysis = nil; return }
        do {
            let engine = try await liveEngine()
            let t = workTransform(part)
            let a = try await engine.analyse(partID: part.partID, transform: t)
            analysisTransform = t
            analysis = a
            showUndercuts()
            chooseSides(a)
        } catch {
            errorMessage = "Analysis failed: \(error)"
        }
    }

    /// Parts with shape on the back (faces turned away from the spindle) are machined from
    /// both sides; a flat back can be done from one side, so that stays the default there. A
    /// choice the user made themselves is kept.
    func chooseSides(_ a: PartAnalysis) {
        guard !twoSidedChosen else { return }
        let want = Self.backHasShape(a)
        if twoSided != want {
            twoSided = want
            status = want ? "The back has shape (shown red): planned from both sides." : "The back is flat: planned from one side."
        }
    }

    static func backHasShape(_ a: PartAnalysis) -> Bool { a.undercutArea > 0.5 }

    /// Faces that point away from the spindle, drawn red over the part.
    func showUndercuts() {
        renderer.scene.remove(id: "undercuts")
        undercutOverlayShown = false
        // Drawn on the part in side A's clamping only (the prep shows the bare stock; side B has
        // the part turned over).
        guard showUndercutOverlay, let a = analysis, !a.undercutTriangles.isEmpty, let stock, let part, !showingMillDown, viewSide != 1 else { return }
        // The triangles are in the work frame of the analysis. Moved since: follow the part at
        // once. Turned or scaled: those are different faces, so nothing until the new analysis.
        let now = workTransform(part)
        guard let partMesh = renderer.scene.mesh("part"), partMesh.isVisible else { return }
        if let then = analysisTransform {
            let same = (0..<3).allSatisfy { c in simd_distance(now[c], then[c]) < 1e-9 }
            guard same else { return }
        }
        _ = stock
        var t = a.undercutTriangles
        var normals = [Float](repeating: 0, count: t.count)
        var k = 0
        while k + 8 < t.count {
            let p0 = SIMD3(t[k], t[k + 1], t[k + 2]), p1 = SIMD3(t[k + 3], t[k + 4], t[k + 5]), p2 = SIMD3(t[k + 6], t[k + 7], t[k + 8])
            let n = simd_normalize(simd_cross(p1 - p0, p2 - p0))
            for v in 0..<3 {
                normals[k + 3 * v] = n.x; normals[k + 3 * v + 1] = n.y; normals[k + 3 * v + 2] = n.z
                // Lift the overlay off the surface along its normal so it never z-fights the part.
                t[k + 3 * v] += n.x * 0.03; t[k + 3 * v + 1] += n.y * 0.03; t[k + 3 * v + 2] += n.z * 0.03
            }
            k += 9
        }
        // On the part wherever it's drawn: the part's model transform, back through the work
        // transform the triangles were made with.
        let placed = partMesh.transform * (analysisTransform ?? now).inverse.float
        if let m = SceneMesh(device: renderer.device, id: "undercuts", positions: t, normals: normals,
                             indices: (0..<UInt32(t.count / 3)).map { $0 }, color: SIMD4(0.9, 0.12, 0.08, 0.75),
                             transform: placed) {
            renderer.scene.setMesh(m)
            undercutOverlayShown = true
        }
    }

    // MARK: Watching the CAD file

    /// Watches the imported file; a re-export from Rhino shows a Reload banner.
    func watchPartFile(_ url: URL) {
        partWatcher?.cancel()
        partChangedOnDisk = false
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.partChangedOnDisk = true }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        partWatcher = source
    }

    /// Re-imports the changed file, keeping the orientation, stock and operations.
    func reloadPart() async {
        guard let url = part?.url else { return }
        let keepSetup = setup, keepOps = operations, keepStock = stockID, keepSides = (twoSided, twoSidedChosen)
        await importPart(url)
        (twoSided, twoSidedChosen) = keepSides
        setup = keepSetup
        stockID = keepStock
        operations = keepOps
        partChangedOnDisk = false
        status = "Reloaded \(url.lastPathComponent): orientation, stock and operations kept. Generate again."
    }
}
