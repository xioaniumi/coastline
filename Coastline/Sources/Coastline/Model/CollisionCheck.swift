import CoastlineCore
import Foundation
import simd
import Viewport

/// One object on the bed for the collision check: a fixture assembly (kit parts with their
/// transforms) or a box (riser, parallels, the stock).
struct BedBody: Sendable {
    enum Shape: Sendable {
        case mesh([(Int, simd_double4x4)])
        case box(SIMD3<Double>, SIMD3<Double>)
        case triangles([SIMD3<Double>])
    }
    var name: String
    /// Scene meshes of this body (tinted when it collides).
    var meshPrefix: String
    var shape: Shape
}

/// The collision engine at work in the 3D view (Safety/Collision.swift does the geometry): after
/// every layout the fixtures, the stock and the machine (bed, frame, enclosure) are checked
/// against each other in the background; what collides turns red, gets a marker, and is listed
/// with the issues.
extension AppModel {
    static func fixtureName(kit: String, instance i: Int) -> String {
        switch kit {
        case "brick": "Squaring stop"
        case "cclamp": "C-clamp \(i + 1)"
        case "clamp": "Universal clamp \(i + 1)"
        case "spacer_u", "spacer_cube": "Spacer \(i + 1)"
        case "eccentric": "Eccentric clamp \(i + 1)"
        default: "\(kit) \(i + 1)"
        }
    }

    static func fixtureName(box id: String) -> String {
        if id.hasPrefix("fixture.parallel.behind."), let n = Int(id.split(separator: ".").last ?? "") { return "Parallel behind the stock (clamp \(n + 1))" }
        return switch id {
        case "fixture.riser": "Riser plate"
        case "fixture.bridge": "Parallel across the bar"
        case "fixture.parallel.behind": "Parallels behind the stock"
        case "fixture.parallel.under": "Parallels under the stock"
        default: id
        }
    }

    nonisolated static let machineBodyName = "the machine (bed, frame)"

    /// The machine's fixed parts and the table (as modelled, with the table at its setup pose),
    /// built once: it's the largest mesh.
    func machineCollisionTree() async -> TriangleTree? {
        if let t = machineTree { return t }
        if let running = machineTreeTask { return await running.value }
        guard let mm = machineModel else { return nil }
        let parts = mm.parts.filter { $0.group == "static" || $0.group == "x" }
        // One build, shared by everyone who asks while it runs.
        let task = Task.detached(priority: .utility) { () -> TriangleTree? in
            var tris: [SIMD3<Double>] = []
            for p in parts {
                let v = p.mesh.vertices
                for idx in p.mesh.indices {
                    let i = Int(idx) * 3
                    tris.append(SIMD3(Double(v[i]), Double(v[i + 1]), Double(v[i + 2])))
                }
            }
            return TriangleTree(tris)
        }
        machineTreeTask = task
        let tree = await task.value
        machineTree = tree
        machineTreeTask = nil
        return tree
    }

    func scheduleCollisionCheck(_ bodies: [BedBody], stockSize: SIMD3<Double>) {
        collisionGeneration += 1
        let generation = collisionGeneration
        guard !bodies.isEmpty, stock != nil, !showingStockOnly, ProcessInfo.processInfo.environment["COASTLINE_NO_COLLISIONS"] == nil else {
            if !collisions.isEmpty { collisions = [] }
            showCollisions()
            return
        }
        // The stock as shown (a box; the simulation's cut shape doesn't matter here).
        let o = workOrigin(stockSize: stockSize)
        var all = bodies
        if showingShoulders {
            all.append(BedBody(name: "the stock", meshPrefix: "stock", shape: .triangles(setup.stockTriangles(stockSize: stockSize).map { $0 + o })))
        } else {
            all.append(BedBody(name: "the stock", meshPrefix: "stock", shape: .box(SIMD3(o.x - stockSize.x / 2, o.y - stockSize.y / 2, o.z - stockSize.z),
                                                                                 SIMD3(o.x + stockSize.x / 2, o.y + stockSize.y / 2, o.z))))
        }
        let parts = kitParts.map(\.mesh)
        bedBodies = all
        Task { @MainActor in
            // Let a drag settle: only the latest layout is checked.
            try? await Task.sleep(for: .milliseconds(60))
            guard generation == collisionGeneration else { return }
            let machine = await machineCollisionTree()
            guard generation == collisionGeneration else { return }
            let bodies = all, meshes = parts
            let found = await Task.detached(priority: .userInitiated) { Self.collide(bodies, meshes: meshes, machine: machine) }.value
            guard generation == collisionGeneration else { return }
            if found != collisions { collisions = found }
            collisionPrefixes = Dictionary(all.map { ($0.name, $0.meshPrefix) }, uniquingKeysWith: { a, _ in a })
            showCollisions()
        }
    }

