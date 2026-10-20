import CoastlineCore
import Foundation
import simd

/// A tool change in playback, as it happens at the machine: where one program's tool differs
/// from the last (the edge finder to the first cutter too), playback stops, the CR-1 goes to
/// the tool-change position (Coast Runner's moves: spindle back, over, table down, spindle out),
/// and a panel asks you to change the tool. "Tool Changed" puts the new tool in and the machine
/// goes back to the next cut.
/// Where this job's tools are changed (machine Y and Z; X is Coast Runner's, the table down).
struct ToolChangeSpot: Equatable {
    var y: Double
    var z: Double
    /// Why it isn't Coast Runner's position, if it isn't.
    var note: String?
}

struct ToolChangeStop: Equatable {
    enum Phase { case moving, waiting, returning }
    /// Where in the timeline the new tool's program starts.
    var time: Double
    var entry: Int
    var from: Tool?
    var to: Tool
    var phase: Phase
    /// Play on after the change (it came up while playing).
    var resume: Bool
    /// The step played after it (its end).
    var playEnd: Double?
    /// What the path couldn't keep to (it stopped short to keep clear).
    var note: String?

    static func == (a: Self, b: Self) -> Bool { a.entry == b.entry && a.phase == b.phase }
}

extension AppModel {
    /// The tool cutting at a timeline entry (the edge finder's program has its own).
    func tool(atEntry i: Int) -> Tool? {
        let op = timeline.entries[i].operation
        return plannedTools.indices.contains(op) ? plannedTools[op] : nil
    }

    /// Timeline entries where the tool changes (the first entry of the new tool's program).
    var toolChangeEntries: [Int] {
        var out: [Int] = []
        var last: Tool?
        for i in timeline.entries.indices {
            guard let t = tool(atEntry: i) else { continue }
            if let l = last, l.id != t.id { out.append(i) }
            last = t
        }
        return out
    }

    /// The tool change starting at entry i, if one does.
    func toolChange(at i: Int) -> (from: Tool?, to: Tool)? {
        guard toolChangeEntries.contains(i), let to = tool(atEntry: i) else { return nil }
        let from = (0..<i).reversed().lazy.compactMap { self.tool(atEntry: $0) }.first
        return (from, to)
    }

    /// Stops playback at a tool change and runs it (see ToolChangeStop).
    func beginToolChange(entry i: Int, resume: Bool, playEnd: Double?) {
        guard let change = toolChange(at: i) else { return }
        pause()
        let t = timeline.entries[i].tStart
        // Just before the new program: the old tool still in.
        quietSeek(max(t - 1e-6, 0))
        let plan = toolChangePath(from: machinePosition, tool: change.from)
        toolChangeStop = ToolChangeStop(time: t, entry: i, from: change.from, to: change.to, phase: .moving, resume: resume, playEnd: playEnd,
                                        note: plan.note)
        animateMachine(along: plan.path) { [weak self] in
            guard let self, self.toolChangeStop?.entry == i else { return }
            self.toolChangeStop?.phase = .waiting
            self.status = "Tool change: fit the \(change.to.name)"
        }
    }

    /// "Tool Changed": the new tool goes in, the machine goes back the way it came to the
    /// next cut, and playback carries on (when it was playing).
    func confirmToolChange() {
        guard var stop = toolChangeStop, stop.phase == .waiting else { return }
        stop.phase = .returning
        toolChangeStop = stop
        currentTool = stop.to
        ensureToolMesh(stop.to)
        let start = timeline.entries[stop.entry].start
        let target = machinePosition(forWork: start, stickout: stop.to.stickout) ?? machinePosition
        // Back the way a change from the next cut would go out, reversed: the spindle in
        // first, over, then to the cut (all clear of the table's load, with the new tool).
        let back = toolChangePath(from: target, tool: stop.to).path.reversed()
        let path = [machinePosition, SIMD3(machinePosition.x, machinePosition.y, machine.machineEnvelope.z.upperBound)] + back.dropFirst()
        animateMachine(along: path) { [weak self] in
            guard let self, let s = self.toolChangeStop, s.entry == stop.entry else { return }
            self.toolChangeStop = nil
            self.toolChangesDone.insert(stop.entry)
            self.quietSeek(s.time + 1e-6)  // into the new program: its tool shows
            self.status = "Tool changed: \(s.to.name)"
            if s.resume { self.play(until: s.playEnd) }
        }
    }

    /// Leaves a tool change without doing it (scrubbing away, Escape).
    func cancelToolChange() {
        guard toolChangeStop != nil else { return }
        toolChangeTask?.cancel()
        toolChangeStop = nil
        updatePlayback()
    }

    // MARK: A path that keeps clear

