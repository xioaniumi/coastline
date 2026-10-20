import AppKit
import CoastlineCore
import Foundation
import simd
import Viewport

/// How toolpaths are coloured in the viewport.
enum PathColorMode: String, CaseIterable, Identifiable {
    case moveType, feed, depth, operation, tool
    var id: Self { self }
    var title: String {
        switch self {
        case .moveType: "Move type"
        case .feed: "Feed rate"
        case .depth: "Depth"
        case .operation: "Operation"
        case .tool: "Tool"
        }
    }
    /// What the colours mean, in one line.
    var explanation: String {
        switch self {
        case .moveType: "Blue cutting, yellow leading in and out, pink going down into the material, red dashed rapids through the air"
        case .feed: "Blue slow to red fast: where the feed drops (corners, ramps)"
        case .depth: "Light near the face to dark at the deepest"
        case .operation: "One colour per operation, as on the timeline bar"
        case .tool: "One colour per tool"
        }
    }
}

/// What the inspector shows for a clicked toolpath segment.
struct InspectedMove: Equatable {
    var entry: Int
    var operation: String
    var role: String
    var feed: Double
    var position: SIMD3<Double>
    var time: Double
    var program: Int
    var line: Int?
    var context: [(Int, String)]

    static func == (a: InspectedMove, b: InspectedMove) -> Bool { a.entry == b.entry }
}

extension AppModel {
    static let palette: [SIMD4<UInt8>] = [SIMD4(46, 160, 255, 255), SIMD4(52, 199, 89, 255), SIMD4(255, 159, 10, 255),
                                          SIMD4(191, 90, 242, 255), SIMD4(255, 55, 95, 255), SIMD4(100, 210, 255, 255)]

    private func colour(for e: ToolpathTimeline.Entry, maxFeed: Double, depth: ClosedRange<Double>) -> SIMD4<UInt8> {
        if e.move.role == .rapid { return PathColor.rapid }
        switch colorMode {
        case .moveType: return Self.colour(e.move.role)
        case .operation: return Self.palette[e.operation % Self.palette.count]
        case .tool: return Self.palette[e.program % Self.palette.count]
        case .feed:
            let t = min(max(e.move.feed / max(maxFeed, 1), 0), 1)
            return SIMD4(UInt8(40 + 215 * t), UInt8(170 - 120 * t), UInt8(255 - 215 * t), 255)
        case .depth:
            let span = max(depth.upperBound - depth.lowerBound, 1e-6)
            let t = min(max((depth.upperBound - e.move.z) / span, 0), 1)
            return SIMD4(UInt8(170 - 140 * t), UInt8(230 - 120 * t), 255, 255)
        }
    }

    /// Draws the whole timeline; playback hides segments past the playhead.
    func showToolpaths() {
        renderer.scene.remove(id: "toolpath")
        entrySegmentEnd = []
        guard let stock, !timeline.entries.isEmpty else { toolpathSegments = 0; return }
        let origin = SIMD3<Float>(workOrigin(stockSize: displayStockSize ?? setup.stockSize(stock)))
        let maxFeed = timeline.entries.map(\.move.feed).max() ?? 1
        let zs = timeline.entries.filter { $0.move.role != .rapid }.map(\.move.z)
        let depth = (zs.min() ?? -1) ... (zs.max() ?? 0)
        var segs: [LineSegment] = []
        entrySegmentEnd.reserveCapacity(timeline.entries.count)
        for e in timeline.entries {
            let c = colour(for: e, maxFeed: maxFeed, depth: depth)
            var a = e.start
            for q in ToolpathGeometry.points(of: e.move, from: e.start, segmentAngle: 0.15) {
                segs.append(LineSegment(SIMD3<Float>(a) + origin, SIMD3<Float>(q) + origin, color: c))
                a = q
            }
            entrySegmentEnd.append(segs.count)
        }
        if let set = SceneLines(device: renderer.device, id: "toolpath", segments: segs) {
            set.xray = realistic ? 0.35 : 0
            set.isVisible = pathsVisible
            renderer.scene.setLines(set)
            toolpathSegments = set.count
        }
        updatePlayback()
    }

    // MARK: Playback

