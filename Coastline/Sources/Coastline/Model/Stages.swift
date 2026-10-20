import CoastlineCore
import Foundation

/// The guided workflow: six stages, each with a status and the reason
/// for it, free to go back and forth. Coastline proposes; every stage shows why.
enum JobStage: Int, CaseIterable, Identifiable {
    case partStock, holding, prep, clampKit, machining, review
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .partStock: "Part & stock"
        case .holding: "Holding"
        case .prep: "Stock prep"
        case .clampKit: "Clamp kit"
        case .machining: "Machining"
        case .review: "Review"
        }
    }
    var symbol: String {
        switch self {
        case .partStock: "cube.transparent"
        case .holding: "hand.raised"
        case .prep: "square.3.layers.3d.down.right"
        case .clampKit: "square.and.arrow.down.on.square"
        case .machining: "point.topleft.down.to.point.bottomright.curvepath"
        case .review: "checklist"
        }
    }
}

/// How the stock is held for the job (stage 2).
enum HoldingPath: String, CaseIterable, Identifiable, Codable {
    /// A · the stock fits the clamp kit's grip range as it is.
    case clampKit
    /// B · flat on the bed (stop, riser, C-clamps) for the whole job.
    case bedOnly
    /// C · prep flat on the bed until it fits, then the clamp kit.
    case prepThenKit
    /// D · shoulders at both ends that the kit grips; the full-height middle carries the part.
    case shoulders
    var id: String { rawValue }
    var letter: String { ["A", "B", "C", "D"][HoldingPath.allCases.firstIndex(of: self)!] }
    var title: String {
        switch self {
        case .clampKit: "Clamp kit directly"
        case .bedOnly: "Flat on the bed only"
        case .prepThenKit: "Prep on the bed, then the clamp kit"
        case .shoulders: "Shoulders, then the clamp kit"
        }
    }
    /// The release that brings it (nil: available now).
    var arrives: String? {
        switch self {
        case .clampKit, .prepThenKit, .bedOnly, .shoulders: nil
        }
    }
}

struct StageStatus {
    /// todo: the next thing to do there (nothing wrong); attention: something to look at.
    enum State { case done, todo, attention, blocked, notNeeded, later }
    var state: State
    var why: String
}

extension AppModel {
    /// The holding path the setup implies now (until B and D exist, A or C).
    var holdingPath: HoldingPath {
        setup.onBed ? .bedOnly : setup.shoulders != nil ? .shoulders : setup.downsizeHeight != nil ? .prepThenKit : .clampKit
    }