    /// The spindle head and the translator, built once from the machine model.
    private func headTreesBuilt() -> (z: TriangleTree, y: TriangleTree)? {
        if let t = headTrees { return t }
        guard let mm = machineModel else { return nil }
        func tree(_ group: String) -> TriangleTree {
            var tris: [SIMD3<Double>] = []
            for p in mm.parts where p.group == group && !p.role.hasPrefix("enclosure") {
                let v = p.mesh.vertices
                for idx in p.mesh.indices {
                    let i = Int(idx) * 3
                    tris.append(SIMD3(Double(v[i]), Double(v[i + 1]), Double(v[i + 2])))
                }
            }
            return TriangleTree(tris)
        }
        let t = (z: tree("z"), y: tree("y"))
        headTrees = t
        return t
    }

    /// What's on the table now (fixtures, parallels, stock), at the table's modelled pose.
    func bedTreeBuilt() -> TriangleTree? {
        if let b = bedTree, b.generation == collisionGeneration { return b.tree }
        guard !bedBodies.isEmpty else { return nil }
        let t = TriangleTree(Self.triangles(bedBodies, meshes: kitParts.map(\.mesh)))
        bedTree = (collisionGeneration, t)
        return t
    }

    /// A tool as a cylinder below the collet nut (model coordinates, machine at its modelled pose).
    private func toolTree(_ tool: Tool?) -> TriangleTree? {
        guard let tool, machineModel != nil else { return nil }
        let tip = tipAtModelPose(stickout: tool.stickout), r = max(tool.diameter, tool.shankDiameter) / 2
        var tris: [SIMD3<Double>] = []
        let n = 16
        for k in 0..<n {
            let a = 2 * Double.pi * Double(k) / Double(n), b = 2 * Double.pi * Double(k + 1) / Double(n)
            let pa = SIMD3(r * cos(a), r * sin(a), 0), pb = SIMD3(r * cos(b), r * sin(b), 0)
            let lo = tip, hi = tip + SIMD3(0, 0, tool.stickout)
            tris += [lo + pa, lo + pb, hi + pb, lo + pa, hi + pb, hi + pa, lo, lo + pb, lo + pa]
        }
        return TriangleTree(tris)
    }

    /// Whether the spindle head, the translator and the tool keep clear of what's on the table
    /// at machine position q (the table moves X; the translator Y; the spindle Y and Z).
    func headClear(at q: SIMD3<Double>, tool: Tool?, bed other: TriangleTree? = nil) -> Bool {
        guard let mm = machineModel, let head = headTreesBuilt(), let bed = other ?? bedTreeBuilt() else { return true }
        let m = SIMD3(mm.modelPose.x, mm.modelPose.y, mm.modelPose.z)
        // The table relative to each moving group at its modelled pose.
        let toHead = m - q, toTranslator = SIMD3(m.x - q.x, m.y - q.y, 0)
        if head.z.touches(bed, offset: toHead) || head.y.touches(bed, offset: toTranslator) { return false }
        if let t = toolTree(tool), t.touches(bed, offset: toHead) { return false }
        return true
    }

    /// Whether a straight move keeps clear (checked every 2 mm; its start may be where the tool
    /// is now).
    func legClear(_ a: SIMD3<Double>, _ b: SIMD3<Double>, tool: Tool?) -> Bool {
        let n = max(Int((simd_length(b - a) / 2).rounded(.up)), 1)
        return (1...n).allSatisfy { headClear(at: a + (b - a) * Double($0) / Double(n), tool: tool) }
    }

    /// Room kept around the spindle, collet nut and tool at the tool-change position, mm: your
    /// hands and two wrenches go in there.
    static let toolChangeRoom = 15.0

    /// Clear with room to spare: the head and tool still clear when the machine is `toolChangeRoom`
    /// further in any direction (up, down, left, right, out).
    func roomy(at q: SIMD3<Double>, tool: Tool?, bed: TriangleTree? = nil) -> Bool {
        let m = Self.toolChangeRoom
        return [SIMD3<Double>.zero, SIMD3(m, 0, 0), SIMD3(-m, 0, 0), SIMD3(0, m, 0), SIMD3(0, -m, 0), SIMD3(0, 0, -m)]
            .allSatisfy { headClear(at: q + $0, tool: tool, bed: bed) }
    }

