import Foundation

/// One machining operation in a setup. `nil` overrides mean "let Coastline decide".
public struct Operation: Identifiable, Equatable, Sendable, Codable {
    public var id: UUID
    public var kind: OperationKind
    public var enabled: Bool
    public var toolID: UUID?
    /// Material left on walls / floors for the finishing passes, mm.
    public var leaveRadial: Double
    public var leaveAxial: Double
    public var stepdownOverride: Double?
    public var stepoverOverride: Double?
    /// Facing depth below the stock top, mm (facing only).
    public var faceDepth: Double
    /// Repeat the last contour pass to take out tool deflection.
    public var springPass: Bool
    /// 3D finishing: cusp height to leave (mm), raster angle and the steep/shallow split (degrees).
    public var scallop: Double = 0.008
    public var angle: Double = 0
    public var steepAngle: Double = 45
    /// Pace from the tuner: feeds (and roughing engagement) relative to the recommended values.
    public var feedScale: Double = 1
    /// Text to engrave (kind .engrave). Optional so older files still open.
    public var engraving: Engraving?
    /// Roughing only the pockets inside the outline (with a smaller tool after the big one).
    public var pocketsOnly: Bool?
    /// Pockets narrower than this many tool diameters are left for a smaller tool (nil:
    /// `defaultMinPocket`).
    public var minPocket: Double?
    /// A pocket 1.6 diameters wide still takes adaptive's helix entry; narrower ones go to
    /// the next smaller tool. (At 2.5 the small tools got pockets the bigger one roughs in a
    /// third of the time: a 1/16" doing what a 1/8" could, about 4× slower.)
    public static let defaultMinPocket = 1.6
    /// Floor finishing: only floors narrower than this (mm) — the wider ones were done by a
    /// bigger tool in an earlier floor pass. nil: every floor.
    public var floorMaxWidth: Double?
    /// Two-sided registration features Coastline adds (not the part's own geometry): side A's
    /// reference bores, side B's windows that open them from the back.
    public var reference: ReferenceFeature?
    /// Roughing style from the tuner (nil: chip-thinned).
    public var roughing: FeedsEngine.RoughingStyle?
    /// Thread milling (kind .thread): which thread, how deep.
    public var thread: ThreadMilling?

    public enum ReferenceFeature: String, Codable, Sendable { case bores, windows }

    /// Its symbol and one-line explanation (a texture is an engraving of a pattern).
    public var symbol: String { kind == .engrave && engraving?.texture != nil ? "circle.hexagongrid" : kind.symbol }
    public var explanation: String {
        kind == .engrave && engraving?.texture != nil
            ? "Cuts a decorative pattern into the surface at a set depth, following its shape, like a watchmaker's rose engine: guilloché, waves, hobnail. A V engraver gives the crispest lines."
            : kind.explanation
    }

    /// The operation's name in lists and programs.
    public var title: String {
        switch reference {
        case .bores: "Reference bores"
        case .windows: "Reference windows"
        case nil: kind == .engrave ? engraving?.texture.map { "Texture · \($0.pattern.title)" } ?? kind.title : kind.title
        }
    }

    public init(id: UUID = UUID(), kind: OperationKind, enabled: Bool = true, toolID: UUID? = nil,
                leaveRadial: Double = 0, leaveAxial: Double = 0, stepdownOverride: Double? = nil,
                stepoverOverride: Double? = nil, faceDepth: Double = 0.25, springPass: Bool = false) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.toolID = toolID
        self.leaveRadial = leaveRadial
        self.leaveAxial = leaveAxial
        self.stepdownOverride = stepdownOverride
        self.stepoverOverride = stepoverOverride
        self.faceDepth = faceDepth
        self.springPass = springPass
    }

    /// Cutting data with the user's overrides applied.
    public func cuttingData(tool: Tool, material: Material) -> CuttingData {
        var data = FeedsEngine.compute(tool: tool, material: material, kind: kind, roughing: roughing ?? .thinned)
        if kind.is3D {
            data.stepover = FeedsEngine.scallopStepover(tool: tool, cusp: scallop)
            data.stepdown = data.stepover
            data.notes = data.notes.filter { !$0.hasPrefix("Stepover") }
            data.notes.append("Stepover \(Length.mm(data.stepover)) mm leaves cusps about \(Int((scallop * 1000).rounded())) µm high.")
        }
        if abs(feedScale - 1) > 1e-6 {
            let cap = MachineProfile.cr1.maxFeedAnyDirection
            data.feed = min((data.feed * feedScale).rounded(), cap)
            data.plungeFeed = min((data.plungeFeed * feedScale).rounded(), cap)
            data.rampFeed = min((data.rampFeed * feedScale).rounded(), cap)
            if kind == .adaptive { data.stepover *= feedScale.squareRoot() }
            data.notes.append("Pace \(Int((feedScale * 100).rounded())) %: feeds\(kind == .adaptive ? " and engagement" : "") scaled from the recommended values.")
        }
        if let s = stepdownOverride { data.stepdown = s }
        if let s = stepoverOverride { data.stepover = s }
        return data
    }
}