    /// All of the bodies' triangles together (model coordinates).
    nonisolated static func triangles(_ all: [BedBody], meshes parts: [MeshData]) -> [SIMD3<Double>] {
        var tris: [SIMD3<Double>] = []
        for b in all {
            switch b.shape {
            case .box(let lo, let hi): tris += Collision.boxTriangles(min: lo, max: hi)
            case .triangles(let t): tris += t
            case .mesh(let ps):
                for (j, t) in ps {
                    let v = parts[j].vertices
                    for idx in parts[j].indices {
                        let i = Int(idx) * 3
                        let w = t * SIMD4(Double(v[i]), Double(v[i + 1]), Double(v[i + 2]), 1)
                        tris.append(SIMD3(w.x, w.y, w.z))
                    }
                }
            }
        }
        return tris
    }

    nonisolated static func collide(_ all: [BedBody], meshes parts: [MeshData], machine: TriangleTree?) -> [Collision.Contact] {
        var list: [Collision.Body] = []
        for b in all {
            switch b.shape {
            case .box(let lo, let hi):
                list.append(.box(name: b.name, min: lo, max: hi))
            case .triangles(let t):
                list.append(Collision.Body(name: b.name, triangles: t))
            case .mesh(let ps):
                var tris: [SIMD3<Double>] = []
                for (j, t) in ps {
                    let v = parts[j].vertices
                    for idx in parts[j].indices {
                        let i = Int(idx) * 3
                        let w = t * SIMD4(Double(v[i]), Double(v[i + 1]), Double(v[i + 2]), 1)
                        tris.append(SIMD3(w.x, w.y, w.z))
                    }
                }
                list.append(Collision.Body(name: b.name, triangles: tris))
            }
        }
        if let machine { list.append(Collision.Body(name: machineBodyName, tree: machine)) }
        // Contact by design is touching, never colliding. Up to 0.2 mm is the fit of a key in a
        // T-slot or a modelling tolerance; real overlaps beyond it count.
        return Collision.check(list, tolerance: 0.2)
    }

    /// The collisions as issues ("C-clamp 1 runs into the machine (bed, frame) by 3.2 mm").
    var collisionIssues: [Issue] {
        collisions.map { c in
            Issue(.warning, "\(c.a.prefix(1).uppercased() + c.a.dropFirst()) runs into \(c.b) by about \(Length.mm(max(c.depth, 0.1))) mm.")
        }
    }

    /// Red tint on colliding fixtures and a marker where they meet.
    func showCollisions() {
        let scene = renderer.scene
        scene.remove(id: "collision")
        applyBedHighlight()
        guard !collisions.isEmpty else { return }
        var segs: [LineSegment] = []
        let c8 = SIMD4<UInt8>(255, 30, 30, 255)
        for c in collisions {
            let p = SIMD3<Float>(c.point)
            let r: Float = 3
            for d in [SIMD3<Float>(r, 0, 0), SIMD3(0, r, 0), SIMD3(0, 0, r)] { segs.append(LineSegment(p - d, p + d, color: c8)) }
            // A small ring around it, so it's seen from any side.
            for k in 0..<24 {
                let a = Float(k) / 24 * 2 * .pi, b = Float(k + 1) / 24 * 2 * .pi
                segs.append(LineSegment(p + SIMD3(0, cos(a), sin(a)) * r, p + SIMD3(0, cos(b), sin(b)) * r, color: c8))
            }
        }
        if let set = SceneLines(device: renderer.device, id: "collision", segments: segs) { scene.setLines(set) }
    }
}

// MARK: Fixing a collision

