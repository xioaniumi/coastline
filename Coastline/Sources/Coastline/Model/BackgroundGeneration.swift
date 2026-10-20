import CoastlineCore
import Foundation
import simd

/// Where one operation (on one side) is in a generation, for the operation list.
enum GenState: Equatable {
    case queued, running, ready
    case failed(String)
}

/// One generation in progress, rendered in the background like a video editor renders a
/// timeline: the operations of every side are jobs, several engine processes take them in
/// machining order, and each side's toolpaths appear (timeline, simulation) as soon as the
/// operations from its start are done. A failed operation doesn't stop the others; generating
/// again redoes only it (everything else comes from the cache).
@MainActor
final class GenerationRun {
    struct SidePlan {
        var side: Int
        var setup: Setup
        var planned: [EngineClient.PlannedOperation]
        var materialTop: Double
        var tabSpec: HoldingTabs?
        var tabBottom: Double
        var transform: simd_double4x4
        /// The part's outline box in this side's work frame (X, Y), for the reach check.
        var partX: ClosedRange<Double> = 0...0
        var partY: ClosedRange<Double> = 0...0
    }

    var sides: [SidePlan] = []
    /// The stock box and grip strips, kept here (on the heap): over-aligned SIMD values passed
    /// into async calls trip Swift's task allocator ("freed pointer was not the last allocation").
    var boxMin = SIMD3<Double>(repeating: 0)
    var boxMax = SIMD3<Double>(repeating: 0)
    var strips: [(min: SIMD2<Double>, max: SIMD2<Double>)] = []
    /// The clamp kit's reachable work X (nil: not in the kit, or not known).
    var kitXRange: ClosedRange<Double>?
    var jobs: [(side: Int, k: Int)] = []
    var next = 0
    /// Per side, per operation: the toolpaths once done.
    var done: [[[OperationToolpath]?]] = []
    var failed: [(side: Int, k: Int, message: String)] = []
    var bridged = 0.0
    /// Per side: how many operations from its start are shown.
    var published: [Int] = []
    var lastPublish = Date.distantPast
    var publishScheduled = false
    /// Side B's tab frame (from side A's simulated clearing): being made, and made.
    var frameTask: Task<TabFrame, Never>?
    var frameReady = false
    /// What the job looked like when it started: a change on the way stops it.
    var signature: String

    init(signature: String) { self.signature = signature }

    var finished: Int { done.reduce(0) { $0 + $1.filter { $0 != nil }.count } }
    var total: Int { jobs.count }
    func prefix(_ si: Int) -> Int { done[si].prefix { $0 != nil }.count }
}

extension AppModel {
    /// A program whose moves had to be pulled into the part to stay within the travel fails.
    static let outOfReach = "Out of the CR-1's reach:"

    /// How many engine processes generate at once (the main one and workers).
    static var generationWorkers: Int {
        if let n = ProcessInfo.processInfo.environment["COASTLINE_WORKERS"].flatMap(Int.init), n >= 1 { return n }
        if AppSettings.shared.engines > 0 { return AppSettings.shared.engines }
        // Each engine also runs several threads inside (roughing levels, drop-cutter batches):
        // about one engine per 2–3 cores.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return cores >= 10 ? 4 : cores >= 8 ? 3 : 2
    }

    /// The job's shape that toolpaths depend on (a change while generating stops it).
    var generationSignature: String {
        let s = setup
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys  // dictionaries encode in a stable order
        let ops = (try? enc.encode(operations)).map { $0.hashValue } ?? 0
        return "\(ops)|\(stockID?.uuidString ?? "")|\(twoSided)|\(s.partOffsetX)|\(s.partOffsetY)|\(s.facing)|\(s.spin)|\(s.stockAxes)|\(s.partScale)|\(s.copies)|\(s.topAllowance)"
    }

    func genState(for opID: UUID) -> GenState? {
        guard let bySide = opGenState[opID], !bySide.isEmpty else { return nil }
        let states = bySide.keys.sorted().map { bySide[$0]! }
        if let f = states.first(where: { if case .failed = $0 { true } else { false } }) { return f }
        if states.contains(.running) { return .running }
        if states.contains(.queued) { return .queued }
        return .ready
    }

    var failedOperationCount: Int {
        opGenState.values.reduce(0) { $0 + $1.values.filter { if case .failed = $0 { true } else { false } }.count }
    }