    /// Play plays one step: the program at the playhead to its end (at its end, the next
    /// one). A new tool's program starts with its tool change (ToolChange.swift).
    func togglePlay() {
        if isPlaying { pause(); return }
        if toolChangeStop != nil { return }  // the tool-change panel is up
        // The stock as bought has nothing to play: start at the first clamping.
        if viewSide == -1 && prepStage < 0, !prepResults.isEmpty {
            if let first = jobSteps.first(where: { $0.side == -1 && $0.stage == 0 && $0.kind == .program }) { go(to: first) }
            pendingPlay = true
            return
        }
        let entries = timeline.entries
        guard !entries.isEmpty else { return }
        if playhead >= timeline.duration - 1e-6 { quietSeek(0) }
        var i = timeline.index(at: playhead)
        var program = entries[i].program
        func end(of p: Int) -> Double { entries.last { $0.program == p }?.tEnd ?? timeline.duration }
        if playhead >= end(of: program) - 1e-6, let n = entries[i...].firstIndex(where: { $0.program != program }) {
            i = n
            program = entries[n].program
            quietSeek(entries[n].tStart)
        }
        let stop = end(of: program)
        if let first = entries.firstIndex(where: { $0.program == program }), playhead <= entries[first].tStart + 1e-6,
           !toolChangesDone.contains(first), toolChange(at: first) != nil {
            beginToolChange(entry: first, resume: true, playEnd: stop)
            return
        }
        play(until: stop)
    }