    /// Where to change tools in this job: the table down as Coast Runner does (X), and the
    /// spindle brought forward (−Z, out of the machine towards you) so the collet nut is in
    /// reach: to Coast Runner's Z if it can, at the Y nearest theirs where it keeps
    /// `toolChangeRoom` clear in every clamping of the job with its longest tool. (Z −1 is
    /// fully back inside the machine: the moves pass through it to travel, never stop there.)
    /// One spot for the whole job (the guided job's tool_change_position too).
    func toolChangeSpot() -> ToolChangeSpot {
        let tools = (programs + prepPrograms).map(\.tool) + [EdgeFinding.tool]
        let longest = tools.max { $0.stickout < $1.stickout }
        let key = "\(setup)|\(stockID?.uuidString ?? "")|\(tools.map(\.id))|\(twoSided)|\(kitShiftY)"
        if let c = toolChangeSpotCache, c.key == key { return c.spot }
        let env = machine.machineEnvelope, tc = machine.toolChangePose
        var views: [(side: Int, stage: Int)] = [(0, 0)]
        if twoSided { views.append((1, 0)) }
        if hasPrep, let plan = flatPrepPlan { views += plan.stages.indices.map { (-1, $0) } }
        let saved = (viewSide, prepStage)
        switchingView = true
        defer {
            (viewSide, prepStage) = saved
            layoutScene()
            switchingView = false
        }
        // Candidate Ys, nearest Coast Runner's first, 4 mm apart, a little inside the travel.
        // (Stepped from Coast Runner's Y, so a spot a hair from it is Coast Runner's.)
        var ys: [Double] = [tc.y]
        for k in 1...60 {
            for y in [tc.y + 4 * Double(k), tc.y - 4 * Double(k)] where y >= env.y.lowerBound + 4 && y <= env.y.upperBound - 4 { ys.append(y) }
        }
        // Each clamping laid out once (what's on the table, as a tree); then the nearest Y that
        // lets the spindle come all the way out with room in every one.
        var beds: [TriangleTree] = []
        for v in views {
            (viewSide, prepStage) = (v.side, v.stage)
            layoutScene()
            if let t = bedTreeBuilt() { beds.append(t) }
        }
        // How far forward the spindle comes at Y (lowest machine Z, every clamping), with room
        // around it or just without touching; nil: not even at the back.
        func forward(_ y: Double, room: Bool, better: Double) -> Double? {
            var z = tc.z
            while z <= env.z.upperBound + 1e-9 && z < better - 1e-9 {
                let q = SIMD3(tc.x, y, z)
                if beds.allSatisfy({ room ? roomy(at: q, tool: longest, bed: $0) : headClear(at: q, tool: longest, bed: $0) }) { return z }
                z += 4
            }
            return nil
        }
        var best: (y: Double, z: Double, room: Bool)?
        if let y = ys.first(where: { y in beds.allSatisfy { roomy(at: SIMD3(tc.x, y, tc.z), tool: longest, bed: $0) } }) {
            best = (y, tc.z, true)
        } else {
            // Not all the way forward anywhere: the nearest Ys that come furthest forward, with
            // room if any does, else just without touching.
            for room in [true, false] where best == nil {
                for y in ys.prefix(24) {
                    if let z = forward(y, room: room, better: best?.z ?? .infinity) { best = (y, z, room) }
                }
            }
        }
        var spot = ToolChangeSpot(y: best?.y ?? tc.y, z: best?.z ?? tc.z)
        var notes: [String] = []
        if abs(spot.y - tc.y) >= 2 {
            notes.append("It stops at Y\(Length.mm(spot.y)) instead of Coast Runner's Y\(Length.mm(tc.y)): there the spindle would be right beside the clamps or the stock, with no room for your hands and the wrenches.")
        }
        if let b = best, b.z > tc.z + 1e-9 {
            notes.append("The spindle comes forward to Z\(Length.mm(b.z)), \(Length.mm(b.z - tc.z)) mm less than Coast Runner's Z\(Length.mm(tc.z)): further forward it would \(b.room ? "come within \(Length.mm(Self.toolChangeRoom)) mm of" : "touch") what's on the table. The collet nut is still in front of the machine, in reach.")
        }
        if let b = best, !b.room {
            notes.append("There's less than \(Length.mm(Self.toolChangeRoom)) mm around the spindle here: mind your fingers and the wrenches on the clamps.")
        }
        if best == nil {
            notes.append("No spot in the travel keeps the spindle clear of the clamps: check the clearance by hand before it comes forward.")
        }
        spot.note = notes.isEmpty ? nil : notes.joined(separator: " ")
        toolChangeSpotCache = (key, spot)
        return spot
    }