    /// Runs the jobs on the main engine and worker engines (started on the way, each with the
    /// part loaded), then returns. Cancellation and failures are recorded in `run`.
    func runInBackground(_ run: GenerationRun, partURL url: URL, partID fallbackID: String) async throws {
        let main = try await liveEngine()
        let mainPartID = self.part?.partID ?? fallbackID
        // Workers only when there's real work: cached operations come back instantly.
        let uncached = run.jobs.filter { j in
            let sp = run.sides[j.side]
            return opCache[Self.generationKey(partID: mainPartID, sp.planned[j.k], sp.transform, run.boxMin, run.boxMax, sp.tabSpec, sp.tabBottom)] == nil
        }.count
        let extra = max(min(Self.generationWorkers - 1, uncached - 1), 0)
        // Plain tasks on the main actor (each waits on its own engine process, so they run in
        // parallel); a task group here tripped the task allocator with this SDK and runtime.
        var tasks = [Task { @MainActor in
            await self.work(run, engine: main, partID: mainPartID, mainPartID: mainPartID)
        }]
        for i in 0..<extra {
            tasks.append(Task { @MainActor in
                guard let w = await self.worker(i, url: url) else { return }
                await self.work(run, engine: w.engine, partID: w.partID, mainPartID: mainPartID)
            })
        }
        for t in tasks { await t.value }
        if cancelGeneration { throw CancellationError() }
    }

    /// A worker engine with the part loaded (kept between generations, restarted if it died
    /// or the part changed).
    private func worker(_ i: Int, url: URL) async -> (engine: EngineClient, partID: String)? {
        if workerEngines.indices.contains(i) {
            let w = workerEngines[i]
            if w.partURL == url, await w.engine.isRunning() { return (w.engine, w.partID) }
            w.engine.terminate()
        }
        do {
            let e = try EngineClient.development(repoRoot: Self.repoRoot)
            let m = try await e.importPart(url)
            let w = (engine: e, partURL: url, partID: m.partID)
            if workerEngines.indices.contains(i) { workerEngines[i] = w } else { workerEngines.append(w) }
            return (e, m.partID)
        } catch {
            return nil  // the main engine carries on alone
        }
    }

    /// One engine's loop: takes the next job until there are none (or it's cancelled).
    private func work(_ run: GenerationRun, engine: EngineClient, partID: String, mainPartID: String) async {
        while !cancelGeneration, run.next < run.jobs.count {
            if generationSignature != run.signature {
                if ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil { print("signature changed:\n  \(run.signature)\n  \(generationSignature)") }
                cancelGenerationNow()
                status = "The job changed while generating: generate again (finished operations are kept)."
                return
            }
            // Side B's tabs are made long enough for side A's channel: its jobs wait for that.
            if run.jobs[run.next].side > 0, run.sides[run.jobs[run.next].side].tabSpec != nil, !run.frameReady {
                await awaitTabFrame(run, side: run.jobs[run.next].side)
                continue
            }
            let (si, k) = run.jobs[run.next]
            run.next += 1
            let side = run.sides[si].side
            let opID = run.sides[si].planned[k].operation.id
            setGenState(opID, side: side, .running)
            updateGenerationStatus(run)
            let opStart = Date()
            let key = jobKey(run, si, k, mainPartID: mainPartID)
            do {
                let one: [OperationToolpath], placed: [PlacedTab]
                if let hit = opCache[key] {
                    (one, placed) = hit
                    cachedOps += 1
                } else {
                    (one, placed) = try await generateJob(run, si, k, engine: engine, partID: partID)
                    storeInCache(key, (one, placed))
                }
                if cancelGeneration { return }
                run.done[si][k] = finishJob(one, k: k, si: si, run: run)
                if !placed.isEmpty {
                    placedTabs = placed
                    if let h = run.sides[si].tabSpec?.height { placedTabZ = run.sides[si].tabBottom...(run.sides[si].tabBottom + h) }
                }
                // Ready once every depth slice of it is.
                let allDone = run.sides[si].planned.indices.allSatisfy { j in
                    run.sides[si].planned[j].operation.id != opID || run.done[si][j] != nil
                }
                if allDone { setGenState(opID, side: side, .ready) }
                if ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil {
                    let p = run.sides[si].planned[k]
                    print("timing op side \(side) \(p.operation.title) \(p.tool.name.prefix(18)) \(String(format: "%.1f", Date().timeIntervalSince(opStart))) s, \(one.first?.moves.count ?? 0) moves")
                }
                updateGenerationStatus(run)
                publishPartial(run)
            } catch {
                if cancelGeneration { return }
                let message = (error as? EngineClient.EngineError).map { $0.type == "EngineExited" ? "The geometry engine crashed on this operation (a native library failed on this geometry)." : $0.message } ?? "\(error)"
                run.failed.append((si, k, message))
                setGenState(opID, side: side, .failed(message))
                if ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil { print("generate failed side \(side): \(message)") }
                updateGenerationStatus(run)
                if !(await engine.isRunning()) { return }  // this engine died: the others carry on
            }
        }
    }

