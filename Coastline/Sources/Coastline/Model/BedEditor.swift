import CoastlineCore
import Foundation
import simd

/// A fixture on the bed that can be picked and moved (stage 3, R3).
enum BedObject: Hashable {
    case stop
    case clamp(Int)
    /// In the clamp kit (stage 4): a universal clamp, and the stock itself.
    case kitClamp(Int)
    case kitStock

    var title: String {
        switch self {
        case .stop: "Squaring stop"
        case .clamp(let i): "C-clamp \(i + 1)"
        case .kitClamp(let i): "Universal clamp \(i + 1)"
        case .kitStock: "Stock"
        }
    }
}

/// The bed workholding editor: Coastline proposes where the stop and the C-clamps go for
/// each clamping; the user picks one in 3D and moves it with the gumball. The adjustments are
/// stored per clamping in the setup (`prepOverrides`), and everything downstream (the 3D view,
/// the checks, the prep programs and their clearance check, the guided job) uses them.
/// Which clamping on the bed is being edited: a prep stage, or the whole job (path B).
enum BedClamping: Equatable {
    case prep(Int)
    case job
}

extension AppModel {
    var bedClamping: BedClamping? {
        if stage == .prep, viewSide == -1, prepStage >= 0, currentPrepStage != nil { return .prep(prepStage) }
        if stage == .clampKit, setup.onBed, viewSide >= 0, bedJobStage != nil { return .job }
        return nil
    }

    /// The bed fixtures can be edited while a clamping (not the bar as bought) is on screen.
    var bedEditable: Bool { bedClamping != nil }

    var currentBedStage: FlatPrep.Stage? {
        switch bedClamping {
        case .prep: currentPrepStage
        case .job: bedJobStage
        case nil: nil
        }
    }

    var currentBedPlacement: SideClamps.Placement? {
        switch bedClamping {
        case .prep: currentPrepStage.map { prepPlacement($0) }
        case .job: bedJobPlacement
        case nil: nil
        }
    }

    var currentBedOverride: PrepOverride {
        switch bedClamping {
        case .prep(let k): prepOverride(at: k)
        case .job: setup.bedJobOverride
        case nil: PrepOverride()
        }
    }

    // MARK: Path B: the whole job on the bed

    /// The job's clamping on the bed: the stock as the part setup has it, its face past the
    /// stop by the deepest cut plus clearance (more when the clearance check asks for it).
    var bedJobStage: FlatPrep.Stage? {
        guard setup.onBed, let part, let stock else { return nil }
        let s = setup.stockSize(stock)
        let (lo, hi) = setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        let depth = min(hi.z - lo.z + setup.topAllowance + 0.5, s.z)
        return FlatPrep.Stage(kind: .edge(round: 0, of: 1), title: "Machining on the bed", stock: s, cut: depth,
                              protrusion: max(depth + FlatPrep.stopClearance, autoProtrusion ?? 0))
    }

    var bedJobPlacement: SideClamps.Placement? {
        bedJobStage.map {
            SideClamps.place(stage: $0, table: prepTable, frontSlotZ: machineModel?.tSlotZ.max() ?? -13.4, centreY: travelCentreY,
                             override: setup.bedJobOverride)
        }
    }

    /// Model Y of the stock's centre on path B (it moves with the stop).
    var bedJobCentreY: Double { travelCentreY + setup.bedJobOverride.stopShiftY }

    /// The deepest the part's cuts go (path B): the bar can't overhang the riser much more than
    /// its thickness without chatter.
    func bedAssessment() -> (possible: Bool, why: String) {
        guard let part, let stock else { return (false, "Choose a part and stock first.") }
        let s = setup.stockSize(stock)
        let (lo, hi) = setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        let depth = hi.z - lo.z + setup.topAllowance + 0.5
        let limit = FlatPrep.maxRoundCut(thickness: s.x)
        let opening = FlatPrep.clampOpening - FlatPrep.tableThickness - FlatPrep.riserHeight
        if s.x > opening {
            return (false, "At \(Length.mm(s.x)) mm the stock is taller than a 3\" C-clamp opens over the riser (\(Length.mm(opening)) mm).")
        }
        if depth > limit {
            return (false, "The cuts go \(Length.mm(depth)) mm into the face; a \(Length.mm(s.x)) mm bar flat on the riser takes about \(Length.mm(limit)) mm of overhang without chatter.")
        }
        return (true, "The stock flat on the riser against the stop, two C-clamps behind the cut: no clamp kit. Suits shallow work (\(Length.mm(depth)) mm deep here, up to \(Length.mm(limit)) mm) on one side; the part stays on the bar to be sawn off.")
    }