    /// The clamp kit to the left so the tools are changed on the right: with two clamps along a
    /// long bar, the right-hand clamp sits right where Coast Runner's tool-change position is.
    /// The smallest shift left (5 mm steps) that leaves that position `toolChangeRoom` clear in
    /// every clamping in the kit, with the whole bar still inside the Y travel. Toolpaths are
    /// relative to the stock, so they don't change; only where the kit is bolted does. Found
    /// before generating (the travel checks use it).
    func updateKitShift() {
        guard !setup.onBed, let stock, machineModel != nil else { kitShiftCache = nil; return }
        let tools = operations.compactMap { $0.toolID.flatMap(toolLookup) } + [EdgeFinding.tool]
        let longest = tools.max { $0.stickout < $1.stickout }
        let key = "\(setup)|\(stock.id)|\(tools.map(\.id))|\(twoSided)"
        if let c = kitShiftCache, c.key == key { return }
        kitShiftCache = (key, 0)
        let env = machine.machineEnvelope, tc = machine.toolChangePose
        var views: [(side: Int, stage: Int)] = [(0, 0)]
        if twoSided { views.append((1, 0)) }
        let saved = (viewSide, prepStage)
        switchingView = true
        var beds: [TriangleTree] = []
        for v in views {
            (viewSide, prepStage) = (v.side, v.stage)
            layoutScene()
            if let t = bedTreeBuilt() { beds.append(t) }
        }
        let length = setup.stockSize(stock).y
        var shift = 0.0
        for s in stride(from: 0.0, through: -80, by: -5) {
            // The bar's left end (machine Y), with room for edge finding past it.
            let leftEnd = (env.y.lowerBound + env.y.upperBound) / 2 + s - length / 2
            guard leftEnd - 8 >= env.y.lowerBound else { break }
            if beds.allSatisfy({ roomy(at: SIMD3(tc.x, tc.y - s, tc.z), tool: longest, bed: $0) }) { shift = s; break }
        }
        kitShiftCache = (key, shift)
        (viewSide, prepStage) = saved
        layoutScene()
        switchingView = false
    }

    /// Finds the spot just after the job appears (not when opening waits for it, nor in the
    /// middle of playback: it lays out each clamping in turn).
    func prepareToolChangeSpot() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !self.isPlaying, self.toolChangeStop == nil, !self.programs.isEmpty else { return }
            _ = self.toolChangeSpot()
        }
    }

    /// From p to the job's tool-change spot, the way the CR-1 can go without touching the
    /// clamps, parallels or stock: the spindle all the way back first, then over and the table
    /// down (in whichever order keeps clear), then the spindle out to the spot. `note`: why the
    /// spot isn't Coast Runner's, and anything it couldn't keep to.
    func toolChangePath(from p: SIMD3<Double>, tool: Tool?) -> (path: [SIMD3<Double>], note: String?) {
        let env = machine.machineEnvelope, tc = machine.toolChangePose
        let spot = toolChangeSpot()
        let back = SIMD3(p.x, p.y, env.z.upperBound)
        var path = [p, back]
        var note = spot.note
        let orders = [[SIMD3(p.x, spot.y, back.z), SIMD3(tc.x, spot.y, back.z)], [SIMD3(tc.x, p.y, back.z), SIMD3(tc.x, spot.y, back.z)]]
        let clearOrder = orders.first { o in legClear(back, o[0], tool: tool) && legClear(o[0], o[1], tool: tool) }
        if clearOrder == nil { note = (note.map { $0 + " " } ?? "") + "Moving over to the tool-change position the head would touch what's on the table: check it by hand." }
        path += clearOrder ?? orders[0]
        let top = SIMD3(tc.x, spot.y, back.z)
        var out = SIMD3(tc.x, spot.y, spot.z)
        while out.z < back.z - 1e-9 && !legClear(top, out, tool: tool) { out.z = min(out.z + 2, back.z) }
        if out != top { path.append(out) }
        // Without repeats (a leg of no length).
        var clean: [SIMD3<Double>] = []
        for q in path where clean.last.map({ simd_length($0 - q) > 1e-6 }) ?? true { clean.append(q) }
        return (clean, note)
    }

    /// Moves the machine through machine positions, at a pace a person can follow (about
    /// 60 mm/s, at least 0.3 s a leg).
    func animateMachine(along path: [SIMD3<Double>], then done: @escaping @MainActor () -> Void) {
        toolChangeTask?.cancel()
        let scripted = ProcessInfo.processInfo.environment["COASTLINE_SCRIPT"] != nil
            && ProcessInfo.processInfo.environment["COASTLINE_ANIMATE"] == nil
        guard !scripted, path.count > 1 else {
            if let last = path.last { setMachinePosition(last) }
            done()
            return
        }
        toolChangeTask = Task { @MainActor [weak self] in
            for k in 1..<path.count {
                let a = path[k - 1], b = path[k]
                let time = max(simd_length(b - a) / 60, 0.3)
                let start = Date()
                while true {
                    guard let self, !Task.isCancelled else { return }
                    let t = min(Date().timeIntervalSince(start) / time, 1)
                    let e = t * t * (3 - 2 * t)
                    self.setMachinePosition(a + (b - a) * e)
                    if let tool = self.currentTool { self.ensureToolMesh(tool) }
                    if t >= 1 { break }
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
            guard self != nil, !Task.isCancelled else { return }
            done()
        }
    }
}