    /// What every operation's result goes through: warnings the plan handles become notes,
    /// copies along the bar, and the grip strips kept uncut.
    private func finishJob(_ one: [OperationToolpath], k: Int, si: Int, run: GenerationRun) -> [OperationToolpath] {
        let sp = run.sides[si]
        let strips = run.strips
        let p = sp.planned[k]
        var clipped = one
        // "Too big for these pockets" is no warning when a smaller tool comes later for exactly
        // that: the plan handles it.
        for i in clipped.indices {
            let t = WarningTriage.split(clipped[i].warnings, at: k, in: sp.planned)
            clipped[i].warnings = t.warnings
            clipped[i].notes += t.notes
        }
        // Batching: the same cuts for every copy along the bar (facing once for all).
        if setup.copies > 1, p.operation.kind != .facing {
            clipped = clipped.map { batched($0, offsets: copyOffsets(for: sp.setup)) }
        }
        if p.operation.kind != .facing {
            for i in clipped.indices {
                // The strips under the jaws are never faced (side B's backing comes off only around
                // the part): anything below their top (z 0) would cut what the jaws hold.
                let (m, skipped) = GripZones.clip(clipped[i].moves, tool: p.tool, strips: strips, below: -0.05,
                                                  plungeFeed: p.data.plungeFeed)
                clipped[i].moves = m
                run.bridged += skipped
            }
        }
        // Within the CR-1's X travel (the bar's top edge can sit right at it): a move past it is
        // brought back to the limit; an arc that would end past it becomes a straight line.
        if let xr = run.kitXRange {
            // Brought back toward the part, a cut could reach into it: where the tool, held at
            // the limit, would overlap the part's outline box (alongside it, below the face),
            // the operation fails instead (the bar must sit lower or higher in the kit).
            let r = p.tool.diameter / 2
            let px = sp.partX, py = sp.partY
            var into = 0, worst = 0.0
            // Does a straight move from a to b (tool radius r) come near the part's box?
            func nearPart(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool {
                let lo = SIMD2(px.lowerBound - r - 0.05, py.lowerBound - r - 0.05), hi = SIMD2(px.upperBound + r + 0.05, py.upperBound + r + 0.05)
                for k in 0...20 {
                    let t = Double(k) / 20, q = a + (b - a) * t
                    if q.z < -0.05, q.x > lo.x, q.x < hi.x, q.y > lo.y, q.y < hi.y { return true }
                }
                return false
            }
            for i in clipped.indices {
                var startMoved = false  // an arc's centre is relative to its start
                var out: [Move] = []
                out.reserveCapacity(clipped[i].moves.count)
                for m in clipped[i].moves {
                    let beyond = m.x < xr.lowerBound || m.x > xr.upperBound
                    defer { startMoved = beyond }
                    guard beyond || startMoved else { out.append(m); continue }
                    var q = m
                    q.x = min(max(m.x, xr.lowerBound), xr.upperBound)
                    if q.motion != .line { q.motion = .line; q.i = 0; q.j = 0 }
                    let from = out.last?.position ?? q.position
                    if !beyond, m.motion == .line, m.role == .rapid || !nearPart(from, q.position) { out.append(m); continue }
                    if m.role != .rapid, !beyond, nearPart(from, q.position) {
                        // From a clamped start, the move (an arc becomes a chord) would cross the
                        // part: up and over instead (only frame is left standing).
                        let up = max(from.z, q.position.z, 0) + 3
                        out.append(Move(.rapid, x: from.x, y: from.y, z: up))
                        out.append(Move(.rapid, x: q.x, y: q.y, z: up))
                        out.append(Move(.plunge, x: q.x, y: q.y, z: q.z, feed: p.data.plungeFeed))
                        continue
                    }
                    let pushed = abs(q.x - m.x)
                    if m.role != .rapid, pushed > 0.02, m.z < -0.05, m.y > py.lowerBound - r, m.y < py.upperBound + r {
                        // Pulled down from above: its lower edge vs the part's top; pulled up: the reverse.
                        let overlap = q.x < m.x ? (px.upperBound - (q.x - r)) : ((q.x + r) - px.lowerBound)
                        if overlap > 0.02 { into += 1; worst = max(worst, min(overlap, pushed)) }
                    }
                    out.append(q)
                }
                clipped[i].moves = out
            }
            if into > 0, !clipped.isEmpty {
                clipped[0].warnings.append(Self.outOfReach + " \(into) cutting move\(into == 1 ? "" : "s") of this ⌀\(Length.mm(p.tool.diameter)) mm tool would have to stop up to \(Length.mm(worst)) mm short at the CR-1's X travel, inside the part's outline. Lower the bar in the kit (Clamp kit: bottom shoulders or parallels) so the part's edge plus the tool's radius is within reach.")
            }
        }
        return clipped
    }

    private func jobKey(_ run: GenerationRun, _ si: Int, _ k: Int, mainPartID: String) -> String {
        let sp = run.sides[si]
        return Self.generationKey(partID: mainPartID, sp.planned[k], sp.transform, run.boxMin, run.boxMax, sp.tabSpec, sp.tabBottom)
    }

    /// The engine call, with everything read from the run inside (no SIMD values in the async
    /// frame of the caller).
    private func generateJob(_ run: GenerationRun, _ si: Int, _ k: Int, engine: EngineClient, partID: String) async throws -> ([OperationToolpath], [PlacedTab]) {
        let sp = run.sides[si]
        let r = try await engine.generate(partID: partID, transform: sp.transform, stockMin: run.boxMin, stockMax: run.boxMax,
                                          operations: [sp.planned[k]], tabs: sp.tabSpec, tabBottom: sp.tabBottom)
        return (r.paths, r.tabs)
    }

    func setGenState(_ id: UUID, side: Int, _ s: GenState) {
        opGenState[id, default: [:]][side] = s
    }

    private func updateGenerationStatus(_ run: GenerationRun) {
        let running = opGenState.values.reduce(0) { $0 + $1.values.filter { $0 == .running }.count }
        let failed = run.failed.isEmpty ? "" : " · \(run.failed.count) failed"
        status = "Generating: \(run.finished) of \(run.total) ready · \(running) at a time\(failed)"
        generationProgress = Double(run.finished) / Double(max(run.total, 1))
    }

    /// Shows each side's toolpaths from its start up to the first operation still being made:
    /// the timeline and simulation work on them while the rest generates. At most every 2.5 s
    /// (a side that completes shows at once); the playhead stays where you left it.
    func publishPartial(_ run: GenerationRun, force: Bool = false) {
        let grew = run.sides.indices.contains { run.prefix($0) > run.published[$0] }
        guard grew else { return }
        let sideDone = run.sides.indices.contains { run.prefix($0) == run.sides[$0].planned.count && run.published[$0] < run.prefix($0) }
        let wait = 2.5 - Date().timeIntervalSince(run.lastPublish)
        if !force && !sideDone && wait > 0 {
            if !run.publishScheduled {
                run.publishScheduled = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    run.publishScheduled = false
                    guard let self, self.isGenerating, !self.cancelGeneration else { return }
                    self.publishPartial(run, force: true)
                }
            }
            return
        }
        run.lastPublish = Date()
        var results: [SideResult] = []
        var program = 0
        let lastSide = run.sides.indices.last { run.prefix($0) > 0 } ?? 0
        for si in run.sides.indices where si <= lastSide {
            let sp = run.sides[si]
            let n = run.prefix(si)
            run.published[si] = n
            let planned = Array(sp.planned.prefix(n))
            let paths = (0..<n).flatMap { run.done[si][$0] ?? [] }
            // Programs as they'll be: consecutive operations with the same tool share one.
            var opProgram: [Int] = []
            for (k, p) in planned.enumerated() {
                if k > 0 && planned[k - 1].tool.id != p.tool.id { program += 1 }
                opProgram.append(program)
            }
            if !planned.isEmpty { program += 1 }
            results.append(SideResult(side: sp.side, setup: sp.setup, planned: planned, paths: paths,
                                      operationProgram: opProgram, operationLines: Array(repeating: [], count: planned.count)))
        }
        let first = sideResults.isEmpty
        let keep = playhead
        let atEnd = timeline.entries.isEmpty || playhead >= timeline.duration - 1e-6
        sideResults = results
        toolpaths = Dictionary((results.first?.paths ?? []).map { ($0.operationID, $0) }, uniquingKeysWith: { a, _ in a })
        if viewSide >= results.count { viewSide = 0 }
        // In Machining the stock prep's view has nothing yet (its programs come at the end):
        // the first toolpaths show on side A.
        // The prep's programs were made first: the job starts there (chapter 1). Without a prep,
        // side A from its start.
        if first && viewSide < 0 && prepResults.isEmpty && (stage == .machining || stage == .review) {
            switchingView = true
            viewSide = 0
            prepStage = 0
            switchingView = false
        }
        // Side A complete: its final state for side B's simulation (the back) from now on.
        if twoSided, let a = results.first, a.planned.count >= (plannedOperationCount[0] ?? .max) { computeSideAFinal() }
        if first {
            if viewSide >= 0 { showSide(at: 0) }  // chapter 1, step 1
            focusWork()
        } else if viewSide >= 0 {
            // Never onto the steps that just arrived: at the end of what was there, stay on
            // its last step.
            showSide(at: atEnd ? max(keep - 1e-3, 0) : keep)
        }
        if ProcessInfo.processInfo.environment["COASTLINE_TIMING"] != nil {
            print("publish ready \(run.sides.indices.map { "\(run.prefix($0))/\(run.sides[$0].planned.count)" }) of \(run.finished)/\(run.total) done, timeline \(Int(timeline.duration)) s, playhead \(Int(playhead)) s")
        }
    }
}