extension AppModel {
    /// Where The C-clamp model sits for a pad point and a turn about its screw (kit x → up,
    /// y → away from the spindle, z → across; the fixed jaw under the table).
    func cClampTransform(pad c: SIMD3<Double>, angle a: Double) -> simd_double4x4 {
        let under = prepTable.topX - FlatPrep.tableThickness
        let turn = simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, cos(a), sin(a), 0), SIMD4(0, -sin(a), cos(a), 0), SIMD4(0, 0, 0, 1)))
        return simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(under, c.y, c.z, 1)))
            * turn * simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, 1)))
    }

    /// The C-clamp's world triangles for a pad point and angle.
    func cClampTriangles(pad c: SIMD3<Double>, angle a: Double) -> [SIMD3<Double>] {
        let under = prepTable.topX - FlatPrep.tableThickness
        var tris: [SIMD3<Double>] = []
        for (j, t) in kitPartTransforms(kit: "cclamp", transform: cClampTransform(pad: c, angle: a), screwSlide: (c.x - under) - Self.cClampPadAt) {
            let m = kitParts[j].mesh, v = m.vertices
            for idx in m.indices {
                let i = Int(idx) * 3
                let w = t * SIMD4(Double(v[i]), Double(v[i + 1]), Double(v[i + 2]), 1)
                tris.append(SIMD3(w.x, w.y, w.z))
            }
        }
        return tris
    }

    /// Moves C-clamp `i` of the clamping on screen to the nearest place (pad position and turn)
    /// where it collides with nothing and still holds the bar: candidates by how little they
    /// change, the first clean one wins. False when none was found.
    @discardableResult
    func resolveClampCollision(_ i: Int) async -> Bool {
        guard bedEditable, let st = currentBedStage, let base = currentBedPlacement, i < base.clampPoints.count,
              let machine = await machineCollisionTree() else { return false }
        status = "Looking for a place for C-clamp \(i + 1) that doesn't collide…"
        let o0 = currentBedOverride
        let c0 = i < o0.clamps.count ? o0.clamps[i] : ClampOverride()
        let a0 = i < base.clampAngles.count ? base.clampAngles[i] : 0
        // Everything else on the bed: the stop, the other clamp, the bar, the riser, the machine.
        var others: [Collision.Body] = [Collision.Body(name: "the machine", tree: machine)]
        for (k, c) in base.clampPoints.enumerated() where k != i {
            others.append(Collision.Body(name: "C-clamp \(k + 1)", triangles: cClampTriangles(pad: c, angle: k < base.clampAngles.count ? base.clampAngles[k] : 0)))
        }
        if let size = displayStockSize {
            let o = workOrigin(stockSize: size)
            others.append(.box(name: "the bar", min: SIMD3(o.x - size.x / 2, o.y - size.y / 2, o.z - size.z), max: SIMD3(o.x + size.x / 2, o.y + size.y / 2, o.z)))
        }
        others.append(.box(name: "the riser", min: base.riserMin, max: base.riserMax))
        var stopTris: [SIMD3<Double>] = []
        for (j, t) in kitPartTransforms(kit: "brick", transform: base.brick) {
            let m = kitParts[j].mesh, v = m.vertices
            for idx in m.indices {
                let k = Int(idx) * 3
                let w = t * SIMD4(Double(v[k]), Double(v[k + 1]), Double(v[k + 2]), 1)
                stopTris.append(SIMD3(w.x, w.y, w.z))
            }
        }
        if !stopTris.isEmpty { others.append(Collision.Body(name: "the stop", triangles: stopTris)) }
        // Candidates: pad moves (back first: toward the bed's edge frees the frame) and turns,
        // cheapest change first.
        var candidates: [(cost: Double, o: ClampOverride)] = []
        // Far enough to get back to Coastline's proposal from wherever it was dragged.
        for dz in stride(from: 0.0, through: max(40, abs(c0.dz) + 20), by: 2) {
            for back in [-1.0, 1.0] where !(dz == 0 && back > 0) {
                for dy in [0.0, -5, 5, -10, 10] {
                    for turn in [0.0, -15, 15, -30, 30, -45, 45] {
                        var c = c0
                        c.dz += back * dz
                        c.dy += dy
                        c.angle = max(min(a0 + turn * .pi / 180, Self.maxClampAngle), -Self.maxClampAngle)
                        candidates.append((dz + abs(dy) + abs(turn) / 3 + (back > 0 ? 3 : 0), c))
                    }
                }
            }
        }
        candidates.sort { $0.cost < $1.cost }
        let table = prepTable, frontSlotZ = machineModel?.tSlotZ.max() ?? -13.4, centreY = travelCentreY
        for cand in candidates {
            var o = o0
            while o.clamps.count <= i { o.clamps.append(ClampOverride()) }
            o.clamps[i] = cand.o
            // Cheap checks first: the pad on the bar, out of the cut, the frame round the bed.
            let p = SideClamps.place(stage: st, table: table, frontSlotZ: frontSlotZ, centreY: centreY, override: o)
            guard !p.issues.contains(where: { $0.severity != .info && $0.message.contains("C-clamp \(i + 1)") }) else { continue }
            let tris = cClampTriangles(pad: p.clampPoints[i], angle: i < p.clampAngles.count ? p.clampAngles[i] : 0)
            let all = others
            let clean = await Task.detached(priority: .userInitiated) { () -> Bool in
                let me = Collision.Body(name: "me", triangles: tris)
                return Collision.check([me] + all, tolerance: 0.2).allSatisfy { $0.a != "me" && $0.b != "me" }
            }.value
            if clean {
                editPrep { $0.clamps[i] = cand.o }
                status = "C-clamp \(i + 1) moved to the nearest place where nothing collides."
                return true
            }
        }
        status = "No collision-free place found nearby for C-clamp \(i + 1): try the other side of the bar or a parallel."
        return false
    }
}