    /// Switches the holding path (stage 2).
    func choose(_ path: HoldingPath) {
        switch path {
        case .bedOnly:
            guard bedAssessment().possible else { return }
            prepAuto = false
            twoSided = false
            twoSidedChosen = true
            var s = setup
            s.onBed = true
            s.downsizeHeight = nil
            setup = s
            status = "The whole job flat on the bed: one side, no clamp kit."
        case .clampKit, .prepThenKit:
            guard setup.onBed || setup.shoulders != nil else { return }
            var s = setup
            s.onBed = false
            s.shoulders = nil
            setup = s
            prepAuto = true
            autoPlanPrep()
        case .shoulders:
            guard let sh = shoulderProposal else { return }
            prepAuto = false
            var s = setup
            s.onBed = false
            s.downsizeHeight = nil
            s.shoulders = sh
            setup = s
            status = "Shoulders: \(Length.mm(sh.length)) mm at each end milled down to \(Length.mm(sh.height)) mm for the clamp kit."
        }
    }

    /// How far the stop can slide each way along the T-slots: the cutter must still reach both
    /// ends of the bar within the Y travel.
    var stopRange: Double {
        guard let st = currentBedStage else { return 0 }
        return max((machine.travel.y - st.stock.y - 12) / 2, 0).rounded(.down)
    }

    static let maxClampAngle = 80 * Double.pi / 180

    /// The adjustments for prep stage `k` (empty when none).
    func prepOverride(at k: Int) -> PrepOverride {
        k >= 0 && k < setup.prepOverrides.count ? setup.prepOverrides[k] : PrepOverride()
    }

    /// A copy of `s` with the current clamping's adjustments changed (two clamp slots always there).
    func editingPrep(_ s: Setup, _ body: (inout PrepOverride) -> Void) -> Setup {
        var s = s
        if bedClamping == .job {
            var o = s.bedJobOverride
            while o.clamps.count < 2 { o.clamps.append(ClampOverride()) }
            body(&o)
            s.bedJobOverride = o.isEmpty ? PrepOverride() : o
            return s
        }
        let k = max(prepStage, 0)
        while s.prepOverrides.count <= k { s.prepOverrides.append(PrepOverride()) }
        while s.prepOverrides[k].clamps.count < 2 { s.prepOverrides[k].clamps.append(ClampOverride()) }
        body(&s.prepOverrides[k])
        // Nothing left changed: drop the trailing empty entries so the file stays clean.
        while let last = s.prepOverrides.last, last.isEmpty { s.prepOverrides.removeLast() }
        return s
    }

    func editPrep(_ body: (inout PrepOverride) -> Void) {
        let s = editingPrep(setup, body)
        if s != setup { setup = s }
        refreshPrepPrograms()
        layoutGumball()
    }

    // MARK: Inspector actions

    func resetClamping() { editPrep { $0 = PrepOverride() } }

    func setClampAngle(_ i: Int, _ a: Double) {
        editPrep { $0.clamps[i].angle = min(max(a, -Self.maxClampAngle), Self.maxClampAngle) }
    }

    /// Pushes the clamp's pad as far onto the bar as its frame allows: the spine against the
    /// bed's back edge.
    func snapClampToBedEdge(_ i: Int) {
        guard let p = currentBedPlacement, i < p.clampPoints.count else { return }
        let a = i < p.clampAngles.count ? p.clampAngles[i] : 0
        let want = prepTable.padLimit(angle: a)
        let dz = want - p.clampPoints[i].z
        editPrep { $0.clamps[i].dz = (($0.clamps[i].dz + dz) * 2).rounded(.down) / 2 }
    }

    /// The current clamping's placement problems (warnings only).
    var bedIssues: [Issue] {
        (currentBedPlacement?.issues ?? []).filter { $0.severity != .info } + collisionIssues
    }

    var bedPlacementWarning: String? { bedIssues.first { $0.severity == .warning }?.message }

    // MARK: Picking