    /// What each path would mean for this part and stock, and whether it's the one to use.
    func holdingAssessment(_ path: HoldingPath) -> (possible: Bool, recommended: Bool, why: String) {
        guard let part, let stock else { return (false, false, "Choose a part and stock first.") }
        let option = stockOptions().first { $0.axes == setup.stockAxes }
        let (lo, hi) = setup.rotatedPartBounds(min: part.boundsMin, max: part.boundsMax)
        let partSize = hi - lo
        let raw = setup.rawStockSize(stock)
        let kitMax = UniversalClamp.onJaw(softJaw: false).upperBound
        let needX = GripZones.neededHeight(partX: partSize.x)
        switch path {
        case .clampKit:
            let fits = option?.workable == true && option?.prepHeight == nil && option?.viaShoulders != true
            let why: String
            if fits {
                why = "The stock (\(Length.mm(raw.x)) mm tall) fits the kit's grip as it is: no prep, straight to machining."
            } else if option?.viaShoulders == true {
                why = "Not as a whole bar: the part with its frame needs \(Length.mm(needX)) mm\(raw.x > kitMax ? " and the kit grips \(Length.mm(kitMax)) mm" : ""). Held by the ends (D) it works."
            } else if raw.x <= kitMax && needX > raw.x {
                why = "The kit grips this \(Length.mm(raw.x)) mm stock, but the part with its frame needs \(Length.mm(needX)) mm: taller stock, or scale the part."
            } else {
                why = "At \(Length.mm(raw.x)) mm tall the stock doesn't fit the kit's grip (up to \(Length.mm(kitMax)) mm without soft jaws)."
            }
            return (fits, fits, why)
        case .prepThenKit:
            let possible = option?.workable == true && option?.prepHeight != nil
            let plan = flatPrepPlan
            let steps = plan.map { p in "face end A\(p.rounds > 0 ? ", then the edge down to \(Length.mm(p.target)) mm in \(p.rounds) round\(p.rounds == 1 ? "" : "s")" : "")" } ?? "square it and mill it down"
            let why: String
            if possible {
                why = "Too tall for the kit as bought: on the bed, \(steps); then into the kit at full length."
            } else if needX > kitMax {
                why = "Milling the whole edge down can't help: the part with its frame needs \(Length.mm(needX)) mm, more than the kit grips."
            } else {
                why = "Not needed: the stock fits the kit as it is."
            }
            return (possible, possible, why)
        case .bedOnly:
            let b = bedAssessment()
            // Recommended only when the clamp kit can't do it, with or without prep.
            let kitWorks = option?.workable == true
            return (b.possible, b.possible && !kitWorks, b.why)
        case .shoulders:
            guard let proposal = shoulderProposal else {
                return (false, false, "Needs a bar at least \(Length.mm(partSize.x + 1)) mm tall and \(Length.mm(partSize.y + 2 * Shoulders.gripZone + 2)) mm long: the part between the clamps' jaws at the ends.")
            }
            let taller = needX > kitMax || needX > raw.x
            let cut = raw.x - proposal.height
            if cut < 0.01 {
                return (true, taller, "The kit grips the bar's two ends only (\(Length.mm(Shoulders.gripZone)) mm each): the part can reach the top and bottom edges, no frame strips along them. Nothing to mill first.")
            }
            return (true, taller, taller
                    ? "The part (with its frame) needs \(Length.mm(needX)) mm: taller than the kit grips (\(Length.mm(kitMax)) mm). A \(Length.mm(proposal.length)) mm shoulder at each end is milled down to \(Length.mm(proposal.height)) mm for the jaws; the full-height middle carries the part."
                    : "Instead of milling the whole edge down, only two \(Length.mm(proposal.length)) mm shoulders lose \(Length.mm(cut)) mm: much less to cut, the bar stays \(Length.mm(raw.x)) mm tall in the middle.")
        }
    }

    /// A stage's name for this job: on path B stage 4 is the bed, not the clamp kit.
    func title(_ stage: JobStage) -> String { stage == .clampKit && setup.onBed ? "On the bed" : stage.title }

    /// Each stage's state and the reason, shown in the stage bar.
    /// Why Generate can't run yet (nil: it can): an earlier step still blocked, no operations,
    /// or an operation without a tool.
    var generationBlocker: String? {
        for st in [JobStage.partStock, .holding, .prep, .clampKit] where status(st).state == .blocked {
            return "First: \(st.title), \(status(st).why.prefix(1).lowercased() + status(st).why.dropFirst())"
        }
        let ops = operations.filter(\.enabled)
        if ops.isEmpty { return "First: find the best plan (or a quick suggestion) above." }
        if ops.contains(where: { $0.toolID == nil || toolLookup($0.toolID!) == nil }) {
            return "First: choose a tool for every operation."
        }
        return nil
    }