    /// Plays from the playhead to `end` (nil: the side's end), stopping at a tool change on
    /// the way.
    func play(until end: Double?) {
        let stopAt = min(end ?? timeline.duration, timeline.duration)
        let changes = toolChangeEntries.filter { !toolChangesDone.contains($0) }.map { ($0, timeline.entries[$0].tStart) }
        isPlaying = true
        renderer.scene.remove(id: "deviation")  // stale while cutting; redrawn on pause
        var last = Date()
        playTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                let dt = now.timeIntervalSince(last)
                last = now
                let t = min(self.playhead + dt * self.playSpeed, stopAt)
                // A tool change inside the step (one at its end is the next step's).
                if let c = changes.first(where: { $0.1 > self.playhead + 1e-9 && $0.1 <= t && $0.1 < stopAt - 1e-9 }) {
                    self.beginToolChange(entry: c.0, resume: true, playEnd: stopAt)
                    return
                }
                self.advanceSpin(dt)
                self.quietSeek(t)
                if t >= stopAt - 1e-9 { self.pause() }
            }
        }
    }

    /// A seek by playback or a tool change, not by you (keeps the tool changes done there).
    func quietSeek(_ t: Double) {
        internalSeek = true
        seek(t)
        internalSeek = false
    }

    func pause() {
        let wasPlaying = isPlaying
        isPlaying = false
        playTimer?.invalidate()
        playTimer = nil
        if wasPlaying && showDeviation { Task { await updateDeviation() } }
    }

    func seek(_ t: Double) {
        // You moved the playhead: a tool change in progress is left, and the ones done count again.
        if !internalSeek {
            if toolChangeStop != nil { toolChangeTask?.cancel(); toolChangeStop = nil }
            toolChangesDone = []
        }
        let target = min(max(t, 0), timeline.duration)
        if isGenerating, !isPlaying, abs(target - playhead) > 60, ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil {
            print("seek jump \(Int(playhead)) → \(Int(target)) while generating: \(Thread.callStackSymbols.prefix(6).dropFirst().joined(separator: " | "))")
        }
        if target < playhead - 1e-9 { rewindSimulation(to: timeline.index(at: target)) }
        playhead = target
        updatePlayback()
        if showDeviation && !isPlaying { Task { await updateDeviation() } }
    }

    /// Steps to the start of the next/previous move.
    func step(_ delta: Int) {
        guard !timeline.entries.isEmpty else { return }
        let i = timeline.index(at: playhead)
        let j = min(max(i + delta, 0), timeline.entries.count - 1)
        seek(delta > 0 ? timeline.entries[j].tEnd : timeline.entries[j].tStart)
    }

    /// Jumps to the next/previous operation boundary.
    func jumpOperation(_ delta: Int) {
        guard !timeline.entries.isEmpty else { return }
        let current = timeline.entries[timeline.index(at: playhead)].operation
        let target = current + delta
        if let e = timeline.entries.first(where: { $0.operation == target }) { seek(e.tStart) } else { seek(delta > 0 ? timeline.duration : 0) }
    }

    /// Start times of each operation (for the timeline markers).
    var operationStarts: [(Double, Int)] {
        var out: [(Double, Int)] = []
        var last = -1
        for e in timeline.entries where e.operation != last {
            out.append((e.tStart, e.operation))
            last = e.operation
        }
        return out
    }

    /// Shows segments up to the playhead, moves the tool, and advances the material simulation.
    func updatePlayback() {
        defer { layoutCutFace() }
        guard !timeline.entries.isEmpty, let stock else {
            renderer.scene.remove(id: "tool")
            renderer.scene.remove(id: "tool.shank")
            return
        }
        let i = timeline.index(at: playhead)
        let done = playhead >= timeline.duration - 1e-9
        renderer.scene.lineSet("toolpath")?.show(upTo: done ? Int.max : (i > 0 ? entrySegmentEnd[i - 1] : 0) + partialSegments(i))
        _ = stock
        let entry = timeline.entries[i]
        if plannedTools.indices.contains(entry.operation) {
            let tool = plannedTools[entry.operation]
            if currentTool?.id != tool.id { currentTool = tool; toolChanged() }
            ensureToolMesh(tool)
        }
        // Move the machine so the tool tip is where the program is (the table moves X, the
        // translator Y, the spindle Z).
        if let q = machinePosition(forWork: timeline.position(at: playhead)) {
            setMachinePosition(q)
        }
        if simulate { advanceSimulation(to: i, partial: playhead) }
    }

    private func partialSegments(_ i: Int) -> Int {
        let e = timeline.entries[i]
        let n = (i > 0 ? entrySegmentEnd[i] - entrySegmentEnd[i - 1] : entrySegmentEnd[i])
        let f = (playhead - e.tStart) / max(e.tEnd - e.tStart, 1e-9)
        return Int((Double(n) * min(max(f, 0), 1)).rounded(.down))
    }

    // MARK: Tool assembly

    /// Turns the tool as the spindle would at the playhead: forward while cutting (M3) and with
    /// the edge finder (M3 S1500), slowly backwards while the tool itself probes (M4 S1500).
    func advanceSpin(_ dt: Double) {
        let i = timeline.index(at: playhead)
        let entry = timeline.entries.indices.contains(i) ? timeline.entries[i] : nil
        // Edge finding plays as programs 2000+, with its own tool: the cutter (electrical) or the finder.
        let probing = (entry?.program ?? 0) >= 2000
        let electrical = probing && entry.map { plannedTools.indices.contains($0.operation) && plannedTools[$0.operation].id != EdgeFinding.tool.id } == true
        let turnsPerSecond: Float = probing ? (electrical ? -1.5 : 2) : 4
        toolSpin += Float(dt) * 2 * .pi * turnsPerSecond
    }

    /// Puts this tool in the collet (rebuilt only when the tool changes).
    func ensureToolMesh(_ tool: Tool) {
        if renderer.scene.mesh("tool") == nil || toolMeshID != tool.id { buildToolMesh(tool) }
        let spin = isPlaying || touring ? simd_float4x4(simd_quatf(angle: toolSpin, axis: SIMD3(0, 0, 1))) : matrix_identity_float4x4
        for id in ["tool", "tool.shank"] { renderer.scene.mesh(id)?.transform = simd_float4x4(translation: SIMD3<Float>(tipAtModelPose)) * spin }
    }

    /// The real cutter (helical flutes, tip, shank) below the collet nut (the assembly model
    /// already has the ER-11 nut and collet), tip at the origin, pointing −Z (into the work).
    private func buildToolMesh(_ tool: Tool) {
        renderer.scene.remove(id: "tool")
        renderer.scene.remove(id: "tool.shank")
        for m in tool.sceneMeshes(device: renderer.device, id: "tool") { renderer.scene.setMesh(m) }
        toolMeshID = tool.id
    }

    // MARK: Material removal

    /// Back to the latest saved state at or before entry i (or the fresh stock).
    func rewindSimulation(to i: Int) {
        simCatchUp?.cancel()
        guard simIndex > i else { return }
        if let cp = simCheckpoints.last(where: { $0.index <= i }), renderer.scene.mesh("simstock") != nil {
            // Checkpoints later than this stay: the timeline is the same, so they're still true.
            var hm = cp.map
            hm.markAllDirty()
            heightmap = hm
            simIndex = cp.index
        } else {
            resetSimulation()
        }
    }

    /// Simulates side A to the end in the background (side B starts from it).
    func computeSideAFinal() {
        guard twoSided, let stock, let r = sideResults.first else { return }
        // Already made (or being made) for this side A: keep it.
        let key = r.paths.reduce(0) { $0 + $1.moves.count }
        if key == sideAFinalKey && (sideAFinal != nil || !(sideAFinalTask?.isCancelled ?? true)) { return }
        sideAFinalKey = key
        sideAFinalTask?.cancel()
        sideAFinal = nil
        let size = setup.stockSize(stock)
        let tools = r.planned.map(\.tool)
        let paths = r.paths, programs = r.operationProgram, lines = r.operationLines
        sideAFinalTask = Task { [weak self] in
            let hm = await Task.detached(priority: .utility) { () -> Heightmap in
                let tl = ToolpathTimeline(paths: paths, programOf: programs, lines: lines)
                var hm = Heightmap(stockMin: SIMD3(-size.x / 2, -size.y / 2, -size.z), stockMax: SIMD3(size.x / 2, size.y / 2, 0),
                                   maxCells: 250_000)
                for e in tl.entries where tools.indices.contains(e.operation) {
                    hm.apply(e.move, from: e.start, radius: tools[e.operation].diameter / 2, cornerRadius: tools[e.operation].cornerRadius)
                }
                return hm
            }.value
            guard let self, !Task.isCancelled else { return }
            self.sideAFinal = hm
            if self.viewSide == 1 {
                let t = self.playhead
                self.resetSimulation()
                self.seek(t)
            }
        }
    }

    /// Side B's back: side A's surface turned front-to-back (Y mirrored, Z from the far face).
    private func backSurface(for hm: Heightmap) -> [Float]? {
        guard twoSided, viewSide == 1, let a = sideAFinal, a.cols == hm.cols, a.rows == hm.rows else { return nil }
        let thickness = Float(hm.top - hm.bottom)
        var back = [Float](repeating: Float(hm.bottom), count: hm.cols * hm.rows)
        for r in 0..<hm.rows {
            let y = hm.origin.y + Double(r) * hm.cell
            let ra = min(max(Int(((-y - a.origin.y) / a.cell).rounded()), 0), a.rows - 1)
            for c in 0..<hm.cols { back[r * hm.cols + c] = Float(hm.top) - thickness - a.heights[ra * a.cols + c] }
        }
        return back
    }

    func resetSimulation() {
        simCatchUp?.cancel()
        simPrecompute?.cancel()
        renderer.scene.remove(id: "simstock")
        renderer.scene.remove(id: "simstock.back")
        renderer.scene.remove(id: "simstock.walls")
        renderer.scene.remove(id: "simstock.loose")
        loosePieces = 0
        simBack = nil
        heightmap = nil
        simIndex = 0
        simCheckpoints = []
        simStart = nil
        guard simulate, let stock, !timeline.entries.isEmpty else {
            renderer.scene.mesh("stock")?.isVisible = true
            return
        }
        let size = displayStockSize ?? setup.stockSize(stock)
        let box = (min: SIMD3(-size.x / 2, -size.y / 2, -size.z), max: SIMD3(size.x / 2, size.y / 2, 0))
        var hm = Heightmap(stockMin: box.min, stockMax: box.max, maxCells: 250_000)
        let origin = SIMD3<Float>(workOrigin(stockSize: displayStockSize ?? setup.stockSize(stock)))
        let c = stock.material?.linearSwatch ?? SIMD3(0.5, 0.5, 0.5)
        var back = backSurface(for: hm)
        if let open = shoulderOpen(hm, stockSize: size) {
            // Path D: the shoulders' corners are air — open cells (material from top to top).
            var b = back ?? [Float](repeating: Float(hm.bottom), count: hm.cols * hm.rows)
            for i in b.indices where open[i] { b[i] = Float(hm.top) }
            back = b
        }
        simBack = back
        if let g = SceneMesh.grid(device: renderer.device, id: "simstock", x0: Float(hm.origin.x), y0: Float(hm.origin.y),
                                  cell: Float(hm.cell), cols: hm.cols, rows: hm.rows, z: Float(hm.top),
                                  color: SIMD4(c * 0.85, 1), transform: simd_float4x4(translation: origin), bottom: Float(hm.bottom),
                                  bottomFace: back == nil) {
            renderer.scene.setMesh(g)
        }
        if back != nil, let g = SceneMesh.grid(device: renderer.device, id: "simstock.back", x0: Float(hm.origin.x), y0: Float(hm.origin.y),
                                               cell: Float(hm.cell), cols: hm.cols, rows: hm.rows, z: Float(hm.bottom),
                                               color: SIMD4(c * 0.85, 1), transform: simd_float4x4(translation: origin), facingDown: true) {
            renderer.scene.setMesh(g)
            hm.markAllDirty()  // draws the back (and opens what side A already cut through)
        }
        heightmap = hm
        renderer.scene.mesh("stock")?.isVisible = false
        applySurfaces()
        applyStockDisplay()
        simStart = hm
        precomputeCheckpoints(from: hm)
    }

    /// Runs the whole side's material removal off the main thread once and keeps the state at
    /// the start of every operation (and every 1/50 of the moves). Clicking a step, or anywhere
    /// on the timeline, then starts from the nearest one before it instead of replaying the
    /// side from the start. The same simulation as playback: the result is identical.
    func precomputeCheckpoints(from start: Heightmap) {
        let entries = timeline.entries
        let tools = plannedTools
        // While generating the timeline is rebuilt every few seconds: the CPU goes to the
        // toolpaths, and the checkpoints are made once they're done (showSide again).
        guard !entries.isEmpty, !isGenerating else { return }
        let started = Date()
        // As dense as ~150 MB of saved states allows (a state is one float per cell), at most
        // one every 1/150 of the moves: a click then simulates at most that much.
        let states = min(150, max(150_000_000 / max(start.heights.count * 4, 1), 20))
        let every = max(entries.count / states, 100)
        let tick = timeline.duration  // which timeline these are for
        simPrecompute = Task { [weak self] in
            var hm = start
            var k = 0
            var lastOp = -1
            while k < entries.count {
                // A slice at a time; checkpoints are handed over as they come.
                let slice = await Task.detached(priority: .utility) { [hm, k, lastOp] () -> (Heightmap, Int, [(index: Int, map: Heightmap)], Int) in
                    var hm = hm, k = k, lastOp = lastOp
                    var found: [(index: Int, map: Heightmap)] = []
                    let stop = min(k + max(every * 4, 20_000), entries.count)
                    while k < stop {
                        let e = entries[k]
                        if e.operation != lastOp || (k > 0 && k % every == 0) {
                            lastOp = e.operation
                            if k > 0 { found.append((k, hm)) }
                        }
                        let tool = tools.indices.contains(e.operation) ? tools[e.operation] : nil
                        if let tool, e.operation != 0, !EdgeFinding.isEdgeFinder(tool) {
                            hm.apply(e.move, from: e.start, radius: tool.diameter / 2, cornerRadius: tool.cornerRadius)
                        }
                        k += 1
                    }
                    if Task.isCancelled { return (hm, k, [], lastOp) }
                    return (hm, k, found, lastOp)
                }.value
                guard let self, !Task.isCancelled, self.timeline.duration == tick else { return }
                (hm, k) = (slice.0, slice.1)
                lastOp = slice.3
                for cp in slice.2 where !self.simCheckpoints.contains(where: { $0.index == cp.index }) {
                    let at = self.simCheckpoints.firstIndex { $0.index > cp.index } ?? self.simCheckpoints.count
                    self.simCheckpoints.insert(cp, at: at)
                }
            }
            if ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil {
                print("timing checkpoints \(self?.simCheckpoints.count ?? 0) for \(entries.count) moves in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
            }
        }
    }

    /// Applies every move up to entry i (and the part of entry i before the playhead).
    /// Applies moves up to entry i, ~25 ms at a time: a long jump finishes over the next frames
    /// instead of freezing the scrubber. Saves a checkpoint every 1/40 of the job on the way.
    private func advanceSimulation(to i: Int, partial t: Double) {
        simCatchUp?.cancel()
        guard var hm = heightmap else { return }
        let every = max(timeline.entries.count / 40, 200)
        // Scripted runs (snapshots) want the finished state at once.
        let scripted = ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] != nil
        let deadline = Date().addingTimeInterval(scripted ? 1e9 : isPlaying ? 0.5 : 0.025)
        var n = 0
        // A jump ahead starts from the latest checkpoint on the way (precomputeCheckpoints).
        if let cp = simCheckpoints.last(where: { $0.index <= i }), cp.index > simIndex + every / 4 {
            hm = cp.map
            hm.markAllDirty()
            simIndex = cp.index
        }
        while simIndex < i {
            let e = timeline.entries[simIndex]
            let tool = plannedTools.indices.contains(e.operation) ? plannedTools[e.operation] : nil
            if let tool, e.operation != 0, !EdgeFinding.isEdgeFinder(tool) { hm.apply(e.move, from: e.start, radius: tool.diameter / 2, cornerRadius: tool.cornerRadius) }
            simIndex += 1
            if simIndex % every == 0, !simCheckpoints.contains(where: { $0.index == simIndex }) {
                let at = simCheckpoints.firstIndex { $0.index > simIndex } ?? simCheckpoints.count
                simCheckpoints.insert((simIndex, hm), at: at)
            }
            n += 1
            if n % 64 == 0, Date() > deadline { break }
        }
        heightmap = hm
        // The current move's partial progress is drawn by the tool; it's applied once complete.
        refreshSimMesh()
        if simIndex < i {
            simCatchUp = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(8))
                guard let self, !Task.isCancelled else { return }
                self.advanceSimulation(to: i, partial: t)
            }
        }
    }

    private func refreshSimMesh() {
        guard var hm = heightmap, let mesh = renderer.scene.mesh("simstock"), let (c0, r0, c1, r1) = hm.takeDirty() else { return }
        heightmap = hm
        let back = simBack
        if let back, let bm = renderer.scene.mesh("simstock.back") {
            bm.updateGrid(values: back, top: hm.heights, back: back, cols: hm.cols, rows: hm.rows, cell: Float(hm.cell),
                          c0: c0, r0: r0, c1: c1, r1: r1, downward: true, floor: Float(hm.bottom))
        }
        mesh.updateGrid(values: hm.heights, top: hm.heights, back: back, cols: hm.cols, rows: hm.rows, cell: Float(hm.cell),
                        c0: c0, r0: r0, c1: c1, r1: r1, downward: false, floor: Float(hm.bottom))
        scheduleSimSurfaces()
    }

    /// The walls around holes cut through and the loose pieces: rebuilt after each change,
    /// at most every 0.2 s while playing (they scan the whole grid).
    func scheduleSimSurfaces() {
        guard simBack != nil else { return }  // one side, nothing cut through
        let wait = 0.2 - Date().timeIntervalSince(simSurfacesAt)
        if !isPlaying || wait <= 0 {
            rebuildSimSurfaces()
        } else if !simSurfacesPending {
            simSurfacesPending = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self else { return }
                self.simSurfacesPending = false
                self.rebuildSimSurfaces()
            }
        }
    }

    func rebuildSimSurfaces() {
        simSurfacesAt = Date()
        let scene = renderer.scene
        scene.remove(id: "simstock.walls")
        scene.remove(id: "simstock.loose")
        guard let hm = heightmap, let back = simBack, let sim = scene.mesh("simstock") else { if loosePieces != 0 { loosePieces = 0 }; return }
        let h = hm.heights, cols = hm.cols, rows = hm.rows
        let x0 = Float(hm.origin.x), y0 = Float(hm.origin.y), cell = Float(hm.cell)
        let open: (Int) -> Bool = { h[$0] <= back[$0] + 0.005 }
        let w = SimSurfaces.walls(cols: cols, rows: rows, x0: x0, y0: y0, cell: cell, top: h, back: back, bottom: Float(hm.bottom), open: open)
        if !w.p.isEmpty, let m = SceneMesh(device: renderer.device, id: "simstock.walls", positions: w.p, normals: w.n,
                                          indices: (0..<UInt32(w.p.count / 3)).map { $0 }, color: sim.color, transform: sim.transform) {
            m.material = sim.material
            m.isVisible = sim.isVisible
            m.xrayThrough = true
            scene.setMesh(m)
        }
        // Loose pieces: nothing joins them to where the clamps hold the stock.
        let strips = setup.onBed ? [] : shoulderStrips(stockSize: displayStockSize ?? stock.map { setup.stockSize($0) } ?? .zero)
        let ox = hm.origin.x, oy = hm.origin.y, dc = hm.cell
        let loose = SimSurfaces.loose(cols: cols, rows: rows, top: h, back: back, bottom: Float(hm.bottom), open: open) { i in
            let x = ox + Double(i % cols) * dc, y = oy + Double(i / cols) * dc
            return strips.contains { x >= $0.min.x && x <= $0.max.x && y >= $0.min.y && y <= $0.max.y }
        }
        if loosePieces != loose.pieces { loosePieces = loose.pieces }
        if ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil, loose.pieces > 0 {
            var n = 0, sx = 0.0, sy = 0.0, x0 = Double.infinity, x1 = -Double.infinity, y0 = Double.infinity, y1 = -Double.infinity
            for i in loose.mask.indices where loose.mask[i] {
                let x = ox + Double(i % cols) * dc, y = oy + Double(i / cols) * dc
                n += 1; sx += x; sy += y; x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
            print("loose detail: \(loose.pieces) piece(s), \(n) points, x \(String(format: "%.1f…%.1f", x0, x1)) y \(String(format: "%.1f…%.1f", y0, y1)), strips \(strips.count)")
        }
        if loose.pieces > 0 {
            let o = SimSurfaces.overlay(cols: cols, rows: rows, x0: x0, y0: y0, cell: cell, top: h, mask: loose.mask)
            if !o.p.isEmpty, let m = SceneMesh(device: renderer.device, id: "simstock.loose", positions: o.p, normals: o.n,
                                              indices: (0..<UInt32(o.p.count / 3)).map { $0 }, color: SIMD4(0.95, 0.15, 0.75, 1), transform: sim.transform) {
                m.depthBias = 1
                m.isVisible = sim.isVisible
                scene.setMesh(m)
            }
        }
    }

    // MARK: Inspection

    /// Finds the toolpath move nearest to a click and shows its details and G-code line.
    func inspect(at point: CGPoint, viewSize: CGSize) {
        guard let stock, !timeline.entries.isEmpty else { return }
        let ray = renderer.ray(at: point, viewSize: viewSize)
        let origin = SIMD3<Double>(workOrigin(stockSize: displayStockSize ?? setup.stockSize(stock)))
        let o = SIMD3<Double>(ray.origin) - origin, d = SIMD3<Double>(ray.direction)
        var best = (Double.infinity, -1)
        let limit = timeline.entries.count
        for k in 0..<limit {
            let e = timeline.entries[k]
            let dist = Self.raySegmentDistance(o, d, e.start, e.move.position)
            if dist < best.0 { best = (dist, k) }
        }
        let h = Double(renderer.camera.distance * tan(renderer.camera.fieldOfView / 2))
        guard best.1 >= 0, best.0 < h * 0.03 else { inspected = nil; return }
        let e = timeline.entries[best.1]
        var context: [(Int, String)] = []
        if let line = e.gcodeLine, programs.indices.contains(e.program) {
            let lines = programs[e.program].gcode.split(separator: "\n", omittingEmptySubsequences: false)
            for n in max(line - 3, 1)...min(line + 3, lines.count) { context.append((n, String(lines[n - 1]))) }
        }
        let op = timelineTitles.indices.contains(e.operation) ? timelineTitles[e.operation] : "Operation"
        inspected = InspectedMove(entry: best.1, operation: op, role: "\(e.move.role)", feed: e.move.feed,
                                  position: e.move.position, time: e.tEnd, program: e.program, line: e.gcodeLine, context: context)
        seek(e.tEnd)
    }

    static func raySegmentDistance(_ o: SIMD3<Double>, _ d: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        // Closest distance between a ray and a segment (sampled along the segment: cheap and robust).
        var best = Double.infinity
        for k in 0...8 {
            let p = a + (b - a) * (Double(k) / 8)
            let v = p - o
            let t = max(simd_dot(v, d), 0)
            best = min(best, simd_length(v - d * t))
        }
        return best
    }
}

extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self.init(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(t, 1)))
    }

    init(rotationX a: Float) {
        let c = cos(a), s = sin(a)
        self.init(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
    }
}