    /// A click on the bed in stage 3 picks the stop (or the bar: it moves with the stop) or a
    /// C-clamp; anywhere else clears the pick.
    /// The stop (or the bar, which moves with it) or a C-clamp under the point, and where.
    func bedObject(at point: CGPoint, _ viewSize: CGSize) -> (BedObject, SIMD3<Float>)? {
        let ray = renderer.ray(at: point, viewSize: viewSize)
        let hit = renderer.scene.pick(origin: ray.origin, direction: ray.direction)
        let kit = kitEditable
        // The bar itself (a box; it isn't a pickable mesh so measuring clicks reach the part).
        var bar: (t: Float, p: SIMD3<Float>)?
        if let size = displayStockSize {
            let o = SIMD3<Float>(workOrigin(stockSize: size)), s = SIMD3<Float>(size)
            let lo = SIMD3(o.x - s.x / 2, o.y - s.y / 2, o.z - s.z), hi = SIMD3(o.x + s.x / 2, o.y + s.y / 2, o.z)
            var t0: Float = 0, t1 = Float.greatestFiniteMagnitude
            for k in 0..<3 {
                let inv = 1 / ray.direction[k]
                var a = (lo[k] - ray.origin[k]) * inv, b = (hi[k] - ray.origin[k]) * inv
                if a > b { swap(&a, &b) }
                t0 = max(t0, a); t1 = min(t1, b)
            }
            if t0 <= t1 { bar = (t0, ray.origin + ray.direction * t0) }
        }
        if let hit {
            let tHit = simd_distance(hit.world, ray.origin) / max(simd_length(ray.direction), 1e-6)
            if bar == nil || tHit <= bar!.t + 0.01 {
                let id = hit.id, parts = id.split(separator: ".")
                if kit {
                    if id.hasPrefix("fixture.clamp."), parts.count > 2, let i = Int(parts[2]) { return (.kitClamp(i), hit.world) }
                } else {
                    if id.hasPrefix("fixture.brick.") { return (.stop, hit.world) }
                    if id.hasPrefix("fixture.cclamp."), parts.count > 2, let i = Int(parts[2]) { return (.clamp(i), hit.world) }
                }
            }
        }
        if let bar { return (kit ? .kitStock : .stop, bar.p) }
        return nil
    }

    func selectBedObject(at point: CGPoint, viewSize: CGSize) {
        guard bedEditable || kitEditable else { return }
        let pick = bedObject(at: point, viewSize)?.0
        bedSelection = pick
        layoutGumball()
        if let pick {
            switch pick {
            case .stop: status = "Drag the green arrow to slide the stop (and the bar) along the T-slots."
            case .clamp: status = "Drag the arrows to move the pad on the bar; drag the red ring to turn the clamp about its screw."
            case .kitClamp: status = "Drag the green arrow to slide the clamp along the T-slots."
            case .kitStock: status = "Drag the blue arrow: how far the stock's face stands out past the jaws."
            }
        }
    }

    /// Fixture colours: red where it collides, amber when picked, else its own.
    func applyBedHighlight() {
        let tint = SIMD4<Float>(0.98, 0.72, 0.10, 1), red = SIMD4<Float>(0.95, 0.12, 0.10, 1)
        let prefix: String? = switch bedSelection.flatMap({ pickValid($0) ? $0 : nil }) {
        case .stop: "fixture.brick.0."
        case .clamp(let i): "fixture.cclamp.\(i)."
        case .kitClamp(let i): "fixture.clamp.\(i)."
        case .kitStock, nil: nil
        }
        let colliding = Set(collisions.flatMap { [$0.a, $0.b] }).compactMap { collisionPrefixes[$0] }.filter { $0.hasPrefix("fixture.") }
        for m in renderer.scene.meshes where m.id.hasPrefix("fixture.") {
            let base: SIMD4<Float>
            if colliding.contains(where: { m.id.hasPrefix($0) }) {
                base = red
            } else if prefix.map({ m.id.hasPrefix($0) }) ?? false {
                base = tint
            } else if m.id.split(separator: ".").count == 4, let j = m.id.split(separator: ".").last.flatMap({ Int($0) }), j < kitParts.count {
                base = Self.kitAppearance(kitParts[j]).color
            } else {
                base = SIMD4(0.30, 0.31, 0.33, 1)  // riser, parallels
            }
            m.color = SIMD4(base.x, base.y, base.z, m.color.w)
        }
    }

    // MARK: Prep programs follow the fixtures

    /// After the fixtures moved: the prep programs (cheap, no engine) are made again with the
    /// same tool, so the clearance check and the playback follow at once.
    func refreshPrepPrograms() {
        guard gumballDrag == nil, let tool = prepPrograms.first?.tool, let stock, let material = stock.material else { return }
        let keep = prepStage
        generatePrep(tool: tool, material: material, stock: stock)
        if viewSide == -1, keep >= 0 {
            switchingView = true
            prepStage = min(keep, max(prepResults.count - 1, 0))
            switchingView = false
            showSide()
        }
    }
}