    func status(_ stage: JobStage) -> StageStatus {
        let hasPart = part != nil, hasStock = stock != nil
        switch stage {
        case .partStock:
            if !hasPart { return StageStatus(state: .todo, why: "Import a part (STEP, IGES or Rhino).") }
            if !hasStock { return StageStatus(state: .todo, why: "Choose the stock you have.") }
            if stockOptions().first(where: { $0.axes == setup.stockAxes })?.workable != true {
                if setup.shoulders != nil || setup.onBed {
                    return StageStatus(state: .done, why: "The part fits the stock; it's held \(setup.onBed ? "flat on the bed" : "by shoulders at the ends") (stage 2).")
                }
                if shoulderProposal != nil {
                    return StageStatus(state: .attention, why: "Too tall for the clamp kit as a whole bar, but it can be held by shoulders at its ends: choose D in Holding.")
                }
                return StageStatus(state: .blocked, why: "The part doesn't fit this stock with its frame: scale it (Fit) or choose other stock.")
            }
            return StageStatus(state: .done, why: "The part fits the stock with room for its frame and the clamps.")
        case .holding:
            guard hasPart && hasStock else { return StageStatus(state: .later, why: "After the part and stock.") }
            let a = holdingAssessment(holdingPath)
            return StageStatus(state: .done, why: "\(holdingPath.letter) · \(holdingPath.title): \(a.why)")
        case .prep:
            guard hasPart && hasStock else { return StageStatus(state: .later, why: "After the part and stock.") }
            if setup.onBed { return StageStatus(state: .notNeeded, why: "No prep: the whole job is on the bed.") }
            guard let plan = flatPrepPlan else { return StageStatus(state: .notNeeded, why: "No prep: the stock goes straight into the clamp kit.") }
            if plan.issues.contains(where: { $0.severity == .warning }) {
                return StageStatus(state: .attention, why: plan.issues.first { $0.severity == .warning }!.message)
            }
            return StageStatus(state: .done, why: "\(plan.stages.count) clamping\(plan.stages.count == 1 ? "" : "s") on the bed, then the stock fits the kit.")
        case .clampKit:
            guard hasPart && hasStock else { return StageStatus(state: .later, why: "After the part and stock.") }
            if setup.onBed {
                if let w = bedJobPlacement?.issues.first(where: { $0.severity == .warning }) { return StageStatus(state: .attention, why: w.message) }
                return StageStatus(state: .done, why: "On the bed instead of the clamp kit: the stop, the riser and two C-clamps; face \(Length.mm(bedJobStage?.protrusion ?? 0)) mm past the stop.")
            }
            if setupIssues.contains(where: { $0.severity == .error }) {
                return StageStatus(state: .blocked, why: setupIssues.first { $0.severity == .error }!.message)
            }
            return StageStatus(state: setupIssues.contains { $0.severity == .warning } ? .attention : .done,
                               why: "Universal clamps across both T-slots\(setup.clampSoftJaw ? "" : ", soft jaws off"); face \(Length.mm(effectiveProtrusion)) mm past the jaws.")
        case .machining:
            guard hasPart && hasStock else { return StageStatus(state: .later, why: "After the setup.") }
            if operations.isEmpty { return StageStatus(state: .todo, why: "Next: find the best plan or a quick suggestion.") }
            if isGenerating { return StageStatus(state: .todo, why: "Generating in the background: look at and simulate what's ready while the rest is made.") }
            if failedOperationCount > 0 { return StageStatus(state: .blocked, why: "\(failedOperationCount) operation\(failedOperationCount == 1 ? "" : "s") failed: Retry redoes only \(failedOperationCount == 1 ? "it" : "them").") }
            if programs.isEmpty { return StageStatus(state: .todo, why: "Next: generate the toolpaths for the \(operations.filter(\.enabled).count) operations.") }
            if !(programs + prepPrograms).allSatisfy(\.report.passed) { return StageStatus(state: .blocked, why: "A program failed its safety check.") }
            return StageStatus(state: .done, why: "Toolpaths ready and safety-checked.")
        case .review:
            guard !programs.isEmpty else { return StageStatus(state: .later, why: "After the toolpaths.") }
            return StageStatus(state: .todo, why: "Next: walk through the steps (Tour), then export the guided job for CRWrite.")
        }
    }

    /// Goes to a stage: the inspector shows it and the 3D view shows what it's about.
    func enter(_ stage: JobStage) {
        self.stage = stage
        switch stage {
        case .partStock:
            // Only the stock as bought and the part in it (no machine, no clamps).
            switchingView = true
            viewSide = 0
            prepStage = 0
            switchingView = false
            inspectorTab = .setup
            layoutScene()
            focusWork()
        case .holding:
            if hasPrep { show(side: -1, stage: -1) } else { show(side: 0, stage: 0) }
            inspectorTab = .setup
        case .prep:
            if hasPrep { show(side: -1, stage: 0) }
            inspectorTab = .setup
        case .clampKit:
            show(side: 0, stage: 0)
            inspectorTab = .setup
        case .machining, .review:
            inspectorTab = .machining
            // Back from a setup step: rebuild the side's paths and simulation (the setup steps
            // showed the plain stock).
            if !sideResults.isEmpty || !prepResults.isEmpty {
                if viewSide < 0 && prepResults.isEmpty { viewSide = 0 }
                showSide()
            }
            layoutScene()
        }
    }
}