/// Proposes a first operation list from the inventory. Rules of thumb, each explained; the
/// smart strategy engine replaces this with search + simulation.
public enum OperationPlanner {
    /// Tools the planner may use: owned, not broken, and with a matching collet.
    /// - includeSuggestions: also the tools Coastline suggests buying (ToolCatalog).
    public static func usableTools(_ inventory: Inventory, includeSuggestions: Bool = false) -> [Tool] {
        inventory.tools.filter { t in
            (t.quantity > 0 || (includeSuggestions && t.isSuggestion)) && t.condition != .broken
                && InventoryChecks.check(t, inventory: inventory).allSatisfy { $0.severity < .error }
                && inventory.colletSizes.contains { abs($0 - t.shankDiameter) <= 0.05 }
        }
    }

    public struct Proposal: Sendable {
        public var operations: [Operation]
        public var notes: [String]
    }

    /// - Parameters:
    ///   - holeDiameters: diameters of holes along the tool axis (from the engine).
    ///   - freeform: the part has surfaces 2.5D operations can't finish (domes, fillets…).
    ///   - minConcaveRadius: the tightest concave curvature on those surfaces, if any.
    public static func propose(inventory: Inventory, holeDiameters: [Double] = [], hasFloors: Bool = false,
                               freeform: Bool = false, minConcaveRadius: Double? = nil) -> Proposal {
        let tools = usableTools(inventory)
        let flats = tools.filter { $0.kind == .flatEndMill }.sorted { $0.diameter > $1.diameter }
        var ops: [Operation] = []
        var notes: [String] = []
        guard let rougher = flats.first(where: { $0.diameter <= 6.36 }) ?? flats.first else {
            return Proposal(operations: [], notes: ["No usable flat end mill in your inventory (check quantities and collets)."])
        }
        ops.append(Operation(kind: .facing, toolID: rougher.id, faceDepth: 0.25))  // one 0.25 mm pass [FS]
        notes.append("Facing and roughing with the \(rougher.name): the largest end mill you can hold, for speed and rigidity.")
        var rough = Operation(kind: .adaptive, toolID: rougher.id, leaveRadial: 0.2, leaveAxial: 0.1)
        if freeform {
            // Shallow steps leave small terraces on curved surfaces, so the ball finisher
            // never meets a full step of material.
            rough.stepdownOverride = 1.0
            rough.leaveAxial = 0.15
            notes.append("Curved surfaces: roughing steps down 1 mm at a time so the terraces it leaves are small for the ball finisher.")
        }
        ops.append(rough)
        // Finish with a smaller tool (≈3 mm) if there is one: tighter inside corners, less force.
        let finisher = flats.first { $0.diameter < rougher.diameter - 0.5 && $0.diameter >= 2.9 } ?? rougher
        if finisher.id != rougher.id {
            notes.append("Finishing walls with the \(finisher.name): reaches tighter corners and cuts lighter.")
        }
        ops.append(Operation(kind: .contour, toolID: finisher.id, springPass: true))
        if hasFloors { ops.append(Operation(kind: .floor, toolID: finisher.id)) }
        if freeform {
            // 3D finishing: the largest ball that fits the tightest concave curve, then a rest
            // pass with a smaller one where that ball couldn't reach.
            let balls = tools.filter { $0.kind == .ballEndMill }.sorted { $0.diameter > $1.diameter }
            let limit = minConcaveRadius.map { 2 * $0 } ?? .infinity
            if let ball = balls.first(where: { $0.diameter <= min(limit, 6.36) }) ?? balls.last {
                ops.append(Operation(kind: .steepShallow, toolID: ball.id))
                notes.append("Curved surfaces: steep & shallow finishing with the \(ball.name), leaving ~8 µm cusps.")
                if let small = balls.first(where: { $0.diameter < ball.diameter - 0.4 }) {
                    ops.append(Operation(kind: .rest, toolID: small.id))
                    notes.append("Then the \(small.name) cleans the corners the bigger ball couldn't reach.")
                }
            } else {
                notes.append("Curved surfaces need a ball end mill for a smooth finish. A 1/8\" ball is a good first one to buy.")
            }
        }

        let drills = tools.filter { $0.kind == .drill }
        for d in Set(holeDiameters.map { ($0 * 100).rounded() / 100 }).sorted() {
            if let drill = drills.first(where: { abs($0.diameter - d) <= 0.05 }) {
                ops.append(Operation(kind: .drill, toolID: drill.id))
                notes.append("⌀\(Length.mm(d)) holes: drilled with the \(drill.name).")
            } else if let mill = flats.filter({ $0.diameter <= d * 0.8 && $0.diameter >= d * 0.3 }).max(by: { $0.diameter < $1.diameter }) {
                ops.append(Operation(kind: .bore, toolID: mill.id))
                notes.append("⌀\(Length.mm(d)) holes: no matching drill, so they're helically bored with the \(mill.name).")
            } else {
                notes.append("⌀\(Length.mm(d)) holes: no drill or small enough end mill. Add one to your inventory.")
            }
        }
        return Proposal(operations: ops, notes: notes)
    }
}
